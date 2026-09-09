# Sebastian's Bike Display

A simple bike computer app showing important stats and recording
the ride.

## Strava auto-upload

Finished rides can be uploaded to Strava automatically.

1. Create a Strava API application and note its client ID and client secret.
   In Strava, set the authorization callback domain to `sebastiansbikedisplay`.
   The app uses the redirect URI `sebastiansbikedisplay://sebastiansbikedisplay`.
2. The app client ID is hardcoded to `276719`.
3. Deploy the Strava proxy server from this repository and set
   `STRAVA_CLIENT_SECRET` only on that server.
4. (Optional for non-production environments) point the app to a different
   proxy by passing
   `--dart-define=STRAVA_PROXY_BASE_URL=https://your-proxy.example.com`.
5. Connect the Strava account that should receive uploads.
6. Enable automatic uploads for finished rides.

The app uploads the generated FIT file after each ride when auto-upload is enabled.

## Strava proxy server

This repository now includes a Python 3 Strava proxy server so the Strava client
secret can be kept on the server side instead of in the app build:

- Server code: `/home/runner/work/sebastians-bike-display/sebastians-bike-display/server/strava_proxy_server.py`
- Nginx bootstrap config (HTTP): `/home/runner/work/sebastians-bike-display/sebastians-bike-display/deploy/nginx/sbc.diegeekdie.com.conf`
- Nginx TLS config (HTTPS): `/home/runner/work/sebastians-bike-display/sebastians-bike-display/deploy/nginx/sbc.diegeekdie.com.tls.conf`
- Systemd unit: `/home/runner/work/sebastians-bike-display/sebastians-bike-display/deploy/systemd/strava-upload-proxy.service`
- Deployment guide (Debian Trixie + Let's Encrypt): `/home/runner/work/sebastians-bike-display/sebastians-bike-display/deploy/strava-proxy-deployment.md`

## Development

There is a dev container with the needed tools for development.

Build & test with:

- `flutter pub get`
- `flutter analyze`
- `flutter test`
- `flutter build apk --debug`
- Or with custom proxy: `flutter build apk --debug --dart-define=STRAVA_PROXY_BASE_URL=https://your-proxy.example.com`
