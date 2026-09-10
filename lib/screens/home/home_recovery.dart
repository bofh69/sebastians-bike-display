part of 'package:simple_bike_display/screens/home_screen.dart';

extension _HomeScreenRecovery on _HomeScreenState {
  Future<io.File> _rideCheckpointFile() async {
    final docsDir = await getApplicationDocumentsDirectory();
    await docsDir.create(recursive: true);
    return io.File('${docsDir.path}/$_rideCheckpointFileName');
  }

  Future<io.File> _rideCheckpointMetadataFile() async {
    final docsDir = await getApplicationDocumentsDirectory();
    await docsDir.create(recursive: true);
    return io.File('${docsDir.path}/$_rideCheckpointMetadataFileName');
  }

  Future<List<io.File>> _rideCheckpointMetadataFiles() async {
    final primary = await _rideCheckpointMetadataFile();
    final dir = primary.parent;
    final prefix = '${primary.uri.pathSegments.last}.';
    final files = <io.File>[];
    if (await primary.exists()) {
      files.add(primary);
    }
    await for (final entity in dir.list()) {
      if (entity is! io.File) continue;
      final name = entity.uri.pathSegments.last;
      if (name.startsWith(prefix)) {
        files.add(entity);
      }
    }
    return files;
  }

  Future<io.File> _rideCheckpointSamplesFile() async {
    final docsDir = await getApplicationDocumentsDirectory();
    await docsDir.create(recursive: true);
    return io.File('${docsDir.path}/$_rideCheckpointSamplesFileName');
  }

  Future<void> _persistRideCheckpoint({bool force = false}) async {
    if (!_supportsRideCheckpointing || !_isRunning) return;
    final startTime = _startTime;
    if (startTime == null) {
      return;
    }
    final now = DateTime.now();
    final lastSavedAt = _lastCheckpointSavedAt;
    if (!force &&
        lastSavedAt != null &&
        now.difference(lastSavedAt) < _rideCheckpointWriteInterval) {
      return;
    }
    final persistedSamplesSnapshot = List<_RideSample>.from(_samples);
    final checkpoint = _InterruptedRideCheckpoint(
      startTime: startTime,
      lastSavedAt: now,
      samples: persistedSamplesSnapshot,
      distanceKm: _data.distance ?? 0,
      totalClimbMeters: _data.totalClimb ?? 0,
      speedKph: _data.speed,
      avgSpeedKph: _data.avgSpeed,
      cadence: _data.cadence,
      heartRate: _data.heartRate,
      leftBalance: _data.leftBalance,
      rightBalance: _data.rightBalance,
      smoothedSpeedMps: _smoothedSpeedMps,
      filteredAltitudeForClimb: _filteredAltitudeForClimb,
      climbReferenceAltitude: _climbReferenceAltitude,
      sampleCount: persistedSamplesSnapshot.length,
    );
    final checkpointMetadataJson = jsonEncode(checkpoint.toMetadataJson());
    final legacyCheckpointJson = jsonEncode(checkpoint.toJson());
    _rideCheckpointWriteQueue = _rideCheckpointWriteQueue.then((_) async {
      try {
        final samplesFile = await _rideCheckpointSamplesFile();
        final pendingSampleStartIndex = _lastCheckpointSampleCount.clamp(
            0, persistedSamplesSnapshot.length);
        final pendingSamples = persistedSamplesSnapshot
            .skip(pendingSampleStartIndex)
            .map((sample) => jsonEncode(sample.toJson()))
            .join('\n');
        if (pendingSamples.isNotEmpty) {
          await samplesFile.writeAsString(
            '$pendingSamples\n',
            mode: io.FileMode.append,
            flush: true,
          );
        }
        final metadataFile = await _rideCheckpointMetadataFile();
        final tempFile = io.File(
          '${metadataFile.path}.${now.microsecondsSinceEpoch}.tmp',
        );
        await tempFile.writeAsString(
          checkpointMetadataJson,
          flush: true,
        );
        final publishedFile = io.File(
          '${metadataFile.path}.${now.microsecondsSinceEpoch}',
        );
        if (await publishedFile.exists()) {
          await publishedFile.delete();
        }
        await tempFile.rename(publishedFile.path);
        await metadataFile.writeAsString(checkpointMetadataJson, flush: true);
        final previousPublishedMetadataPath =
            _lastPublishedRideCheckpointMetadataPath;
        if (previousPublishedMetadataPath != null &&
            previousPublishedMetadataPath != publishedFile.path) {
          final previousPublishedFile = io.File(previousPublishedMetadataPath);
          if (await previousPublishedFile.exists()) {
            await previousPublishedFile.delete();
          }
        }
        _lastPublishedRideCheckpointMetadataPath = publishedFile.path;
        final legacyFile = await _rideCheckpointFile();
        await legacyFile.writeAsString(legacyCheckpointJson, flush: true);
        _lastCheckpointSavedAt = now;
        _lastCheckpointSampleCount = persistedSamplesSnapshot.length;
      } catch (error, stackTrace) {
        debugPrint('Failed to persist ride checkpoint: $error\n$stackTrace');
      }
    });
    await _rideCheckpointWriteQueue;
  }

  Future<void> _clearRideCheckpoint() async {
    if (!_supportsRideCheckpointing) return;
    _rideCheckpointWriteQueue = _rideCheckpointWriteQueue.then((_) async {
      try {
        final files = <io.File>[
          await _rideCheckpointFile(),
          ...await _rideCheckpointMetadataFiles(),
          await _rideCheckpointSamplesFile(),
        ];
        for (final file in files) {
          if (await file.exists()) {
            await file.delete();
          }
        }
        _lastCheckpointSavedAt = null;
        _lastCheckpointSampleCount = 0;
        _lastPublishedRideCheckpointMetadataPath = null;
        _interruptedRideRecoveryRetryScheduled = false;
      } catch (error, stackTrace) {
        debugPrint('Failed to clear ride checkpoint: $error\n$stackTrace');
      }
    });
    await _rideCheckpointWriteQueue;
  }

  Future<_InterruptedRideCheckpoint?> _loadRideCheckpoint() async {
    if (!_supportsRideCheckpointing) return null;
    try {
      final metadataFiles = await _rideCheckpointMetadataFiles();
      final publishedMetadataFiles =
          metadataFiles.where((file) => !file.path.endsWith('.tmp')).toList();
      final readableMetadataFiles = publishedMetadataFiles.isNotEmpty
          ? publishedMetadataFiles
          : List<io.File>.from(metadataFiles);
      if (readableMetadataFiles.isNotEmpty) {
        readableMetadataFiles.sort(
          (a, b) => rideCheckpointMetadataSortKey(b)
              .compareTo(rideCheckpointMetadataSortKey(a)),
        );
        for (final metadataFile in readableMetadataFiles) {
          try {
            final metadataRaw = await metadataFile.readAsString();
            if (metadataRaw.trim().isEmpty) {
              continue;
            }
            final metadataDecoded = jsonDecode(metadataRaw);
            if (metadataDecoded is! Map) {
              continue;
            }
            final samples = await _loadRideCheckpointSamples(
              await _rideCheckpointSamplesFile(),
            );
            final reconciledMetadata = reconcileRecoveredCheckpointMetadata(
              metadata: Map<String, dynamic>.from(metadataDecoded),
              parsedSampleCount: samples.length,
            );
            return _InterruptedRideCheckpoint.fromMetadataJson(
              json: reconciledMetadata,
              samples: samples,
            );
          } catch (error, stackTrace) {
            debugPrint(
              'Failed to read ride checkpoint metadata ${metadataFile.path}: '
              '$error\n$stackTrace',
            );
          }
        }
      }
      final file = await _rideCheckpointFile();
      if (!await file.exists()) {
        return null;
      }
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        await file.delete();
        return null;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        await file.delete();
        return null;
      }
      return _InterruptedRideCheckpoint.fromJson(
          Map<String, dynamic>.from(decoded));
    } catch (error, stackTrace) {
      debugPrint('Failed to load ride checkpoint: $error\n$stackTrace');
      await _clearRideCheckpoint();
      return null;
    }
  }

  Future<List<_RideSample>> _loadRideCheckpointSamples(io.File file) async {
    final samples = await loadRideCheckpointSampleJsonFromFile(file);
    return samples.map(_RideSample.fromJson).toList();
  }

  Future<void> _restoreInterruptedRideIfNeeded() async {
    final restoreFuture = _restoreInterruptedRideFuture ??=
        _restoreInterruptedRideIfNeededInternal();
    try {
      await restoreFuture;
    } finally {
      if (identical(_restoreInterruptedRideFuture, restoreFuture)) {
        _restoreInterruptedRideFuture = null;
      }
    }
  }

  Future<void> _restoreInterruptedRideIfNeededInternal() async {
    final checkpoint = await _loadRideCheckpoint();
    if (checkpoint == null || !mounted) return;
    final routeReady = await _waitForCurrentHomeRoute();
    if (!mounted || !routeReady || _hasActiveRideRuntime) return;
    if (shouldOfferInterruptedRideResume(lastSavedAt: checkpoint.lastSavedAt)) {
      final wantsResume = await showResumeInterruptedRideDialog(context);
      final action = await resolveInterruptedRideRecovery(
        promptForResume: () async => wantsResume,
        resumeRide: () => _resumeInterruptedRide(checkpoint),
      );
      switch (action) {
        case InterruptedRideRecoveryAction.resumeRide:
          _interruptedRideRecoveryRetryScheduled = false;
          return;
        case InterruptedRideRecoveryAction.keepCheckpoint:
          if (shouldScheduleInterruptedRideRecoveryRetry(
            wantsResume: wantsResume,
            action: action,
            retryAlreadyScheduled: _interruptedRideRecoveryRetryScheduled,
          )) {
            _interruptedRideRecoveryRetryScheduled = true;
            unawaited(
              scheduleInterruptedRideRecoveryRetry(
                _restoreInterruptedRideIfNeeded,
              ),
            );
          }
          return;
        case InterruptedRideRecoveryAction.finalizeRide:
          _interruptedRideRecoveryRetryScheduled = false;
          break;
      }
    } else {
      _interruptedRideRecoveryRetryScheduled = false;
    }
    _setRecoveredRideFinalizationActive(true);
    final readyToFinalizeRecoveredRide = await _prepareRideRuntime();
    if (!readyToFinalizeRecoveredRide) {
      _setRecoveredRideFinalizationActive(false);
      return;
    }
    try {
      final routeReadyToFinalize = await _waitForCurrentHomeRoute();
      if (!mounted || !routeReadyToFinalize) {
        if (!_interruptedRideRecoveryRetryScheduled) {
          _interruptedRideRecoveryRetryScheduled = true;
          unawaited(scheduleInterruptedRideRecoveryRetry(
            _restoreInterruptedRideIfNeeded,
          ));
        }
        return;
      }
      await _HomeScreenExport(this)._finalizeRide(
        rideStartTime: checkpoint.startTime,
        rideSamples: _samplesWithRecoveredEndTime(
          checkpoint.samples,
          checkpoint.lastSavedAt,
        ),
        completionPrefix: 'Recovered interrupted ride.',
        preserveCheckpointOnFailure: true,
        requireCurrentRouteForUpload: true,
      );
    } finally {
      _setRecoveredRideFinalizationActive(false);
      await _stopTemporaryRecoveryRuntime();
    }
  }

  Future<void> _stopActiveRideRuntime() async {
    await _stopRideRuntime();
  }

  Future<void> _stopTemporaryRecoveryRuntime() async {
    await _stopRideRuntime();
  }

  Future<void> _stopRideRuntime() async {
    if (_isMobileTrackingPlatform) {
      try {
        await WakelockPlus.disable();
      } catch (error, stackTrace) {
        debugPrint('Failed to disable wakelock: $error\n$stackTrace');
      }
    }
    try {
      await _hideBackgroundRideNotification(force: true);
    } catch (error, stackTrace) {
      debugPrint(
        'Failed to hide background ride notification: $error\n$stackTrace',
      );
    }
    if (_supportsBackgroundRideService && _serviceConfigured) {
      try {
        _backgroundService.invoke('stopService');
      } catch (error, stackTrace) {
        debugPrint('Failed to stop ride service: $error\n$stackTrace');
      }
    }
  }

  Future<bool> _waitForCurrentHomeRoute() async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (!mounted) {
        return false;
      }
      final route = ModalRoute.of(context);
      if (route == null) {
        continue;
      }
      if (route.isCurrent) {
        return true;
      }
    }
    return false;
  }

  Future<bool> _resumeInterruptedRide(
    _InterruptedRideCheckpoint checkpoint,
  ) async {
    if (_isRunning) return false;
    final hasPermission = await _ensureLocationPermission();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Location permission is required.')),
        );
      }
      return false;
    }

    final canStartForegroundTracking =
        await _ensureForegroundTrackingPermission();
    if (!canStartForegroundTracking) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Notification permission is required.')),
        );
      }
      return false;
    }

    final readyToRun = await _prepareRideRuntime();
    if (!readyToRun) return false;
    var resumed = false;
    try {
      if (!mounted) return false;
      final restoredSamples = List<_RideSample>.from(checkpoint.samples)
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      final restoredPosition = _positionFromSample(
        restoredSamples.isEmpty ? null : restoredSamples.last,
      );
      final restoredCurrentPowerWatts =
          restoredSamples.isEmpty ? 0.0 : (restoredSamples.last.power ?? 0.0);
      final restoredPowerWindowEnd = restoredSamples.isEmpty
          ? checkpoint.lastSavedAt
          : restoredSamples.last.timestamp;
      final restoredPowerSamples = restoredSamples.map(
        (sample) => (
          timestamp: sample.timestamp,
          value: sample.power ?? 0.0,
        ),
      );
      final restoredPower3s = restoreWindowedRollingAverage(
        average: _power3sAverage,
        values: restoredPowerSamples,
        windowEnd: restoredPowerWindowEnd,
        window: const Duration(seconds: 3),
      );
      final restoredPower20min = restoreWindowedRollingAverage(
        average: _power20MinAverage,
        values: restoredPowerSamples,
        windowEnd: restoredPowerWindowEnd,
        window: const Duration(minutes: 20),
      );
      final restoredBalanceSamples = restoredSamples
          .where((sample) =>
              sample.leftBalance != null && sample.rightBalance != null)
          .where((sample) =>
              (sample.power ?? 0) >= _minimumPowerForBalanceAverageWatts)
          .toList();
      final restoredLeftBalance = restoreWindowedTimeAverage(
        average: _leftBalanceAverage,
        values: restoredBalanceSamples.map(
          (sample) => (
            timestamp: sample.timestamp,
            value: sample.leftBalance!,
          ),
        ),
        windowEnd: restoredPowerWindowEnd,
        window: const Duration(minutes: 1),
      );
      final restoredRightBalance = restoreWindowedTimeAverage(
        average: _rightBalanceAverage,
        values: restoredBalanceSamples.map(
          (sample) => (
            timestamp: sample.timestamp,
            value: sample.rightBalance!,
          ),
        ),
        windowEnd: restoredPowerWindowEnd,
        window: const Duration(minutes: 1),
      );

      _applyState(() {
        _isRunning = true;
        _startTime = checkpoint.startTime;
        _samples
          ..clear()
          ..addAll(restoredSamples);
        _data.distance = checkpoint.distanceKm;
        _data.duration = DateTime.now().difference(checkpoint.startTime);
        _data.avgSpeed = checkpoint.avgSpeedKph;
        _data.speed = checkpoint.speedKph;
        _data.power3s = restoredPower3s;
        _data.power20min = restoredPower20min;
        _data.totalClimb = checkpoint.totalClimbMeters;
        _data.cadence = checkpoint.cadence;
        _data.heartRate = checkpoint.heartRate;
        _data.leftBalance = restoredLeftBalance ?? checkpoint.leftBalance;
        _data.rightBalance = restoredRightBalance ?? checkpoint.rightBalance;
        _currentPowerWatts = restoredCurrentPowerWatts;
        _lastAcceptedPosition = restoredPosition;
        _lastAcceptedTimestamp = restoredPosition?.timestamp;
        _lastAcceptedBearingDegrees =
            _bearingFromRecentSamples(restoredSamples);
        _smoothedSpeedMps = checkpoint.smoothedSpeedMps;
        _filteredAltitudeForClimb = checkpoint.filteredAltitudeForClimb;
        _climbReferenceAltitude = checkpoint.climbReferenceAltitude;
        _lastCheckpointSavedAt = checkpoint.lastSavedAt;
        _lastCheckpointSampleCount = restoredSamples.length;
      });
      resumed = true;
    } finally {
      if (!resumed) {
        await _stopTemporaryRecoveryRuntime();
      }
    }
    try {
      await _startLocationStream();
    } catch (error, stackTrace) {
      debugPrint(
        'Failed to restart location stream after ride resume: $error\n$stackTrace',
      );
    }
    _recordingTimer?.cancel();
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _recordSample();
    });
    if (!kIsWeb && io.Platform.isAndroid) {
      if (_isAppInForeground) {
        unawaited(_hideBackgroundRideNotification(force: true));
      } else {
        unawaited(_showBackgroundRideNotification());
      }
    }
    if (!mounted) return false;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Interrupted ride resumed.')),
    );
    return true;
  }

  List<_RideSample> _samplesWithRecoveredEndTime(
    List<_RideSample> samples,
    DateTime recoveredEndTime,
  ) {
    if (samples.isEmpty) return samples;
    final lastSample = samples.last;
    if (!recoveredEndTime.isAfter(lastSample.timestamp)) {
      return samples;
    }
    return <_RideSample>[
      ...samples,
      _RideSample(
        timestamp: recoveredEndTime,
        latitude: lastSample.latitude,
        longitude: lastSample.longitude,
        altitudeMeters: lastSample.altitudeMeters,
        accuracyMeters: lastSample.accuracyMeters,
        gpsConfidence: lastSample.gpsConfidence,
        power: null,
        cadence: null,
        heartRate: null,
        leftBalance: null,
        rightBalance: null,
        distanceMeters: lastSample.distanceMeters,
        speedMps: 0,
      ),
    ];
  }

  Position? _positionFromSample(_RideSample? sample) {
    if (sample == null || sample.latitude == null || sample.longitude == null) {
      return null;
    }
    final altitude = sample.altitudeMeters;
    final accuracy = sample.accuracyMeters;
    return Position(
      longitude: sample.longitude!,
      latitude: sample.latitude!,
      timestamp: sample.timestamp,
      accuracy: (accuracy != null && accuracy.isFinite) ? accuracy : 0,
      altitude: (altitude != null && altitude.isFinite) ? altitude : 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: sample.speedMps,
      speedAccuracy: 0,
    );
  }

  double? _bearingFromRecentSamples(List<_RideSample> samples) {
    for (var index = samples.length - 1; index > 0; index--) {
      final current = samples[index];
      final previous = samples[index - 1];
      if (current.latitude == null ||
          current.longitude == null ||
          previous.latitude == null ||
          previous.longitude == null) {
        continue;
      }
      return Geolocator.bearingBetween(
        previous.latitude!,
        previous.longitude!,
        current.latitude!,
        current.longitude!,
      );
    }
    return null;
  }
}
