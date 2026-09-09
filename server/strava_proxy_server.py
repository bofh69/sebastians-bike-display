#!/usr/bin/env python3
"""Simple Strava proxy server.

Keeps STRAVA_CLIENT_SECRET on the server side and provides minimal endpoints for:
- OAuth token exchange
- OAuth token refresh
- FIT upload proxying
- Athlete profile lookup (for bike selection)
"""

from __future__ import annotations

import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


STRAVA_CLIENT_ID = os.getenv("STRAVA_CLIENT_ID", "276719")
STRAVA_CLIENT_SECRET = os.getenv("STRAVA_CLIENT_SECRET", "")
STRAVA_OAUTH_BASE_URL = os.getenv("STRAVA_OAUTH_BASE_URL", "https://www.strava.com")
STRAVA_API_BASE_URL = os.getenv("STRAVA_API_BASE_URL", "https://www.strava.com/api/v3")
MAX_REQUEST_BYTES = int(os.getenv("MAX_REQUEST_BYTES", str(16 * 1024 * 1024)))
ALLOWED_ORIGINS = {
    origin.strip()
    for origin in os.getenv("ALLOWED_ORIGINS", "").split(",")
    if origin.strip()
}


def _json_dumps(payload: dict[str, Any]) -> bytes:
    return json.dumps(payload, separators=(",", ":")).encode("utf-8")


def _make_multipart_body(
    *, fields: dict[str, str], file_field_name: str, file_name: str, file_bytes: bytes
) -> tuple[bytes, str]:
    boundary = f"----sbc-{uuid.uuid4().hex}"
    lines: list[bytes] = []

    for key, value in fields.items():
        lines.extend(
            [
                f"--{boundary}\r\n".encode("utf-8"),
                f'Content-Disposition: form-data; name="{key}"\r\n\r\n'.encode("utf-8"),
                value.encode("utf-8"),
                b"\r\n",
            ]
        )

    lines.extend(
        [
            f"--{boundary}\r\n".encode("utf-8"),
            (
                f'Content-Disposition: form-data; name="{file_field_name}"; '
                f'filename="{file_name}"\r\n'
            ).encode("utf-8"),
            b"Content-Type: application/octet-stream\r\n\r\n",
            file_bytes,
            b"\r\n",
            f"--{boundary}--\r\n".encode("utf-8"),
        ]
    )

    return b"".join(lines), boundary


class StravaProxyHandler(BaseHTTPRequestHandler):
    server_version = "StravaProxy/1.0"

    def do_OPTIONS(self) -> None:
        self.send_response(HTTPStatus.NO_CONTENT)
        self._send_cors_headers()
        self.end_headers()

    def do_GET(self) -> None:
        if self.path == "/healthz":
            self._send_json(HTTPStatus.OK, {"ok": True})
            return
        self._send_json(HTTPStatus.NOT_FOUND, {"error": "Not found"})

    def do_POST(self) -> None:
        if not STRAVA_CLIENT_SECRET:
            self._send_json(
                HTTPStatus.INTERNAL_SERVER_ERROR,
                {"error": "Server is missing STRAVA_CLIENT_SECRET"},
            )
            return

        route = self.path.split("?", 1)[0]

        if route == "/api/strava/oauth/token":
            payload = self._read_json_body()
            if payload is None:
                return
            self._handle_oauth_token_exchange(payload)
            return

        if route == "/api/strava/oauth/refresh":
            payload = self._read_json_body()
            if payload is None:
                return
            self._handle_oauth_refresh(payload)
            return

        if route == "/api/strava/upload":
            payload = self._read_json_body()
            if payload is None:
                return
            self._handle_upload(payload)
            return

        if route == "/api/strava/athlete":
            payload = self._read_json_body()
            if payload is None:
                return
            self._handle_athlete_lookup(payload)
            return

        self._send_json(HTTPStatus.NOT_FOUND, {"error": "Not found"})

    def _handle_oauth_token_exchange(self, payload: dict[str, Any]) -> None:
        code = str(payload.get("code", "")).strip()
        code_verifier = str(payload.get("code_verifier", "")).strip()
        redirect_uri = str(payload.get("redirect_uri", "")).strip()

        if not code or not code_verifier or not redirect_uri:
            self._send_json(
                HTTPStatus.BAD_REQUEST,
                {
                    "error": (
                        "Missing required fields: code, code_verifier, redirect_uri"
                    )
                },
            )
            return

        form = {
            "client_id": STRAVA_CLIENT_ID,
            "client_secret": STRAVA_CLIENT_SECRET,
            "code": code,
            "grant_type": "authorization_code",
            "code_verifier": code_verifier,
            "redirect_uri": redirect_uri,
        }
        self._proxy_strava_form(
            url=f"{STRAVA_OAUTH_BASE_URL}/oauth/token",
            form=form,
        )

    def _handle_oauth_refresh(self, payload: dict[str, Any]) -> None:
        refresh_token = str(payload.get("refresh_token", "")).strip()
        if not refresh_token:
            self._send_json(
                HTTPStatus.BAD_REQUEST,
                {"error": "Missing required field: refresh_token"},
            )
            return

        form = {
            "client_id": STRAVA_CLIENT_ID,
            "client_secret": STRAVA_CLIENT_SECRET,
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
        }
        self._proxy_strava_form(
            url=f"{STRAVA_OAUTH_BASE_URL}/oauth/token",
            form=form,
        )

    def _handle_upload(self, payload: dict[str, Any]) -> None:
        access_token = str(payload.get("access_token", "")).strip()
        file_name = str(payload.get("file_name", "")).strip() or "ride.fit"
        file_base64 = str(payload.get("file_base64", "")).strip()
        data_type = str(payload.get("data_type", "fit")).strip() or "fit"

        if not access_token or not file_base64:
            self._send_json(
                HTTPStatus.BAD_REQUEST,
                {"error": "Missing required fields: access_token, file_base64"},
            )
            return

        try:
            file_bytes = base64.b64decode(file_base64, validate=True)
        except (ValueError, TypeError):
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "file_base64 is invalid"})
            return

        fields = {
            "data_type": data_type,
            "external_id": str(payload.get("external_id", file_name)),
            "name": str(payload.get("name", "Bike ride")),
        }

        optional_field_names = ("description", "gear_id", "trainer", "commute")
        for key in optional_field_names:
            value = payload.get(key)
            if value is None:
                continue
            text = str(value).strip()
            if text:
                fields[key] = text

        multipart_body, boundary = _make_multipart_body(
            fields=fields,
            file_field_name="file",
            file_name=file_name,
            file_bytes=file_bytes,
        )

        request = urllib.request.Request(
            url=f"{STRAVA_API_BASE_URL}/uploads",
            data=multipart_body,
            method="POST",
            headers={
                "Authorization": "Bearer " + access_token,
                "Content-Type": f"multipart/form-data; boundary={boundary}",
            },
        )
        self._proxy_strava_request(request)

    def _handle_athlete_lookup(self, payload: dict[str, Any]) -> None:
        access_token = str(payload.get("access_token", "")).strip()
        if not access_token:
            self._send_json(
                HTTPStatus.BAD_REQUEST,
                {"error": "Missing required field: access_token"},
            )
            return

        request = urllib.request.Request(
            url=f"{STRAVA_API_BASE_URL}/athlete",
            method="GET",
            headers={"Authorization": "Bearer " + access_token},
        )
        self._proxy_strava_request(request)

    def _proxy_strava_form(self, *, url: str, form: dict[str, str]) -> None:
        body = urllib.parse.urlencode(form).encode("utf-8")
        request = urllib.request.Request(
            url=url,
            data=body,
            method="POST",
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        self._proxy_strava_request(request)

    def _proxy_strava_request(self, request: urllib.request.Request) -> None:
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                status = response.getcode()
                body = response.read()
                content_type = response.headers.get(
                    "Content-Type", "application/json; charset=utf-8"
                )
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self._send_cors_headers()
            self.end_headers()
            self.wfile.write(body)
        except urllib.error.HTTPError as error:
            body = error.read()
            content_type = error.headers.get(
                "Content-Type", "application/json; charset=utf-8"
            )
            self.send_response(error.code)
            self.send_header("Content-Type", content_type)
            self._send_cors_headers()
            self.end_headers()
            self.wfile.write(body)
        except urllib.error.URLError:
            self._send_json(HTTPStatus.BAD_GATEWAY, {"error": "Unable to reach Strava"})

    def _read_json_body(self) -> dict[str, Any] | None:
        content_length_raw = self.headers.get("Content-Length", "0")
        try:
            content_length = int(content_length_raw)
        except ValueError:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "Invalid Content-Length"})
            return None

        if content_length <= 0:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "Request body is required"})
            return None

        if content_length > MAX_REQUEST_BYTES:
            self._send_json(
                HTTPStatus.REQUEST_ENTITY_TOO_LARGE,
                {"error": "Request body is too large"},
            )
            return None

        raw_body = self.rfile.read(content_length)
        try:
            payload = json.loads(raw_body)
        except json.JSONDecodeError:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "Body must be valid JSON"})
            return None

        if not isinstance(payload, dict):
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "Body must be a JSON object"})
            return None

        return payload

    def _send_json(self, status: int, payload: dict[str, Any]) -> None:
        body = _json_dumps(payload)
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self._send_cors_headers()
        self.end_headers()
        self.wfile.write(body)

    def _send_cors_headers(self) -> None:
        origin = self.headers.get("Origin")
        if not origin:
            return
        if origin in ALLOWED_ORIGINS:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")

    def log_message(self, format: str, *args: Any) -> None:
        sys.stdout.write("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), format % args))


def run() -> None:
    bind_host = os.getenv("HOST", "127.0.0.1")
    bind_port = int(os.getenv("PORT", "8080"))

    server = ThreadingHTTPServer((bind_host, bind_port), StravaProxyHandler)
    print(f"Listening on http://{bind_host}:{bind_port}")
    server.serve_forever()


if __name__ == "__main__":
    run()
