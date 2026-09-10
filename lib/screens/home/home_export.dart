part of 'package:simple_bike_display/screens/home_screen.dart';

extension _HomeScreenExport on _HomeScreenState {
  int _fitTimestamp(DateTime dt) {
    return dt.toUtc().millisecondsSinceEpoch ~/ 1000 - _fitEpochOffsetSeconds;
  }

  Future<_ExportedRideFile?> _writeFitFile(
      List<_RideSample> rideSamples) async {
    if (rideSamples.isEmpty) return null;

    final encoder = Encode();
    encoder.open();

    final start = rideSamples.first.timestamp;
    final end = rideSamples.last.timestamp;
    final elapsedSeconds = end.difference(start).inSeconds.clamp(1, 1 << 30);

    final fileId = Mesg.fromMesgNum(MesgNum.fileId)
      ..setFieldValue(0, 4)
      ..setFieldValue(1, 1)
      ..setFieldValue(2, 1)
      ..setFieldValue(3, start.millisecondsSinceEpoch & 0xFFFFFFFF)
      ..setFieldValue(4, _fitTimestamp(start));
    final fileIdDef = MesgDefinition.fromMesg(fileId);
    encoder.writeMesgDefinition(fileIdDef);
    encoder.writeMesg(fileId);

    for (final sample in rideSamples) {
      final record = Mesg.fromMesgNum(MesgNum.record)
        ..setFieldValue(253, _fitTimestamp(sample.timestamp));

      if (sample.latitude != null) {
        record.setFieldValue(0, (sample.latitude! * 11930464.7111).round());
      }
      if (sample.longitude != null) {
        record.setFieldValue(1, (sample.longitude! * 11930464.7111).round());
      }
      if (sample.heartRate != null) {
        record.setFieldValue(3, sample.heartRate!.round());
      }
      if (sample.cadence != null) {
        record.setFieldValue(4, sample.cadence!.round());
      }
      if (sample.altitudeMeters != null && sample.altitudeMeters!.isFinite) {
        record.setFieldValue(2, sample.altitudeMeters);
      }
      if (sample.accuracyMeters != null && sample.accuracyMeters!.isFinite) {
        record.setFieldValue(30, sample.accuracyMeters!.round().clamp(0, 254));
      }
      if (sample.power != null) {
        record.setFieldValue(7, sample.power!.round());
      }

      final recordDef = MesgDefinition.fromMesg(record);
      encoder.writeMesgDefinition(recordDef);
      encoder.writeMesg(record);
    }

    final session = Mesg.fromMesgNum(MesgNum.session)
      ..setFieldValue(253, _fitTimestamp(end))
      ..setFieldValue(2, _fitTimestamp(start))
      ..setFieldValue(5, _fitSportCycling)
      ..setFieldValue(7, elapsedSeconds.toDouble())
      ..setFieldValue(8, elapsedSeconds.toDouble());
    final sessionDef = MesgDefinition.fromMesg(session);
    encoder.writeMesgDefinition(sessionDef);
    encoder.writeMesg(session);

    final lap = Mesg.fromMesgNum(MesgNum.lap)
      ..setFieldValue(253, _fitTimestamp(end))
      ..setFieldValue(2, _fitTimestamp(start))
      ..setFieldValue(7, elapsedSeconds.toDouble())
      ..setFieldValue(8, elapsedSeconds.toDouble())
      ..setFieldValue(25, _fitSportCycling);
    final lapDef = MesgDefinition.fromMesg(lap);
    encoder.writeMesgDefinition(lapDef);
    encoder.writeMesg(lap);

    final activity = Mesg.fromMesgNum(MesgNum.activity)
      ..setFieldValue(253, _fitTimestamp(end))
      ..setFieldValue(0, elapsedSeconds)
      ..setFieldValue(1, 1)
      ..setFieldValue(2, _fitActivityTypeManual);
    final activityDef = MesgDefinition.fromMesg(activity);
    encoder.writeMesgDefinition(activityDef);
    encoder.writeMesg(activity);

    final fitBytes = encoder.close();

    final fileName = 'ride_${start.toIso8601String().replaceAll(':', '-')}.fit';
    return _writeExportFile(
      fileName: fileName,
      mimeType: 'application/octet-stream',
      bytes: Uint8List.fromList(fitBytes),
    );
  }

  Future<_ExportedRideFile?> _writeGpxFile(
      List<_RideSample> rideSamples) async {
    if (rideSamples.isEmpty) return null;

    final start = rideSamples.first.timestamp;
    final fileName = 'ride_${start.toIso8601String().replaceAll(':', '-')}.gpx';

    final metadataTime = _escapeXmlText(start.toUtc().toIso8601String());
    final trackName = _escapeXmlText('Ride ${start.toIso8601String()}');

    final buffer = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln(
        '<gpx version="1.1" creator="sebastians-bike-display" xmlns="http://www.topografix.com/GPX/1/1" xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1" xmlns:sbd="https://sebastians-bike-display.dev/xmlschemas/TrackPointQuality/v1">',
      )
      ..writeln('<metadata><time>$metadataTime</time></metadata>')
      ..writeln('<trk><name>$trackName</name><trkseg>');

    for (final sample in rideSamples) {
      if (sample.latitude == null || sample.longitude == null) {
        continue;
      }
      final altitude = sample.altitudeMeters;
      final hasAltitude = altitude != null && altitude.isFinite;
      final hasAccuracy =
          sample.accuracyMeters != null && sample.accuracyMeters!.isFinite;
      final pointTime =
          _escapeXmlText(sample.timestamp.toUtc().toIso8601String());
      final pointComment = _escapeXmlText(
        'distance_km=${(sample.distanceMeters / 1000).toStringAsFixed(3)}',
      );
      final speedText = _escapeXmlText(sample.speedMps.toStringAsFixed(2));
      final powerText = _escapeXmlText((sample.power ?? 0).toStringAsFixed(0));
      final confidenceText = _escapeXmlText(
        sample.gpsConfidence.toStringAsFixed(2),
      );
      final altitudeText =
          hasAltitude ? _escapeXmlText(altitude.toStringAsFixed(1)) : null;
      final accuracyText = hasAccuracy
          ? _escapeXmlText(sample.accuracyMeters!.toStringAsFixed(1))
          : null;
      final heartRateText = sample.heartRate != null
          ? _escapeXmlText(sample.heartRate!.round().toString())
          : null;
      final cadenceText = sample.cadence != null
          ? _escapeXmlText(sample.cadence!.round().toString())
          : null;
      buffer.writeln(
        '<trkpt lat="${sample.latitude!.toStringAsFixed(7)}" lon="${sample.longitude!.toStringAsFixed(7)}">${altitudeText != null ? '<ele>$altitudeText</ele>' : ''}<time>$pointTime</time><cmt>$pointComment</cmt><extensions><gpxtpx:TrackPointExtension>${heartRateText != null ? '<gpxtpx:hr>$heartRateText</gpxtpx:hr>' : ''}${cadenceText != null ? '<gpxtpx:cad>$cadenceText</gpxtpx:cad>' : ''}<gpxtpx:speed>$speedText</gpxtpx:speed></gpxtpx:TrackPointExtension><sbd:power_w>$powerText</sbd:power_w>${accuracyText != null ? '<sbd:gps_accuracy_m>$accuracyText</sbd:gps_accuracy_m>' : ''}<sbd:gps_confidence>$confidenceText</sbd:gps_confidence></extensions></trkpt>',
      );
    }

    buffer.writeln('</trkseg></trk></gpx>');

    return _writeExportFile(
      fileName: fileName,
      mimeType: 'application/gpx+xml',
      bytes: Uint8List.fromList(utf8.encode(buffer.toString())),
    );
  }

  Future<_ExportedRideFile> _writeExportFile({
    required String fileName,
    required String mimeType,
    required Uint8List bytes,
  }) async {
    String? uriOrPath;
    if (!kIsWeb && io.Platform.isAndroid) {
      try {
        uriOrPath =
            await _HomeScreenState._fileExportChannel.invokeMethod<String>(
          'saveToDownloads',
          <String, Object>{
            'fileName': fileName,
            'mimeType': mimeType,
            'bytes': bytes,
          },
        );
        if (uriOrPath != null && uriOrPath.isNotEmpty) {
          return _ExportedRideFile(
            fileName: fileName,
            path: uriOrPath,
            bytes: bytes,
          );
        }
      } catch (_) {
        // Fall back to app document directory.
      }
    }
    final docsDir = await getApplicationDocumentsDirectory();
    await docsDir.create(recursive: true);
    final file = io.File('${docsDir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return _ExportedRideFile(fileName: fileName, path: file.path, bytes: bytes);
  }

  Future<bool> _finalizeRide({
    required DateTime? rideStartTime,
    required List<_RideSample> rideSamples,
    required String completionPrefix,
    bool preserveCheckpointOnFailure = true,
    bool requireCurrentRouteForUpload = false,
  }) async {
    final rideMidpointTime = rideSamples.isEmpty
        ? rideStartTime
        : rideSamples.first.timestamp.add(
            Duration(
              milliseconds: rideSamples.last.timestamp
                      .difference(rideSamples.first.timestamp)
                      .inMilliseconds ~/
                  2,
            ),
          );
    _ExportedRideFile? fitFile;
    _ExportedRideFile? gpxFile;
    try {
      fitFile = await _writeFitFile(rideSamples);
    } catch (error, stackTrace) {
      debugPrint('Failed to export FIT file: $error\n$stackTrace');
    }
    try {
      gpxFile = await _writeGpxFile(rideSamples);
    } catch (error, stackTrace) {
      debugPrint('Failed to export GPX file: $error\n$stackTrace');
    }
    StravaUploadResult uploadResult = const StravaUploadResult.skipped();
    var deferredUploadUntilRouteReady = false;
    if (fitFile != null) {
      final stravaState = _stravaUploadService.state.value;
      if (stravaState.autoUploadEnabled && stravaState.isAuthenticated) {
        try {
          var shouldPromptForUpload = false;
          if (mounted) {
            final route = ModalRoute.of(context);
            shouldPromptForUpload = route == null || route.isCurrent;
          }
          if ((requireCurrentRouteForUpload || preserveCheckpointOnFailure) &&
              !shouldPromptForUpload) {
            uploadResult = const StravaUploadResult(
              attempted: false,
              succeeded: false,
              message: 'Strava upload deferred until the app is ready.',
              activityId: null,
            );
            deferredUploadUntilRouteReady = true;
          } else {
            final resolvedDecision = shouldPromptForUpload
                ? resolveStravaUploadDecision(
                    await _selectStravaUploadDecision(),
                  )
                : (
                    shouldUpload: false,
                    selectedGearId: null,
                    clearGear: false,
                  );
            if (!resolvedDecision.shouldUpload) {
              uploadResult = const StravaUploadResult(
                attempted: false,
                succeeded: false,
                message: 'Strava upload skipped.',
                activityId: null,
              );
            } else {
              uploadResult = await _stravaUploadService.uploadFinishedRide(
                fileName: fitFile.fileName,
                fileBytes: fitFile.bytes,
                midpointAt: rideMidpointTime,
                selectedGearId: resolvedDecision.selectedGearId,
                clearGear: resolvedDecision.clearGear,
              );
            }
          }
        } catch (error, stackTrace) {
          debugPrint('Strava upload flow failed: $error\n$stackTrace');
          uploadResult = const StravaUploadResult(
            attempted: true,
            succeeded: false,
            message: 'Strava upload failed.',
            activityId: null,
          );
        }
      }
    }
    final completedSuccessfully = didRecoveredRideFinalizeCompletely(
          hasSamples: rideSamples.isNotEmpty,
          fitExported: fitFile != null,
          gpxExported: gpxFile != null,
          uploadAttempted: uploadResult.attempted,
          uploadSucceeded: uploadResult.succeeded,
        ) &&
        !deferredUploadUntilRouteReady;
    if (!deferredUploadUntilRouteReady &&
        shouldClearRideCheckpointAfterFinalization(
          completedSuccessfully: completedSuccessfully,
          preserveCheckpointOnFailure: preserveCheckpointOnFailure,
        )) {
      await _HomeScreenRecovery(this)._clearRideCheckpoint();
    }
    if (!mounted) return completedSuccessfully;
    final route = ModalRoute.of(context);
    if (route == null || route.isCurrent) {
      final rideSavedMessage = switch ((fitFile, gpxFile)) {
        (null, null) => '$completionPrefix No files written (no samples).',
        (_ExportedRideFile fit, _ExportedRideFile gpx) =>
          '$completionPrefix FIT: ${fit.path} GPX: ${gpx.path}',
        (_ExportedRideFile fit, null) =>
          '$completionPrefix FIT saved to ${fit.path}. GPX export failed.',
        (null, _ExportedRideFile gpx) =>
          '$completionPrefix GPX saved to ${gpx.path}. FIT export failed.',
      };
      final uploadMessage =
          uploadResult.message == null ? '' : ' ${uploadResult.message}';
      final retryMessage = completedSuccessfully || !preserveCheckpointOnFailure
          ? ''
          : ' Recovery data kept so the ride can be retried.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$rideSavedMessage$uploadMessage$retryMessage'),
        ),
      );
    }
    return completedSuccessfully;
  }
}
