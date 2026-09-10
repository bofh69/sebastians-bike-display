part of 'package:simple_bike_display/screens/home_screen.dart';

const int _fitEpochOffsetSeconds = 631065600;
const int _fitSportCycling = 2;
const int _fitActivityTypeManual = 0;
const double _minimumPowerForBalanceAverageWatts = 10;
const double _climbAltitudeSmoothingFactor = 0.25;
const double _minimumClimbGainMeters = 0.75;
const String _rideTrackingNotificationChannelId = 'ride_tracking_lockscreen';
const int _rideTrackingForegroundServiceNotificationId = 888;
const String _rideTrackingNotificationContent =
    'Ride recording active in background';
const String _rideCheckpointFileName = 'active_ride_checkpoint.json';
const String _rideCheckpointMetadataFileName =
    'active_ride_checkpoint.metadata.json';
const String _rideCheckpointSamplesFileName =
    'active_ride_checkpoint.samples.jsonl';
const Duration _rideCheckpointWriteInterval = Duration(minutes: 1);
const Duration _interruptedRideResumeWindow = Duration(minutes: 10);

String formatPowerBalance(double? leftBalance, double? rightBalance) {
  if (leftBalance == null || rightBalance == null) return 'N/A';

  String formatSide(double value) {
    return value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
  }

  return '${formatSide(leftBalance)}/${formatSide(rightBalance)}';
}

bool shouldAccumulatePowerBalanceSample({
  required bool isConnected,
  required double? power,
  required double? leftBalance,
  required double? rightBalance,
}) {
  return isConnected &&
      (power ?? 0) >= _minimumPowerForBalanceAverageWatts &&
      leftBalance != null &&
      rightBalance != null;
}

({
  double filteredAltitude,
  double climbReferenceAltitude,
  double additionalClimb,
}) updateClimbTracking({
  required double? previousFilteredAltitude,
  required double? previousClimbReferenceAltitude,
  required double currentAltitude,
}) {
  final filteredAltitude = previousFilteredAltitude == null
      ? currentAltitude
      : previousFilteredAltitude +
          (currentAltitude - previousFilteredAltitude) *
              _climbAltitudeSmoothingFactor;
  var climbReferenceAltitude =
      previousClimbReferenceAltitude ?? filteredAltitude;
  var additionalClimb = 0.0;

  if (filteredAltitude < climbReferenceAltitude) {
    climbReferenceAltitude = filteredAltitude;
  } else {
    final climbGain = filteredAltitude - climbReferenceAltitude;
    if (climbGain >= _minimumClimbGainMeters) {
      additionalClimb = climbGain;
      climbReferenceAltitude = filteredAltitude;
    }
  }

  return (
    filteredAltitude: filteredAltitude,
    climbReferenceAltitude: climbReferenceAltitude,
    additionalClimb: additionalClimb,
  );
}

@pragma('vm:entry-point')
void rideBackgroundServiceStart(ServiceInstance service) {
  DartPluginRegistrant.ensureInitialized();
  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((_) {
      service.setAsForegroundService();
    });
    service.on('setAsBackground').listen((_) {
      service.setAsBackgroundService();
    });
  }
  service.on('stopService').listen((_) {
    service.stopSelf();
  });
}

class _RideSample {
  final DateTime timestamp;
  final double? latitude;
  final double? longitude;
  final double? altitudeMeters;
  final double? accuracyMeters;
  final double gpsConfidence;
  final double? power;
  final double? cadence;
  final double? heartRate;
  final double? leftBalance;
  final double? rightBalance;
  final double distanceMeters;
  final double speedMps;

  const _RideSample({
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    required this.altitudeMeters,
    required this.accuracyMeters,
    required this.gpsConfidence,
    required this.power,
    required this.cadence,
    required this.heartRate,
    required this.leftBalance,
    required this.rightBalance,
    required this.distanceMeters,
    required this.speedMps,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'timestamp': timestamp.toIso8601String(),
        'latitude': latitude,
        'longitude': longitude,
        'altitudeMeters': altitudeMeters,
        'accuracyMeters': accuracyMeters,
        'gpsConfidence': gpsConfidence,
        'power': power,
        'cadence': cadence,
        'heartRate': heartRate,
        'leftBalance': leftBalance,
        'rightBalance': rightBalance,
        'distanceMeters': distanceMeters,
        'speedMps': speedMps,
      };

  factory _RideSample.fromJson(Map<String, dynamic> json) => _RideSample(
        timestamp: DateTime.parse(json['timestamp'] as String),
        latitude: (json['latitude'] as num?)?.toDouble(),
        longitude: (json['longitude'] as num?)?.toDouble(),
        altitudeMeters: (json['altitudeMeters'] as num?)?.toDouble(),
        accuracyMeters: (json['accuracyMeters'] as num?)?.toDouble(),
        gpsConfidence: (json['gpsConfidence'] as num?)?.toDouble() ?? 0,
        power: (json['power'] as num?)?.toDouble(),
        cadence: (json['cadence'] as num?)?.toDouble(),
        heartRate: (json['heartRate'] as num?)?.toDouble(),
        leftBalance: (json['leftBalance'] as num?)?.toDouble(),
        rightBalance: (json['rightBalance'] as num?)?.toDouble(),
        distanceMeters: (json['distanceMeters'] as num?)?.toDouble() ?? 0,
        speedMps: (json['speedMps'] as num?)?.toDouble() ?? 0,
      );
}

class _ExportedRideFile {
  final String fileName;
  final String path;
  final Uint8List bytes;

  const _ExportedRideFile({
    required this.fileName,
    required this.path,
    required this.bytes,
  });
}

class StravaUploadDecision {
  final bool skipUpload;
  final String? selectedGearId;
  final bool clearGear;

  const StravaUploadDecision({
    required this.skipUpload,
    required this.selectedGearId,
    required this.clearGear,
  });
}

class _InterruptedRideCheckpoint {
  final DateTime startTime;
  final DateTime lastSavedAt;
  final List<_RideSample> samples;
  final double distanceKm;
  final double totalClimbMeters;
  final double? speedKph;
  final double? avgSpeedKph;
  final double? cadence;
  final double? heartRate;
  final double? leftBalance;
  final double? rightBalance;
  final double smoothedSpeedMps;
  final double? filteredAltitudeForClimb;
  final double? climbReferenceAltitude;
  final int sampleCount;

  const _InterruptedRideCheckpoint({
    required this.startTime,
    required this.lastSavedAt,
    required this.samples,
    required this.distanceKm,
    required this.totalClimbMeters,
    required this.speedKph,
    required this.avgSpeedKph,
    required this.cadence,
    required this.heartRate,
    required this.leftBalance,
    required this.rightBalance,
    required this.smoothedSpeedMps,
    required this.filteredAltitudeForClimb,
    required this.climbReferenceAltitude,
    required this.sampleCount,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'startTime': startTime.toIso8601String(),
        'lastSavedAt': lastSavedAt.toIso8601String(),
        'distanceKm': distanceKm,
        'totalClimbMeters': totalClimbMeters,
        'speedKph': speedKph,
        'avgSpeedKph': avgSpeedKph,
        'cadence': cadence,
        'heartRate': heartRate,
        'leftBalance': leftBalance,
        'rightBalance': rightBalance,
        'smoothedSpeedMps': smoothedSpeedMps,
        'filteredAltitudeForClimb': filteredAltitudeForClimb,
        'climbReferenceAltitude': climbReferenceAltitude,
        'sampleCount': sampleCount,
        'samples': samples.map((sample) => sample.toJson()).toList(),
      };

  Map<String, dynamic> toMetadataJson() => <String, dynamic>{
        'startTime': startTime.toIso8601String(),
        'lastSavedAt': lastSavedAt.toIso8601String(),
        'distanceKm': distanceKm,
        'totalClimbMeters': totalClimbMeters,
        'speedKph': speedKph,
        'avgSpeedKph': avgSpeedKph,
        'cadence': cadence,
        'heartRate': heartRate,
        'leftBalance': leftBalance,
        'rightBalance': rightBalance,
        'smoothedSpeedMps': smoothedSpeedMps,
        'filteredAltitudeForClimb': filteredAltitudeForClimb,
        'climbReferenceAltitude': climbReferenceAltitude,
        'sampleCount': sampleCount,
      };

  factory _InterruptedRideCheckpoint.fromJson(Map<String, dynamic> json) {
    final rawSamples = (json['samples'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>();
    return _InterruptedRideCheckpoint(
      startTime: DateTime.parse(json['startTime'] as String),
      lastSavedAt: DateTime.parse(json['lastSavedAt'] as String),
      samples: rawSamples.map(_RideSample.fromJson).toList(),
      distanceKm: (json['distanceKm'] as num?)?.toDouble() ?? 0,
      totalClimbMeters: (json['totalClimbMeters'] as num?)?.toDouble() ?? 0,
      speedKph: (json['speedKph'] as num?)?.toDouble(),
      avgSpeedKph: (json['avgSpeedKph'] as num?)?.toDouble(),
      cadence: (json['cadence'] as num?)?.toDouble(),
      heartRate: (json['heartRate'] as num?)?.toDouble(),
      leftBalance: (json['leftBalance'] as num?)?.toDouble(),
      rightBalance: (json['rightBalance'] as num?)?.toDouble(),
      smoothedSpeedMps: (json['smoothedSpeedMps'] as num?)?.toDouble() ?? 0,
      filteredAltitudeForClimb:
          (json['filteredAltitudeForClimb'] as num?)?.toDouble(),
      climbReferenceAltitude:
          (json['climbReferenceAltitude'] as num?)?.toDouble(),
      sampleCount: (json['sampleCount'] as num?)?.toInt() ?? rawSamples.length,
    );
  }

  factory _InterruptedRideCheckpoint.fromMetadataJson({
    required Map<String, dynamic> json,
    required List<_RideSample> samples,
  }) {
    return _InterruptedRideCheckpoint(
      startTime: DateTime.parse(json['startTime'] as String),
      lastSavedAt: DateTime.parse(json['lastSavedAt'] as String),
      samples: samples,
      distanceKm: (json['distanceKm'] as num?)?.toDouble() ?? 0,
      totalClimbMeters: (json['totalClimbMeters'] as num?)?.toDouble() ?? 0,
      speedKph: (json['speedKph'] as num?)?.toDouble(),
      avgSpeedKph: (json['avgSpeedKph'] as num?)?.toDouble(),
      cadence: (json['cadence'] as num?)?.toDouble(),
      heartRate: (json['heartRate'] as num?)?.toDouble(),
      leftBalance: (json['leftBalance'] as num?)?.toDouble(),
      rightBalance: (json['rightBalance'] as num?)?.toDouble(),
      smoothedSpeedMps: (json['smoothedSpeedMps'] as num?)?.toDouble() ?? 0,
      filteredAltitudeForClimb:
          (json['filteredAltitudeForClimb'] as num?)?.toDouble(),
      climbReferenceAltitude:
          (json['climbReferenceAltitude'] as num?)?.toDouble(),
      sampleCount: (json['sampleCount'] as num?)?.toInt() ?? samples.length,
    );
  }
}

({bool shouldUpload, String? selectedGearId, bool clearGear})
    resolveStravaUploadDecision(StravaUploadDecision? decision) {
  if (decision == null || decision.skipUpload) {
    return (shouldUpload: false, selectedGearId: null, clearGear: false);
  }
  return (
    shouldUpload: true,
    selectedGearId: decision.selectedGearId,
    clearGear: decision.clearGear,
  );
}

bool shouldOfferInterruptedRideResume({
  required DateTime lastSavedAt,
  DateTime? now,
}) {
  final effectiveNow = now ?? DateTime.now();
  if (lastSavedAt.isAfter(effectiveNow)) return false;
  return effectiveNow.difference(lastSavedAt) < _interruptedRideResumeWindow;
}

enum InterruptedRideRecoveryAction { keepCheckpoint, resumeRide, finalizeRide }

InterruptedRideRecoveryAction resolveInterruptedRideRecoveryAction({
  required bool? wantsResume,
  required bool resumeStarted,
}) {
  if (wantsResume == true) {
    return resumeStarted
        ? InterruptedRideRecoveryAction.resumeRide
        : InterruptedRideRecoveryAction.keepCheckpoint;
  }
  if (wantsResume == false) {
    return InterruptedRideRecoveryAction.finalizeRide;
  }
  return InterruptedRideRecoveryAction.keepCheckpoint;
}

int resolveRecoveredCheckpointSampleCount({
  required int metadataSampleCount,
  required int parsedSampleCount,
}) {
  return parsedSampleCount > metadataSampleCount
      ? parsedSampleCount
      : metadataSampleCount;
}

Map<String, dynamic> reconcileRecoveredCheckpointMetadata({
  required Map<String, dynamic> metadata,
  required int parsedSampleCount,
}) {
  final reconciled = Map<String, dynamic>.from(metadata);
  final metadataSampleCount = (reconciled['sampleCount'] as num?)?.toInt() ?? 0;
  reconciled['sampleCount'] = resolveRecoveredCheckpointSampleCount(
    metadataSampleCount: metadataSampleCount,
    parsedSampleCount: parsedSampleCount,
  );
  return reconciled;
}

Future<InterruptedRideRecoveryAction> resolveInterruptedRideRecovery({
  required Future<bool?> Function() promptForResume,
  required Future<bool> Function() resumeRide,
}) async {
  final wantsResume = await promptForResume();
  final resumeStarted = wantsResume == true ? await resumeRide() : false;
  return resolveInterruptedRideRecoveryAction(
    wantsResume: wantsResume,
    resumeStarted: resumeStarted,
  );
}

Map<String, dynamic>? tryParseRideCheckpointSampleJsonLine(String line) {
  final trimmedLine = line.trim();
  if (trimmedLine.isEmpty) {
    return null;
  }
  final decoded = jsonDecode(trimmedLine);
  if (decoded is! Map) {
    throw const FormatException('Checkpoint sample line is not a JSON object.');
  }
  return Map<String, dynamic>.from(decoded);
}

List<Map<String, dynamic>> parseRideCheckpointSampleJsonLines(
  Iterable<String> lines,
) {
  final decodedSamples = <Map<String, dynamic>>[];
  for (final line in lines) {
    try {
      final decoded = tryParseRideCheckpointSampleJsonLine(line);
      if (decoded != null) {
        decodedSamples.add(decoded);
      }
    } catch (error, stackTrace) {
      debugPrint(
        'Failed to parse ride checkpoint sample line: $error\n$stackTrace',
      );
      break;
    }
  }
  return decodedSamples;
}

Future<List<Map<String, dynamic>>> loadRideCheckpointSampleJsonFromFile(
  io.File file,
) async {
  if (!await file.exists()) {
    return <Map<String, dynamic>>[];
  }
  final decodedSamples = <Map<String, dynamic>>[];
  final lines = file.openRead().transform(utf8.decoder).transform(
        const LineSplitter(),
      );
  await for (final line in lines) {
    try {
      final decoded = tryParseRideCheckpointSampleJsonLine(line);
      if (decoded != null) {
        decodedSamples.add(decoded);
      }
    } catch (error, stackTrace) {
      debugPrint(
        'Failed to parse ride checkpoint sample line: $error\n$stackTrace',
      );
      break;
    }
  }
  return decodedSamples;
}

Future<void> scheduleInterruptedRideRecoveryRetry(
  Future<void> Function() retry,
) {
  return Future<void>.delayed(
    const Duration(milliseconds: 50),
    retry,
  );
}

bool shouldScheduleInterruptedRideRecoveryRetry({
  required bool? wantsResume,
  required InterruptedRideRecoveryAction action,
  required bool retryAlreadyScheduled,
}) {
  return action == InterruptedRideRecoveryAction.keepCheckpoint &&
      !retryAlreadyScheduled &&
      (wantsResume == null || wantsResume == true);
}

int rideCheckpointMetadataSortKey(io.File file) {
  final name = file.uri.pathSegments.last;
  if (name == _rideCheckpointMetadataFileName) {
    return 0;
  }
  if (!name.startsWith('$_rideCheckpointMetadataFileName.')) {
    return -1;
  }
  final suffix = name
      .substring('$_rideCheckpointMetadataFileName.'.length)
      .replaceFirst(RegExp(r'\.tmp$'), '');
  return int.tryParse(suffix) ?? -1;
}

double restoreWindowedRollingAverage({
  required RollingAverage average,
  required Iterable<({DateTime timestamp, double value})> values,
  required DateTime windowEnd,
  required Duration window,
}) {
  average.reset();
  var restored = 0.0;
  final windowStart = windowEnd.subtract(window);
  final sortedValues = values.toList()
    ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  for (final value in sortedValues) {
    if (value.timestamp.isBefore(windowStart) ||
        value.timestamp.isAfter(windowEnd)) {
      continue;
    }
    restored = average.add(value.value);
  }
  return restored;
}

double? restoreWindowedTimeAverage({
  required TimeWindowAverage average,
  required Iterable<({DateTime timestamp, double value})> values,
  required DateTime windowEnd,
  required Duration window,
}) {
  average.clear();
  final windowStart = windowEnd.subtract(window);
  final sortedValues = values.toList()
    ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  for (final value in sortedValues) {
    if (value.timestamp.isBefore(windowStart) ||
        value.timestamp.isAfter(windowEnd)) {
      continue;
    }
    average.add(value.timestamp, value.value);
  }
  return average.average;
}

bool didRecoveredRideFinalizeCompletely({
  required bool hasSamples,
  required bool fitExported,
  required bool gpxExported,
  required bool uploadAttempted,
  required bool uploadSucceeded,
}) {
  return !hasSamples ||
      (fitExported && gpxExported && (!uploadAttempted || uploadSucceeded));
}

bool shouldClearRideCheckpointAfterFinalization({
  required bool completedSuccessfully,
  required bool preserveCheckpointOnFailure,
}) {
  return completedSuccessfully || !preserveCheckpointOnFailure;
}

Future<bool?> showResumeInterruptedRideDialog(BuildContext context) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Resume interrupted ride?'),
        content: const Text(
          'The previous ride was interrupted recently. Do you want to continue it?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('End ride'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Resume'),
          ),
        ],
      ),
    ),
  );
}
