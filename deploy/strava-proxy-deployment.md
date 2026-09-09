# Strava proxy deployment (Debian Trixie)

This deploys a Python 3 server at `https://sbc.diegeekdie.com/` so the Strava client secret stays on the server.

## 1) Install packages

```bash
sudo apt update
sudo apt install -y nginx certbot python3-certbot-nginx
```

## 2) Create service user and install files

```bash
sudo useradd --system --home /opt/strava-upload-proxy --shell /usr/sbin/nologin strava-proxy
sudo mkdir -p /opt/strava-upload-proxy
sudo chown strava-proxy:strava-proxy /opt/strava-upload-proxy
```

Copy this repository content to `/opt/strava-upload-proxy` (for example via git pull on the server), then set permissions:

```bash
sudo chown -R strava-proxy:strava-proxy /opt/strava-upload-proxy
sudo chmod 750 /opt/strava-upload-proxy
```

## 3) Configure environment variables

```bash
sudo cp /opt/strava-upload-proxy/server/strava_proxy.env.example /etc/default/strava-upload-proxy
sudo nano /etc/default/strava-upload-proxy
```

Set at least:

- `STRAVA_CLIENT_SECRET=<real secret>`
- `STRAVA_CLIENT_ID=276719` (or your app's client ID)
- `HOST=127.0.0.1`
- `PORT=8080`

Lock down the env file:

```bash
sudo chown root:root /etc/default/strava-upload-proxy
sudo chmod 600 /etc/default/strava-upload-proxy
```

## 4) Install and start systemd service

```bash
sudo cp /opt/strava-upload-proxy/deploy/systemd/strava-upload-proxy.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now strava-upload-proxy
sudo systemctl status strava-upload-proxy
```

Health check:

```bash
curl http://127.0.0.1:8080/healthz
```

## 5) Configure nginx

```bash
sudo mkdir -p /var/www/certbot
sudo cp /opt/strava-upload-proxy/deploy/nginx/sbc.diegeekdie.com.conf /etc/nginx/sites-available/sbc.diegeekdie.com.conf
sudo ln -sf /etc/nginx/sites-available/sbc.diegeekdie.com.conf /etc/nginx/sites-enabled/sbc.diegeekdie.com.conf
sudo nginx -t
sudo systemctl reload nginx
```

## 6) Issue Let's Encrypt certificate

With DNS for `sbc.diegeekdie.com` already pointing to the server:

```bash
sudo certbot --nginx -d sbc.diegeekdie.com
```

Choose redirect to HTTPS when prompted.

## 7) Verify renewal

```bash
sudo systemctl status certbot.timer
sudo certbot renew --dry-run
```

`certbot.timer` handles automatic renewals.

## Exposed API endpoints

- `GET /healthz`
- `POST /api/strava/oauth/token`
- `POST /api/strava/oauth/refresh`
- `POST /api/strava/athlete`
- `POST /api/strava/upload`

All POST endpoints expect `application/json` payloads.
