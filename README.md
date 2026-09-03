# simple-bike-display

A simple bike computer app showing important stats and recording
the ride.

## Strava auto-upload

Finished rides can be uploaded to Strava automatically.

1. Create a Strava API application and note its client ID and client secret.
2. In the app configuration screen, enter those credentials.
3. Connect the Strava account that should receive uploads.
4. Enable automatic uploads for finished rides.

The app uploads the generated FIT file after each ride when auto-upload is enabled.

## Development

There is a dev container with the needed tools for development.

Build & test with:

- `flutter pub get`
- `flutter analyze`
- `flutter test`
- `flutter build apk --debug`
