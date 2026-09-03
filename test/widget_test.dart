import 'package:flutter_test/flutter_test.dart';
import 'package:simple_bike_display/main.dart';
import 'package:simple_bike_display/models/time_window_average.dart';
import 'package:simple_bike_display/screens/home_screen.dart';
import 'package:simple_bike_display/services/power_cadence_sensor_service.dart';
import 'package:simple_bike_display/services/sensor_reconnect_policy.dart';

void main() {
  test('formatPowerBalance preserves fractional balance values', () {
    expect(formatPowerBalance(49.5, 50.5), '49.5/50.5');
    expect(formatPowerBalance(50, 50), '50/50');
    expect(formatPowerBalance(null, 50), 'N/A');
  });

  test('shouldAccumulatePowerBalanceSample ignores idle samples', () {
    expect(
      shouldAccumulatePowerBalanceSample(
        isConnected: true,
        power: 200,
        leftBalance: 45,
        rightBalance: 55,
      ),
      isTrue,
    );
    expect(
      shouldAccumulatePowerBalanceSample(
        isConnected: true,
        power: 9.9,
        leftBalance: 0,
        rightBalance: 100,
      ),
      isFalse,
    );
    expect(
      shouldAccumulatePowerBalanceSample(
        isConnected: false,
        power: 200,
        leftBalance: 45,
        rightBalance: 55,
      ),
      isFalse,
    );
  });

  test('parsePowerBalance decodes half-percent values', () {
    expect(
      parsePowerBalance(flags: 0x0003, rawPedalBalance: 200),
      (leftBalance: 100.0, rightBalance: 0.0),
    );
    expect(
      parsePowerBalance(flags: 0x0001, rawPedalBalance: 34),
      (leftBalance: 17.0, rightBalance: 83.0),
    );
  });

  test('parsePowerBalance treats the flag bit as left-referenced', () {
    expect(
      parsePowerBalance(flags: 0x0003, rawPedalBalance: 40),
      (leftBalance: 20.0, rightBalance: 80.0),
    );
  });

  test('TimeWindowAverage keeps only the last minute of values', () {
    final average = TimeWindowAverage(window: const Duration(minutes: 1));
    final start = DateTime(2026);

    expect(average.add(start, 40), 40);
    expect(average.add(start.add(const Duration(seconds: 30)), 20), 30);
    expect(average.add(start.add(const Duration(seconds: 61)), 10), 15);
  });

  test('updateClimbTracking ignores small flat-road altitude oscillations', () {
    double? filteredAltitude;
    double? climbReferenceAltitude;
    var totalClimb = 0.0;

    for (final altitude in <double>[12, 13, 12, 13, 12, 13, 12]) {
      final update = updateClimbTracking(
        previousFilteredAltitude: filteredAltitude,
        previousClimbReferenceAltitude: climbReferenceAltitude,
        currentAltitude: altitude,
      );
      filteredAltitude = update.filteredAltitude;
      climbReferenceAltitude = update.climbReferenceAltitude;
      totalClimb += update.additionalClimb;
    }

    expect(totalClimb, 0);
  });

  test('updateClimbTracking records sustained climbing', () {
    double? filteredAltitude;
    double? climbReferenceAltitude;
    var totalClimb = 0.0;

    for (final altitude in <double>[12, 14, 16, 18, 20]) {
      final update = updateClimbTracking(
        previousFilteredAltitude: filteredAltitude,
        previousClimbReferenceAltitude: climbReferenceAltitude,
        currentAltitude: altitude,
      );
      filteredAltitude = update.filteredAltitude;
      climbReferenceAltitude = update.climbReferenceAltitude;
      totalClimb += update.additionalClimb;
    }

    expect(totalClimb, greaterThan(0));
  });

  test('shouldRetrySavedSensorConnection only retries when idle and saved', () {
    expect(
      shouldRetrySavedSensorConnection(
        deviceId: 'sensor-1',
        isConnected: false,
        isConnecting: false,
        isScanning: false,
      ),
      isTrue,
    );
    expect(
      shouldRetrySavedSensorConnection(
        deviceId: null,
        isConnected: false,
        isConnecting: false,
        isScanning: false,
      ),
      isFalse,
    );
    expect(
      shouldRetrySavedSensorConnection(
        deviceId: 'sensor-1',
        isConnected: true,
        isConnecting: false,
        isScanning: false,
      ),
      isFalse,
    );
    expect(
      shouldRetrySavedSensorConnection(
        deviceId: 'sensor-1',
        isConnected: false,
        isConnecting: true,
        isScanning: false,
      ),
      isFalse,
    );
    expect(
      shouldRetrySavedSensorConnection(
        deviceId: 'sensor-1',
        isConnected: false,
        isConnecting: false,
        isScanning: true,
      ),
      isFalse,
    );
  });

  test('SavedSensorReconnectCoordinator alternates between sensors', () {
    final coordinator = SavedSensorReconnectCoordinator(autoStartTimer: false);
    final base = DateTime.now().add(const Duration(seconds: 1));

    coordinator.register(heartRateReconnectKey, () async {});
    coordinator.register(powerCadenceReconnectKey, () async {});

    expect(coordinator.takeNextTurnAt(base), heartRateReconnectKey);
    expect(coordinator.takeNextTurnAt(base), powerCadenceReconnectKey);
    expect(
      coordinator.takeNextTurnAt(base.add(aggressiveSavedSensorReconnectInterval)),
      heartRateReconnectKey,
    );

    coordinator.unregister(heartRateReconnectKey);
    coordinator.unregister(powerCadenceReconnectKey);
  });

  test('SavedSensorReconnectCoordinator backs off and eventually stops', () {
    final coordinator = SavedSensorReconnectCoordinator(autoStartTimer: false);
    final base = DateTime.now();

    coordinator.register(heartRateReconnectKey, () async {});

    expect(coordinator.takeNextTurnAt(base), heartRateReconnectKey);
    expect(
      coordinator.takeNextTurnAt(
        base.add(
          aggressiveSavedSensorReconnectInterval - const Duration(seconds: 1),
        ),
      ),
      isNull,
    );
    expect(
      coordinator.takeNextTurnAt(base.add(aggressiveSavedSensorReconnectInterval)),
      heartRateReconnectKey,
    );
    expect(
      coordinator.takeNextTurnAt(base.add(aggressiveSavedSensorReconnectWindow)),
      heartRateReconnectKey,
    );
    expect(
      coordinator.takeNextTurnAt(
        base.add(aggressiveSavedSensorReconnectWindow + const Duration(seconds: 5)),
      ),
      isNull,
    );
    expect(
      coordinator.takeNextTurnAt(
        base.add(
          aggressiveSavedSensorReconnectWindow +
              backedOffSavedSensorReconnectInterval,
        ),
      ),
      heartRateReconnectKey,
    );
    expect(
      coordinator.takeNextTurnAt(
        base.add(savedSensorReconnectTimeout + const Duration(seconds: 1)),
      ),
      isNull,
    );

    coordinator.unregister(heartRateReconnectKey);
  });

  testWidgets('Home screen shows Start button', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Power (3s)'), findsOneWidget);
    expect(find.text('Heart Rate'), findsOneWidget);
    expect(find.text('Total Climb'), findsOneWidget);
    expect(find.text('N/A W'), findsWidgets);
  });

  testWidgets('Start button toggles to End', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.ensureVisible(find.text('Start'));
    await tester.tap(find.text('Start'));
    await tester.pump();
    expect(find.text('End'), findsOneWidget);
  });
}
