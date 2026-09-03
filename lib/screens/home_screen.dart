import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';
import 'dart:ui';

import 'package:fit_sdk/fit_sdk.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/bike_data.dart';
import '../services/heart_rate_sensor_service.dart';
import '../services/power_cadence_sensor_service.dart';
import '../widgets/metric_tile.dart';
import '../widgets/power_bar.dart';

const int _fitEpochOffsetSeconds = 631065600;

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
  final double? power;
  final double? cadence;
  final double? heartRate;
  final double distanceMeters;
  final double speedMps;

  const _RideSample({
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    required this.altitudeMeters,
    required this.power,
    required this.cadence,
    required this.heartRate,
    required this.distanceMeters,
    required this.speedMps,
  });
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const MethodChannel _fileExportChannel = MethodChannel(
    'simple_bike_display/file_export',
  );
  bool _isRunning = false;
  bool _serviceConfigured = false;
  Future<void>? _backgroundServiceConfigurationFuture;
  bool _isAppInBackground = false;
  int _ftp = 200;
  final BikeData _data = BikeData();
  final List<_RideSample> _samples = [];
  final HeartRateSensorService _heartRateSensorService =
      HeartRateSensorService.instance;
  final PowerCadenceSensorService _powerCadenceSensorService =
      PowerCadenceSensorService.instance;

  final FlutterBackgroundService _backgroundService = FlutterBackgroundService();

  StreamSubscription<Position>? _positionSubscription;
  Timer? _recordingTimer;
  DateTime? _startTime;
  Position? _lastAcceptedPosition;
  DateTime? _lastAcceptedTimestamp;
  Position? _latestPosition;

  bool get _isMobileTrackingPlatform =>
      !kIsWeb && (io.Platform.isAndroid || io.Platform.isIOS);
  bool get _supportsBackgroundRideService => !kIsWeb && io.Platform.isIOS;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadPreferences();
    if (_supportsBackgroundRideService) {
      unawaited(_preconfigureBackgroundService());
    }
    unawaited(_heartRateSensorService.initialize());
    _heartRateSensorService.state.addListener(_syncHeartRateData);
    unawaited(_powerCadenceSensorService.initialize());
    _powerCadenceSensorService.state.addListener(_syncPowerCadenceData);
    _startLocationStream();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isAppInBackground = state != AppLifecycleState.resumed;
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _positionSubscription?.cancel();
    _recordingTimer?.cancel();
    _heartRateSensorService.state.removeListener(_syncHeartRateData);
    _powerCadenceSensorService.state.removeListener(_syncPowerCadenceData);
    if (_isRunning && _isMobileTrackingPlatform) {
      WakelockPlus.disable();
    }
    if (_supportsBackgroundRideService && _serviceConfigured) {
      _backgroundService.invoke('stopService');
    }
    super.dispose();
  }

  void _syncHeartRateData() {
    if (!mounted) return;
    final heartRate = _heartRateSensorService.state.value.heartRate;
    if (_data.heartRate == heartRate) return;
    setState(() {
      _data.heartRate = heartRate;
    });
  }

  void _syncPowerCadenceData() {
    if (!mounted) return;
    final powerState = _powerCadenceSensorService.state.value;
    final power = powerState.power;
    final cadence = powerState.cadence;
    if (_data.power3s == power && _data.cadence == cadence) return;
    setState(() {
      _data.power3s = power;
      _data.cadence = cadence;
    });
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _ftp = prefs.getInt('ftp') ?? 200;
    });
  }

  Future<void> _configureBackgroundService() async {
    if (_serviceConfigured) return;
    _backgroundServiceConfigurationFuture ??=
        _configureBackgroundServiceInternal();
    await _backgroundServiceConfigurationFuture;
  }

  Future<void> _preconfigureBackgroundService() async {
    try {
      await _configureBackgroundService();
    } catch (error, stackTrace) {
      debugPrint(
        'Background service preconfiguration failed: $error\n$stackTrace',
      );
    }
  }

  Future<void> _configureBackgroundServiceInternal() async {
    try {
      await _backgroundService.configure(
        androidConfiguration: AndroidConfiguration(
          onStart: rideBackgroundServiceStart,
          autoStart: false,
          isForegroundMode: true,
          notificationChannelId: 'ride_tracking',
          initialNotificationTitle: 'Simple Bike Display',
          initialNotificationContent: 'Ride recording active in background',
          foregroundServiceNotificationId: 888,
        ),
        iosConfiguration: IosConfiguration(
          autoStart: false,
          onForeground: rideBackgroundServiceStart,
        ),
      );
      _serviceConfigured = true;
    } finally {
      _backgroundServiceConfigurationFuture = null;
    }
  }

  Future<void> _startLocationStream() async {
    if (!_isMobileTrackingPlatform) return;
    final hasPermission = await _ensureLocationPermission();
    if (!hasPermission) return;

    const settings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
    );

    await _positionSubscription?.cancel();
    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: settings,
    ).listen(_handlePosition);
  }

  Future<bool> _ensureLocationPermission() async {
    if (!_isMobileTrackingPlatform) return true;
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return false;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  void _handlePosition(Position position) {
    final wasReliableGpsForSpeed = _hasReliableGpsForSpeed;
    _latestPosition = position;
    if (position.accuracy > 35) {
      if (wasReliableGpsForSpeed && mounted) {
        setState(() {});
      }
      return;
    }

    final now = position.timestamp;
    final previousPosition = _lastAcceptedPosition;
    final previousTimestamp = _lastAcceptedTimestamp;

    if (previousPosition == null || previousTimestamp == null) {
      _lastAcceptedPosition = position;
      _lastAcceptedTimestamp = now;
      if (mounted) {
        setState(() {
          _data.speed = position.speed > 0 ? position.speed * 3.6 : 0.0;
        });
      }
      return;
    }

    final deltaSeconds = now.difference(previousTimestamp).inMilliseconds / 1000;
    if (deltaSeconds <= 0) return;

    final distanceMeters = Geolocator.distanceBetween(
      previousPosition.latitude,
      previousPosition.longitude,
      position.latitude,
      position.longitude,
    );

    final jitterThreshold = position.accuracy.clamp(3.0, 15.0);
    final speedMps = distanceMeters / deltaSeconds;
    if (distanceMeters < jitterThreshold || speedMps > 25) {
      if (mounted && distanceMeters < jitterThreshold && (_data.speed ?? 0) > 0) {
        setState(() {
          _data.speed = 0;
        });
      }
      return;
    }
    _lastAcceptedPosition = position;
    _lastAcceptedTimestamp = now;

    if (mounted) {
      setState(() {
        _data.speed = speedMps * 3.6;
        if (_isRunning) {
          _data.distance = (_data.distance ?? 0) + distanceMeters / 1000;
          final durationSeconds =
              DateTime.now().difference(_startTime ?? DateTime.now()).inSeconds;
          if (durationSeconds > 0) {
            _data.avgSpeed = (_data.distance! / durationSeconds) * 3600;
          }
        }
      });
    }
  }

  void _recordSample() {
    if (!_isRunning) return;
    final now = DateTime.now();
    final startTime = _startTime;
    if (startTime == null) return;

    setState(() {
      _data.duration = now.difference(startTime);
    });

    _samples.add(
      _RideSample(
        timestamp: now,
        latitude: _latestPosition?.latitude,
        longitude: _latestPosition?.longitude,
        altitudeMeters: _latestPosition?.altitude,
        power: _data.power3s,
        cadence: _data.cadence,
        heartRate: _data.heartRate,
        distanceMeters: (_data.distance ?? 0) * 1000,
        speedMps: (_data.speed ?? 0) / 3.6,
      ),
    );
  }

  Future<void> _toggleRunState() async {
    if (_isRunning) {
      await _endRide();
      return;
    }

    final hasPermission = await _ensureLocationPermission();
    if (!hasPermission) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Location permission is required.')),
      );
      return;
    }

    final canStartForegroundTracking = await _ensureForegroundTrackingPermission();
    if (!canStartForegroundTracking) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Notification permission is required.')),
      );
      return;
    }

    if (_supportsBackgroundRideService) {
      try {
        await _configureBackgroundService();
        final started = await _backgroundService.startService();
        if (!started) {
          throw Exception('Unable to start ride tracking service.');
        }
        _backgroundService.invoke('setAsForeground');
      } catch (error, stackTrace) {
        debugPrint('Failed to start ride tracking service: $error\n$stackTrace');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to start ride tracking service: $error'),
          ),
        );
        return;
      }
    }
    if (_isMobileTrackingPlatform) {
      try {
        await WakelockPlus.enable();
      } catch (error, stackTrace) {
        debugPrint('Failed to enable wakelock: $error\n$stackTrace');
      }
    }

    setState(() {
      _isRunning = true;
      _data.distance = 0;
      _data.duration = Duration.zero;
      _data.avgSpeed = 0;
      _startTime = DateTime.now();
      _samples.clear();
    });

    _recordSample();
    _recordingTimer?.cancel();
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _recordSample();
    });
  }

  Future<bool> _ensureForegroundTrackingPermission() async {
    if (kIsWeb || !io.Platform.isAndroid) return true;
    final status = await Permission.notification.request();
    return status.isGranted;
  }

  Future<void> _endRide() async {
    _recordingTimer?.cancel();
    _recordingTimer = null;
    if (_isMobileTrackingPlatform) {
      await WakelockPlus.disable();
    }
    if (_supportsBackgroundRideService && _serviceConfigured) {
      _backgroundService.invoke('stopService');
    }

    setState(() {
      _isRunning = false;
    });

    final fitPath = await _writeFitFile();
    final gpxPath = await _writeGpxFile();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          fitPath == null && gpxPath == null
              ? 'Ride ended. No files written (no samples).'
              : 'Ride saved. FIT: ${fitPath ?? 'N/A'} GPX: ${gpxPath ?? 'N/A'}',
        ),
      ),
    );
  }

  int _fitTimestamp(DateTime dt) {
    return dt.toUtc().millisecondsSinceEpoch ~/ 1000 - _fitEpochOffsetSeconds;
  }

  Future<String?> _writeFitFile() async {
    if (_samples.isEmpty) return null;

    final encoder = Encode();
    encoder.open();

    final start = _samples.first.timestamp;
    final end = _samples.last.timestamp;
    final totalDistance = _samples.last.distanceMeters;
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

    for (final sample in _samples) {
      final record = Mesg.fromMesgNum(MesgNum.record)
        ..setFieldValue(253, _fitTimestamp(sample.timestamp))
        ..setFieldValue(5, sample.distanceMeters)
        ..setFieldValue(6, sample.speedMps);

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
      ..setFieldValue(7, elapsedSeconds.toDouble())
      ..setFieldValue(8, elapsedSeconds.toDouble())
      ..setFieldValue(9, totalDistance)
      ..setFieldValue(16, 2);
    final sessionDef = MesgDefinition.fromMesg(session);
    encoder.writeMesgDefinition(sessionDef);
    encoder.writeMesg(session);

    final lap = Mesg.fromMesgNum(MesgNum.lap)
      ..setFieldValue(253, _fitTimestamp(end))
      ..setFieldValue(2, _fitTimestamp(start))
      ..setFieldValue(7, elapsedSeconds.toDouble())
      ..setFieldValue(8, elapsedSeconds.toDouble())
      ..setFieldValue(9, totalDistance)
      ..setFieldValue(16, 0);
    final lapDef = MesgDefinition.fromMesg(lap);
    encoder.writeMesgDefinition(lapDef);
    encoder.writeMesg(lap);

    final activity = Mesg.fromMesgNum(MesgNum.activity)
      ..setFieldValue(253, _fitTimestamp(end))
      ..setFieldValue(0, totalDistance)
      ..setFieldValue(1, elapsedSeconds)
      ..setFieldValue(2, 1)
      ..setFieldValue(3, 0);
    final activityDef = MesgDefinition.fromMesg(activity);
    encoder.writeMesgDefinition(activityDef);
    encoder.writeMesg(activity);

    final fitBytes = encoder.close();

    final fileName = 'ride_${start.toIso8601String().replaceAll(':', '-')}.fit';
    return _writeExportFile(
      fileName: fileName,
      mimeType: 'application/octet-stream',
      bytes: fitBytes,
    );
  }

  Future<String?> _writeGpxFile() async {
    if (_samples.isEmpty) return null;

    final start = _samples.first.timestamp;
    final fileName = 'ride_${start.toIso8601String().replaceAll(':', '-')}.gpx';

    final buffer = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln(
        '<gpx version="1.1" creator="simple-bike-display" xmlns="http://www.topografix.com/GPX/1/1" xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">',
      )
      ..writeln('<metadata><time>${start.toUtc().toIso8601String()}</time></metadata>')
      ..writeln('<trk><name>Ride ${start.toIso8601String()}</name><trkseg>');

    for (final sample in _samples) {
      if (sample.latitude == null || sample.longitude == null) {
        continue;
      }
      final altitude = sample.altitudeMeters;
      final hasAltitude = altitude != null && altitude.isFinite;
      buffer.writeln(
        '<trkpt lat="${sample.latitude!.toStringAsFixed(7)}" lon="${sample.longitude!.toStringAsFixed(7)}">${hasAltitude ? '<ele>${altitude.toStringAsFixed(1)}</ele>' : ''}<time>${sample.timestamp.toUtc().toIso8601String()}</time><cmt>speed_kmh=${(sample.speedMps * 3.6).toStringAsFixed(1)} distance_km=${(sample.distanceMeters / 1000).toStringAsFixed(3)}</cmt><extensions><gpxtpx:TrackPointExtension>${sample.heartRate != null ? '<gpxtpx:hr>${sample.heartRate!.round()}</gpxtpx:hr>' : ''}${sample.cadence != null ? '<gpxtpx:cad>${sample.cadence!.round()}</gpxtpx:cad>' : ''}<gpxtpx:speed>${sample.speedMps.toStringAsFixed(2)}</gpxtpx:speed></gpxtpx:TrackPointExtension></extensions></trkpt>',
      );
    }

    buffer.writeln('</trkseg></trk></gpx>');

    return _writeExportFile(
      fileName: fileName,
      mimeType: 'application/gpx+xml',
      bytes: Uint8List.fromList(utf8.encode(buffer.toString())),
    );
  }

  Future<String> _writeExportFile({
    required String fileName,
    required String mimeType,
    required List<int> bytes,
  }) async {
    if (!kIsWeb && io.Platform.isAndroid) {
      try {
        final uriOrPath = await _fileExportChannel.invokeMethod<String>(
          'saveToDownloads',
          <String, Object>{
            'fileName': fileName,
            'mimeType': mimeType,
            'bytes': Uint8List.fromList(bytes),
          },
        );
        if (uriOrPath != null && uriOrPath.isNotEmpty) {
          return uriOrPath;
        }
      } catch (_) {
        // Fall back to app document directory.
      }
    }
    final docsDir = await getApplicationDocumentsDirectory();
    await docsDir.create(recursive: true);
    final file = io.File('${docsDir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  String _formatDuration(Duration? d) {
    if (d == null) return 'N/A';
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _formatBalance() {
    if (_data.leftBalance == null || _data.rightBalance == null) return 'N/A';
    return '${_data.leftBalance!.toStringAsFixed(0)}/${_data.rightBalance!.toStringAsFixed(0)}';
  }

  bool get _hasReliableGpsForSpeed {
    final latest = _latestPosition;
    if (latest == null) return false;
    return latest.accuracy > 0 && latest.accuracy <= 35;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Simple Bike Display'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await Navigator.pushNamed(context, '/config');
              await _loadPreferences();
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            if (_isRunning)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colorScheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _supportsBackgroundRideService
                      ? (_isAppInBackground
                          ? 'Recording continues while app is in background.'
                          : 'Recording active (background tracking enabled).')
                      : 'Recording active.',
                  style: TextStyle(color: colorScheme.onTertiaryContainer),
                ),
              ),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 2.0,
              children: [
                MetricTile(
                  title: 'Power (3s)',
                  value: _data.power3s?.toStringAsFixed(0) ?? 'N/A',
                  unit: 'W',
                ),
                MetricTile(
                  title: 'Cadence',
                  value: _data.cadence?.toStringAsFixed(0) ?? 'N/A',
                  unit: 'rpm',
                ),
                MetricTile(
                  title: 'Heart Rate',
                  value: _data.heartRate?.toStringAsFixed(0) ?? 'N/A',
                  unit: 'bpm',
                ),
                MetricTile(
                  title: 'Distance',
                  value: _data.distance?.toStringAsFixed(2) ?? 'N/A',
                  unit: 'km',
                ),
                MetricTile(
                  title: 'Duration',
                  value: _formatDuration(_data.duration),
                  unit: '',
                ),
                MetricTile(
                  title: 'Speed',
                  value: _data.speed?.toStringAsFixed(1) ?? 'N/A',
                  unit: 'km/h',
                  valueColor:
                      _hasReliableGpsForSpeed ? null : Theme.of(context).colorScheme.error,
                ),
                MetricTile(
                  title: 'L/R Balance',
                  value: _formatBalance(),
                  unit: '%',
                ),
                MetricTile(
                  title: 'Avg Speed',
                  value: _data.avgSpeed?.toStringAsFixed(1) ?? 'N/A',
                  unit: 'km/h',
                ),
                MetricTile(
                  title: 'Power (20 min)',
                  value: _data.power20min?.toStringAsFixed(0) ?? 'N/A',
                  unit: 'W',
                ),
              ],
            ),
            const SizedBox(height: 16),
            PowerBar(power: _data.power3s, ftp: _ftp.toDouble()),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: _toggleRunState,
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      _isRunning ? colorScheme.error : colorScheme.primary,
                  foregroundColor: colorScheme.onPrimary,
                ),
                child: Text(
                  _isRunning ? 'End' : 'Start',
                  style: const TextStyle(fontSize: 20),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
