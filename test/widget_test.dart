import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_bike_display/main.dart';
import 'package:simple_bike_display/models/rolling_average.dart';
import 'package:simple_bike_display/models/time_window_average.dart';
import 'package:simple_bike_display/screens/home_screen.dart';
import 'package:simple_bike_display/services/power_cadence_sensor_service.dart';
import 'package:simple_bike_display/services/sensor_reconnect_policy.dart';
import 'package:simple_bike_display/services/strava_upload_service.dart';

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

  test('shouldOfferInterruptedRideResume only allows recent rides', () {
    final now = DateTime(2026, 1, 1, 12);

    expect(
      shouldOfferInterruptedRideResume(
        lastSavedAt: now.subtract(const Duration(minutes: 9, seconds: 59)),
        now: now,
      ),
      isTrue,
    );
    expect(
      shouldOfferInterruptedRideResume(
        lastSavedAt: now.subtract(const Duration(minutes: 10)),
        now: now,
      ),
      isFalse,
    );
    expect(
      shouldOfferInterruptedRideResume(
        lastSavedAt: now.add(const Duration(minutes: 2)),
        now: now,
      ),
      isFalse,
    );
  });

  test('resolveInterruptedRideRecoveryAction keeps failed resumes resumable',
      () {
    expect(
      resolveInterruptedRideRecoveryAction(
        wantsResume: true,
        resumeStarted: false,
      ),
      InterruptedRideRecoveryAction.keepCheckpoint,
    );
    expect(
      resolveInterruptedRideRecoveryAction(
        wantsResume: true,
        resumeStarted: true,
      ),
      InterruptedRideRecoveryAction.resumeRide,
    );
    expect(
      resolveInterruptedRideRecoveryAction(
        wantsResume: false,
        resumeStarted: false,
      ),
      InterruptedRideRecoveryAction.finalizeRide,
    );
    expect(
      resolveInterruptedRideRecoveryAction(
        wantsResume: null,
        resumeStarted: false,
      ),
      InterruptedRideRecoveryAction.keepCheckpoint,
    );
  });

  test('resolveInterruptedRideRecovery keeps failed resumes resumable',
      () async {
    var promptCalls = 0;
    var resumeCalls = 0;

    final action = await resolveInterruptedRideRecovery(
      promptForResume: () async {
        promptCalls += 1;
        return true;
      },
      resumeRide: () async {
        resumeCalls += 1;
        return false;
      },
    );

    expect(action, InterruptedRideRecoveryAction.keepCheckpoint);
    expect(promptCalls, 1);
    expect(resumeCalls, 1);
  });

  test('resolveRecoveredCheckpointSampleCount keeps the larger sample count',
      () {
    expect(
      resolveRecoveredCheckpointSampleCount(
        metadataSampleCount: 10,
        parsedSampleCount: 12,
      ),
      12,
    );
    expect(
      resolveRecoveredCheckpointSampleCount(
        metadataSampleCount: 10,
        parsedSampleCount: 8,
      ),
      10,
    );
  });

  test('reconcileRecoveredCheckpointMetadata updates sample count from log',
      () {
    final reconciled = reconcileRecoveredCheckpointMetadata(
      metadata: <String, dynamic>{
        'startTime': DateTime.utc(2024).toIso8601String(),
        'lastSavedAt': DateTime.utc(2024).toIso8601String(),
        'sampleCount': 3,
      },
      parsedSampleCount: 5,
    );

    expect(reconciled['sampleCount'], 5);
  });

  test('checkpoint sample parsing keeps the valid prefix on a bad line', () {
    final parsed = parseRideCheckpointSampleJsonLines(<String>[
      '{"timestamp":"2026-01-01T00:00:00.000Z","power":100}',
      '{"timestamp":"2026-01-01T00:00:01.000Z","power":200}',
      '{"timestamp":',
      '{"timestamp":"2026-01-01T00:00:02.000Z","power":300}',
    ]);
    final reconciled = reconcileRecoveredCheckpointMetadata(
      metadata: <String, dynamic>{'sampleCount': 4},
      parsedSampleCount: parsed.length,
    );

    expect(parsed, hasLength(2));
    expect(reconciled['sampleCount'], 4);
  });

  test('scheduleInterruptedRideRecoveryRetry defers the retry', () async {
    var called = false;
    final future = scheduleInterruptedRideRecoveryRetry(() async {
      called = true;
    });

    await Future<void>.delayed(Duration.zero);
    expect(called, isFalse);

    await future;
    expect(called, isTrue);
  });

  test('restoreWindowedRollingAverage only replays samples inside the window',
      () {
    final average = RollingAverage(windowSize: 3);

    final restored = restoreWindowedRollingAverage(
      average: average,
      values: <({DateTime timestamp, double value})>[
        (timestamp: DateTime.utc(2026, 1, 1, 12, 0, 0), value: 100),
        (timestamp: DateTime.utc(2026, 1, 1, 12, 0, 5), value: 200),
        (timestamp: DateTime.utc(2026, 1, 1, 12, 0, 6), value: 300),
      ],
      windowEnd: DateTime.utc(2026, 1, 1, 12, 0, 6),
      window: const Duration(seconds: 3),
    );

    expect(restored, 250);
    expect(average.add(300), closeTo(800 / 3, 0.001));
  });

  test('restoreWindowedRollingAverage supports longer recovery windows', () {
    final average = RollingAverage(windowSize: 20 * 60);

    final restored = restoreWindowedRollingAverage(
      average: average,
      values: <({DateTime timestamp, double value})>[
        (timestamp: DateTime.utc(2026, 1, 1, 12, 0, 0), value: 100),
        (timestamp: DateTime.utc(2026, 1, 1, 12, 15, 0), value: 200),
        (timestamp: DateTime.utc(2026, 1, 1, 12, 19, 30), value: 300),
      ],
      windowEnd: DateTime.utc(2026, 1, 1, 12, 19, 30),
      window: const Duration(minutes: 20),
    );

    expect(restored, 200);
  });

  test('didRecoveredRideFinalizeCompletely requires all exports to succeed',
      () {
    expect(
      didRecoveredRideFinalizeCompletely(
        hasSamples: true,
        fitExported: true,
        gpxExported: true,
        uploadAttempted: true,
        uploadSucceeded: true,
      ),
      isTrue,
    );
    expect(
      didRecoveredRideFinalizeCompletely(
        hasSamples: true,
        fitExported: true,
        gpxExported: false,
        uploadAttempted: false,
        uploadSucceeded: false,
      ),
      isFalse,
    );
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
      coordinator
          .takeNextTurnAt(base.add(aggressiveSavedSensorReconnectInterval)),
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
      coordinator
          .takeNextTurnAt(base.add(aggressiveSavedSensorReconnectInterval)),
      heartRateReconnectKey,
    );
    expect(
      coordinator
          .takeNextTurnAt(base.add(aggressiveSavedSensorReconnectWindow)),
      heartRateReconnectKey,
    );
    expect(
      coordinator.takeNextTurnAt(
        base.add(
            aggressiveSavedSensorReconnectWindow + const Duration(seconds: 5)),
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

  test(
      'buildStravaAccountLabel prefers full name then username then athlete ID',
      () {
    expect(
      buildStravaAccountLabel(
        firstName: 'Ada',
        lastName: 'Lovelace',
        username: 'ada',
        athleteId: '42',
      ),
      'Ada Lovelace',
    );
    expect(
      buildStravaAccountLabel(
        username: 'ada',
        athleteId: '42',
      ),
      'ada',
    );
    expect(
      buildStravaAccountLabel(athleteId: '42'),
      'Athlete 42',
    );
  });

  test('shouldResetStravaAuthentication detects client ID changes', () {
    expect(
      shouldResetStravaAuthentication(
        previousClientId: '123',
        nextClientId: '123',
      ),
      isFalse,
    );
    expect(
      shouldResetStravaAuthentication(
        previousClientId: '123',
        nextClientId: '456',
      ),
      isTrue,
    );
  });

  test('buildStravaRideNameForMidpoint maps time buckets', () {
    expect(buildStravaRideNameForMidpoint(DateTime(2026, 1, 1, 6)),
        'Morning ride');
    expect(buildStravaRideNameForMidpoint(DateTime(2026, 1, 1, 10, 59)),
        'Morning ride');
    expect(
        buildStravaRideNameForMidpoint(DateTime(2026, 1, 1, 11)), 'Lunch ride');
    expect(buildStravaRideNameForMidpoint(DateTime(2026, 1, 1, 13, 59)),
        'Lunch ride');
    expect(buildStravaRideNameForMidpoint(DateTime(2026, 1, 1, 14)),
        'Afternoon ride');
    expect(buildStravaRideNameForMidpoint(DateTime(2026, 1, 1, 17, 59)),
        'Afternoon ride');
    expect(buildStravaRideNameForMidpoint(DateTime(2026, 1, 1, 18)),
        'Evening ride');
    expect(buildStravaRideNameForMidpoint(DateTime(2026, 1, 1, 21, 59)),
        'Evening ride');
    expect(
        buildStravaRideNameForMidpoint(DateTime(2026, 1, 1, 22)), 'Night ride');
    expect(buildStravaRideNameForMidpoint(DateTime(2026, 1, 1, 5, 59)),
        'Night ride');
  });

  test('buildStravaUploadFields applies selected bike', () {
    final fields = buildStravaUploadFields(
      fileName: 'ride.fit',
      midpointLocalTime: DateTime(2026, 1, 1, 7),
      selectedGearId: 'b123',
    );
    expect(fields['external_id'], 'ride.fit');
    expect(fields['data_type'], 'fit');
    expect(fields['gear_id'], 'b123');
  });

  test('buildStravaUploadFields supports none bike selection', () {
    final fields = buildStravaUploadFields(
      fileName: 'ride.fit',
      midpointLocalTime: DateTime(2026, 1, 1, 7),
      clearGear: true,
      selectedGearId: 'ignored',
    );
    expect(fields['gear_id'], 'none');
  });

  test('buildStravaUploadFields omits bike when not selected', () {
    final fields = buildStravaUploadFields(
      fileName: 'ride.fit',
      midpointLocalTime: DateTime(2026, 1, 1, 7),
    );
    expect(fields.containsKey('gear_id'), isFalse);
  });

  test('parseStravaBikeOptions prioritizes default and filters malformed bikes',
      () {
    final bikes = parseStravaBikeOptions(<String, dynamic>{
      'default_bike': '2',
      'bikes': <dynamic>[
        <String, dynamic>{'id': '1', 'name': 'Road'},
        <String, dynamic>{'id': '2', 'name': 'Gravel'},
        <String, dynamic>{'id': null, 'name': 'Missing ID'},
        'not-a-map',
      ],
    });

    expect(bikes, hasLength(2));
    expect(bikes.first.gearId, '2');
    expect(bikes.first.isDefault, isTrue);
    expect(bikes.last.gearId, '1');
  });

  test('parseStravaBikeOptions provides fallback bike names', () {
    final bikes = parseStravaBikeOptions(<String, dynamic>{
      'bikes': <dynamic>[
        <String, dynamic>{'id': '9', 'name': ''},
      ],
    });
    expect(bikes.single.name, 'Bike 9');
  });

  test('parseStravaAuthenticationPayload accepts token refresh without athlete',
      () {
    final parsed = parseStravaAuthenticationPayload(<String, dynamic>{
      'access_token': 'a',
      'refresh_token': 'r',
      'expires_at': 12345,
    });
    expect(parsed.accessToken, 'a');
    expect(parsed.refreshToken, 'r');
    expect(parsed.expiresAt, 12345);
    expect(parsed.athlete, isNull);
  });

  test('parseStravaAuthenticationPayload normalizes athlete map shape', () {
    final parsed = parseStravaAuthenticationPayload(<String, dynamic>{
      'access_token': 'a',
      'refresh_token': 'r',
      'expires_at': '12345',
      'athlete': <Object?, Object?>{'id': 7, 'username': 'rider'},
    });
    expect(parsed.expiresAt, 12345);
    expect(parsed.athlete, isNotNull);
    expect(parsed.athlete!['id'].toString(), '7');
    expect(parsed.athlete!['username'], 'rider');
  });

  test('resolveStravaUploadDecision handles dismissal/skip/none/bike', () {
    expect(
      resolveStravaUploadDecision(null),
      (shouldUpload: false, selectedGearId: null, clearGear: false),
    );
    expect(
      resolveStravaUploadDecision(
        const StravaUploadDecision(
          skipUpload: true,
          selectedGearId: 'bike-1',
          clearGear: false,
        ),
      ),
      (shouldUpload: false, selectedGearId: null, clearGear: false),
    );
    expect(
      resolveStravaUploadDecision(
        const StravaUploadDecision(
          skipUpload: false,
          selectedGearId: null,
          clearGear: true,
        ),
      ),
      (shouldUpload: true, selectedGearId: null, clearGear: true),
    );
    expect(
      resolveStravaUploadDecision(
        const StravaUploadDecision(
          skipUpload: false,
          selectedGearId: 'bike-42',
          clearGear: false,
        ),
      ),
      (shouldUpload: true, selectedGearId: 'bike-42', clearGear: false),
    );
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

  testWidgets('resume interrupted ride dialog returns End ride',
      (WidgetTester tester) async {
    bool? result = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showResumeInterruptedRideDialog(context);
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('End ride'));
    await tester.pumpAndSettle();

    expect(result, isFalse);
  });

  testWidgets('resume interrupted ride dialog returns Resume',
      (WidgetTester tester) async {
    bool? result = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showResumeInterruptedRideDialog(context);
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Resume'));
    await tester.pumpAndSettle();

    expect(result, isTrue);
  });

  testWidgets('resume interrupted ride dialog ignores back',
      (WidgetTester tester) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showResumeInterruptedRideDialog(context);
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(find.text('Resume interrupted ride?'), findsOneWidget);
    expect(result, isNull);
  });
}
