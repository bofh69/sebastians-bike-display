import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_bike_display/screens/home_screen.dart';

void main() {
  test('climb tracking over known GPX is close to Strava climb', () {
    final gpx = File(
      'test/data/ride_2026-09-06T09-23-36.704288.gpx',
    ).readAsStringSync();
    final altitudeMatches = RegExp(r'<ele>([^<]+)</ele>').allMatches(gpx);
    final altitudes = altitudeMatches
        .map((match) => double.parse(match.group(1)!))
        .toList(growable: false);

    expect(altitudes, isNotEmpty);

    double? filteredAltitude;
    double? climbReferenceAltitude;
    var totalClimb = 0.0;

    for (final altitude in altitudes) {
      final update = updateClimbTracking(
        previousFilteredAltitude: filteredAltitude,
        previousClimbReferenceAltitude: climbReferenceAltitude,
        currentAltitude: altitude,
      );
      filteredAltitude = update.filteredAltitude;
      climbReferenceAltitude = update.climbReferenceAltitude;
      totalClimb += update.additionalClimb;
    }

    expect(totalClimb, closeTo(150, 1));
  });
}
