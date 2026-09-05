# Sebastian's Bike Display

A simple bike computer app showing important stats and recording
the ride.

## Strava auto-upload

Finished rides can be uploaded to Strava automatically.

1. Create a Strava API application and note its client ID and client secret.
   In Strava, set the authorization callback domain to `sebastiansbikedisplay`.
   The app uses the redirect URI `sebastiansbikedisplay://sebastiansbikedisplay`.
2. The app client ID is hardcoded to `276719`.
3. Provide the client secret at build time using `STRAVA_CLIENT_SECRET`:
   - CI: pass `--dart-define=STRAVA_CLIENT_SECRET=...`
   - Local: pass `--dart-define=STRAVA_CLIENT_SECRET=...` or
    `--dart-define-from-file=<file>` where the file contains
    `{"STRAVA_CLIENT_SECRET":"..."}`.
4. Connect the Strava account that should receive uploads.
5. Enable automatic uploads for finished rides.

The app uploads the generated FIT file after each ride when auto-upload is enabled.

## Development

There is a dev container with the needed tools for development.

Build & test with:

- `flutter pub get`
- `flutter analyze`
- `flutter test`
- `flutter build apk --debug`
