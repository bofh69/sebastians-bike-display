import 'package:flutter_test/flutter_test.dart';
import 'package:simple_bike_display/screens/home_screen.dart';

void main() {
  group('updateClimbTracking', () {
    test('does not reset climb reference on small descents', () {
      final result = updateClimbTracking(
        previousFilteredAltitude: 100,
        previousClimbReferenceAltitude: 100,
        currentAltitude: 98,
      );

      expect(result.climbReferenceAltitude, 100);
      expect(result.additionalClimb, 0);
    });

    test('resets climb reference after significant descent', () {
      final result = updateClimbTracking(
        previousFilteredAltitude: 100,
        previousClimbReferenceAltitude: 100,
        currentAltitude: 56,
      );

      expect(result.climbReferenceAltitude, 89);
      expect(result.additionalClimb, 0);
    });

    test('does not double-count climb after shallow dip', () {
      final initialClimb = updateClimbTracking(
        previousFilteredAltitude: 100,
        previousClimbReferenceAltitude: 100,
        currentAltitude: 108,
      );
      final shallowDip = updateClimbTracking(
        previousFilteredAltitude: initialClimb.filteredAltitude,
        previousClimbReferenceAltitude: initialClimb.climbReferenceAltitude,
        currentAltitude: 98,
      );
      final rebound = updateClimbTracking(
        previousFilteredAltitude: shallowDip.filteredAltitude,
        previousClimbReferenceAltitude: shallowDip.climbReferenceAltitude,
        currentAltitude: 110,
      );

      expect(initialClimb.additionalClimb, 2);
      expect(shallowDip.additionalClimb, 0);
      expect(rebound.additionalClimb, 0);
    });

    test('counts climb again after real descent and subsequent ascent', () {
      final initialClimb = updateClimbTracking(
        previousFilteredAltitude: 100,
        previousClimbReferenceAltitude: 100,
        currentAltitude: 108,
      );
      final deepDip = updateClimbTracking(
        previousFilteredAltitude: initialClimb.filteredAltitude,
        previousClimbReferenceAltitude: initialClimb.climbReferenceAltitude,
        currentAltitude: 62,
      );
      final recoveryClimb = updateClimbTracking(
        previousFilteredAltitude: deepDip.filteredAltitude,
        previousClimbReferenceAltitude: deepDip.climbReferenceAltitude,
        currentAltitude: 106,
      );

      expect(initialClimb.additionalClimb, 2);
      expect(deepDip.climbReferenceAltitude, 92);
      expect(recoveryClimb.additionalClimb, 3.5);
    });
  });
}
