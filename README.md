# Sebastian's Bike Display

A simple bike computer app showing important stats and recording
the ride.

Active rides are checkpointed locally about once per minute so an interrupted
ride can be resumed on the next launch when it is less than 10 minutes old, or
finalized automatically later. Recent recoveries prompt before resuming, while
older recoveries, or rides you decline to resume, are exported as FIT/GPX and
continue through the usual Strava upload flow. The resume prompt requires an
explicit choice, and backing out leaves the recovery checkpoint in place.

The app is tailored to my needs and I probably won't accept PRs that changes
how it works, except bug fixes. However, feel free to fork the repo and do your own
thing.

## Strava auto-upload

Finished rides can be uploaded to Strava automatically via a proxy server.

The Strava app isn't configured for many requests per day, so if you make a popular fork, set up your own proxy & app:

1. Create a Strava API application and note its client ID and client secret.
   In Strava, set the authorization callback domain to `sebastiansbikedisplay`.
   The app uses the redirect URI `sebastiansbikedisplay://sebastiansbikedisplay`.
2. The app client ID is hardcoded to `276719`, that needs to change then.
3. Deploy the Strava proxy server from this repository and set
   `STRAVA_CLIENT_SECRET` on that server.
4. point the app to a different proxy by passing
   `--dart-define=STRAVA_PROXY_BASE_URL=https://your-proxy.example.com/api/`.
5. Connect the Strava account that should receive uploads in the app's config screen.
6. Enable automatic uploads for finished rides in the app's config screen.

The app uploads the generated FIT file after each ride when auto-upload is enabled.


## Strava proxy server

This repository includes a Python 3 Strava proxy server so the Strava client
secret can be kept on the server side instead of in the app build:

- Server code: `/home/runner/work/sebastians-bike-display/sebastians-bike-display/server/strava_proxy_server.py`
- Deploy assets root: `/home/runner/work/sebastians-bike-display/sebastians-bike-display/server/deploy`
- Nginx bootstrap config (HTTP): `/home/runner/work/sebastians-bike-display/sebastians-bike-display/server/deploy/nginx/sbc.diegeekdie.com.conf`
- Nginx TLS config (HTTPS): `/home/runner/work/sebastians-bike-display/sebastians-bike-display/server/deploy/nginx/sbc.diegeekdie.com.tls.conf`
- Landing page template: `/home/runner/work/sebastians-bike-display/sebastians-bike-display/server/deploy/www/index.html`
- Systemd unit: `/home/runner/work/sebastians-bike-display/sebastians-bike-display/server/deploy/systemd/strava-upload-proxy.service`
- Deployment guide (Debian Trixie + Let's Encrypt): `/home/runner/work/sebastians-bike-display/sebastians-bike-display/server/deploy/strava-proxy-deployment.md`

## Development

There is a dev container with the needed tools for development.

Build & test with:

- `flutter pub get`
- `flutter analyze`
- `flutter test`
- `flutter build apk --debug`
- Or with custom proxy: `flutter build apk --debug --dart-define=STRAVA_PROXY_BASE_URL=https://your-proxy.example.com/api/`
