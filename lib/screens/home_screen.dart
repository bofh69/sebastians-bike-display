import 'dart:async';
import 'dart:io' as io;
import 'dart:ui';

import 'package:fit_sdk/fit_sdk.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/bike_data.dart';
import '../services/heart_rate_sensor_service.dart';
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
  final double? power;
  final double? heartRate;
  final double distanceMeters;

  const _RideSample({
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    required this.power,
    required this.heartRate,
    required this.distanceMeters,
  });
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  bool _isRunning = false;
  bool _serviceConfigured = false;
  bool _isAppInBackground = false;
  int _ftp = 200;
  final BikeData _data = BikeData();
  final List<_RideSample> _samples = [];
  final HeartRateSensorService _heartRateSensorService =
      HeartRateSensorService.instance;

  final FlutterBackgroundService _backgroundService = FlutterBackgroundService();

  StreamSubscription<Position>? _positionSubscription;
  Timer? _recordingTimer;
  DateTime? _startTime;
  Position? _lastAcceptedPosition;
  DateTime? _lastAcceptedTimestamp;
  Position? _latestPosition;

  bool get _isMobileTrackingPlatform =>
      !kIsWeb && (io.Platform.isAndroid || io.Platform.isIOS);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadPreferences();
    if (_isMobileTrackingPlatform) {
      _configureBackgroundService();
    }
    unawaited(_heartRateSensorService.initialize());
    _heartRateSensorService.state.addListener(_syncHeartRateData);
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
    if (_isRunning && _isMobileTrackingPlatform) {
      WakelockPlus.disable();
    }
    if (_serviceConfigured) {
      _backgroundService.invoke('stopService');
    }

    void _syncHeartRateData() {
      if (!mounted) return;
      final heartRate = _heartRateSensorService.state.value.heartRate;
      if (_data.heartRate == heartRate) return;
      setState(() {
        _data.heartRate = heartRate;
      });
    }
    super.dispose();
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
    if (position.accuracy > 35) return;

    final now = position.timestamp;
    final previousPosition = _lastAcceptedPosition;
    final previousTimestamp = _lastAcceptedTimestamp;
    _latestPosition = position;

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
        power: _data.power3s,
        heartRate: _data.heartRate,
        distanceMeters: (_data.distance ?? 0) * 1000,
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

    if (_isMobileTrackingPlatform) {
      await _configureBackgroundService();
      await _backgroundService.startService();
      _backgroundService.invoke('setAsForeground');
      await WakelockPlus.enable();
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

  Future<void> _endRide() async {
    _recordingTimer?.cancel();
    _recordingTimer = null;
    if (_isMobileTrackingPlatform) {
      await WakelockPlus.disable();
    }
    if (_serviceConfigured) {
      _backgroundService.invoke('stopService');
    }

    setState(() {
      _isRunning = false;
    });

    final fitPath = await _writeFitFile();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          fitPath == null
              ? 'Ride ended. No FIT file written (no samples).'
              : 'Ride saved to $fitPath',
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
        ..setFieldValue(6, (_data.speed ?? 0) / 3.6);

      if (sample.latitude != null) {
        record.setFieldValue(0, (sample.latitude! * 11930464.7111).round());
      }
      if (sample.longitude != null) {
        record.setFieldValue(1, (sample.longitude! * 11930464.7111).round());
      }
      if (sample.heartRate != null) {
        record.setFieldValue(3, sample.heartRate!.round());
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

    final docsDir = await getApplicationDocumentsDirectory();
    final fileName = 'ride_${start.toIso8601String().replaceAll(':', '-')}.fit';
    final file = io.File('${docsDir.path}/$fileName');
    await file.writeAsBytes(fitBytes, flush: true);
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
                  _isAppInBackground
                      ? 'Recording continues while app is in background.'
                      : 'Recording active (background tracking enabled).',
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
