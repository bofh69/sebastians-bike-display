import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
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

import '../app_constants.dart';
import '../models/bike_data.dart';
import '../models/rolling_average.dart';
import '../models/time_window_average.dart';
import '../services/heart_rate_sensor_service.dart';
import '../services/power_cadence_sensor_service.dart';
import '../services/strava_upload_service.dart';
import '../widgets/metric_tile.dart';
import '../widgets/power_bar.dart';

part 'home/home_support.dart';
part 'home/home_recovery.dart';
part 'home/home_export.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const MethodChannel _fileExportChannel = MethodChannel(
    '$kAppChannelNamespace/file_export',
  );
  static const MethodChannel _backgroundNotificationChannel = MethodChannel(
    '$kAppChannelNamespace/background_notification',
  );
  bool _isRunning = false;
  bool _isBackgroundNotificationVisible = false;
  bool _isAppInForeground = true;
  bool _serviceConfigured = false;
  Future<void>? _backgroundServiceConfigurationFuture;
  int _ftp = 200;
  final BikeData _data = BikeData();
  final List<_RideSample> _samples = [];
  final HeartRateSensorService _heartRateSensorService =
      HeartRateSensorService.instance;
  final PowerCadenceSensorService _powerCadenceSensorService =
      PowerCadenceSensorService.instance;
  final StravaUploadService _stravaUploadService = StravaUploadService.instance;
  final RollingAverage _power3sAverage = RollingAverage(windowSize: 3);
  final RollingAverage _power20MinAverage = RollingAverage(windowSize: 20 * 60);
  final TimeWindowAverage _leftBalanceAverage =
      TimeWindowAverage(window: const Duration(minutes: 1));
  final TimeWindowAverage _rightBalanceAverage =
      TimeWindowAverage(window: const Duration(minutes: 1));
  double _currentPowerWatts = 0;

  final FlutterBackgroundService _backgroundService =
      FlutterBackgroundService();

  StreamSubscription<Position>? _positionSubscription;
  Timer? _recordingTimer;
  DateTime? _startTime;
  Position? _lastAcceptedPosition;
  DateTime? _lastAcceptedTimestamp;
  double? _lastAcceptedBearingDegrees;
  double _smoothedSpeedMps = 0;
  Position? _latestPosition;
  double? _filteredAltitudeForClimb;
  double? _climbReferenceAltitude;
  DateTime? _lastCheckpointSavedAt;
  int _lastCheckpointSampleCount = 0;
  String? _lastPublishedRideCheckpointMetadataPath;
  Future<void> _rideCheckpointWriteQueue = Future<void>.value();
  Future<void>? _restoreInterruptedRideFuture;
  bool _interruptedRideRecoveryRetryScheduled = false;
  bool _isFinalizingRecoveredRide = false;

  bool get _isMobileTrackingPlatform =>
      !kIsWeb && (io.Platform.isAndroid || io.Platform.isIOS);
  bool get _supportsBackgroundRideService => !kIsWeb && io.Platform.isIOS;
  bool get _supportsRideCheckpointing => _isMobileTrackingPlatform;
  bool get _hasActiveRideRuntime => _isRunning || _isFinalizingRecoveredRide;

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
    unawaited(_stravaUploadService.initialize());
    unawaited(_hideBackgroundRideNotification(force: true));
    _startLocationStream();
    if (_supportsRideCheckpointing) {
      unawaited(_HomeScreenRecovery(this)._restoreInterruptedRideIfNeeded());
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isAppInForeground = state == AppLifecycleState.resumed;

    if (!_hasActiveRideRuntime && _isMobileTrackingPlatform) {
      if (_isAppInForeground) {
        if (!kIsWeb && io.Platform.isAndroid) {
          unawaited(_hideBackgroundRideNotification(force: true));
        }
        unawaited(_resumeSensorsAndLocationWhileIdle());
      } else if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.hidden ||
          state == AppLifecycleState.detached) {
        unawaited(_pauseSensorsAndLocationWhileIdle());
      }
      return;
    }

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(_HomeScreenRecovery(this)._persistRideCheckpoint(force: true));
    }

    if (!kIsWeb && io.Platform.isAndroid) {
      if (state == AppLifecycleState.resumed) {
        unawaited(_startLocationStream());
        unawaited(_hideBackgroundRideNotification(force: true));
        return;
      }
      if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.hidden ||
          state == AppLifecycleState.detached) {
        unawaited(_startLocationStream());
        unawaited(_showBackgroundRideNotification());
      }
    }
  }

  Future<void> _showBackgroundRideNotification() async {
    if (kIsWeb || !io.Platform.isAndroid || _isAppInForeground || !_isRunning) {
      return;
    }
    final content = _buildBackgroundRideNotificationContent();
    try {
      await _backgroundNotificationChannel.invokeMethod<void>(
        'showRideNotification',
        <String, Object>{
          'channelId': _rideTrackingNotificationChannelId,
          'notificationId': _rideTrackingForegroundServiceNotificationId,
          'title': kAppDisplayName,
          'content': content,
        },
      );
      _isBackgroundNotificationVisible = true;
    } catch (error, stackTrace) {
      _isBackgroundNotificationVisible = false;
      debugPrint('Failed to show background notification: $error\n$stackTrace');
    }
  }

  Future<void> _hideBackgroundRideNotification({bool force = false}) async {
    if (kIsWeb || !io.Platform.isAndroid) {
      return;
    }
    if (!force && !_isBackgroundNotificationVisible) {
      return;
    }
    _isBackgroundNotificationVisible = false;
    try {
      await _backgroundNotificationChannel.invokeMethod<void>(
        'hideRideNotification',
        <String, Object>{
          'notificationId': _rideTrackingForegroundServiceNotificationId,
        },
      );
    } catch (error, stackTrace) {
      _isBackgroundNotificationVisible = true;
      debugPrint('Failed to hide background notification: $error\n$stackTrace');
    }
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
    final isConnected = powerState.isConnected;
    final power = powerState.power;
    final cadence = powerState.cadence;
    var leftBalance = powerState.leftBalance;
    var rightBalance = powerState.rightBalance;
    final double normalizedPower = power ?? 0.0;
    _currentPowerWatts = normalizedPower;
    if (!isConnected) {
      _leftBalanceAverage.clear();
      _rightBalanceAverage.clear();
      leftBalance = null;
      rightBalance = null;
    } else if (shouldAccumulatePowerBalanceSample(
      isConnected: isConnected,
      power: power,
      leftBalance: leftBalance,
      rightBalance: rightBalance,
    )) {
      final now = DateTime.now();
      final currentLeftBalance = leftBalance!;
      final currentRightBalance = rightBalance!;
      leftBalance = _leftBalanceAverage.add(now, currentLeftBalance);
      rightBalance = _rightBalanceAverage.add(now, currentRightBalance);
    } else {
      leftBalance = _leftBalanceAverage.average;
      rightBalance = _rightBalanceAverage.average;
    }
    final double? displayedPower3s = !isConnected
        ? null
        : _isRunning
            ? _data.power3s
            : (normalizedPower > 0 ? normalizedPower : 0.0);
    if (_data.power3s == displayedPower3s &&
        _data.cadence == cadence &&
        _data.leftBalance == leftBalance &&
        _data.rightBalance == rightBalance) {
      return;
    }
    setState(() {
      _data.power3s = displayedPower3s;
      _data.cadence = cadence;
      _data.leftBalance = leftBalance;
      _data.rightBalance = rightBalance;
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
          isForegroundMode: false,
          notificationChannelId: _rideTrackingNotificationChannelId,
          initialNotificationTitle: kAppDisplayName,
          initialNotificationContent: _rideTrackingNotificationContent,
          foregroundServiceNotificationId:
              _rideTrackingForegroundServiceNotificationId,
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
    if (!_isRunning && !_isAppInForeground) return;
    final hasPermission = await _ensureLocationPermission();
    if (!hasPermission) return;

    final LocationSettings settings;
    if (!kIsWeb && io.Platform.isAndroid && _isRunning && !_isAppInForeground) {
      settings = AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: kAppDisplayName,
          notificationText: _rideTrackingNotificationContent,
          enableWakeLock: true,
        ),
      );
    } else {
      settings = const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
      );
    }

    await _positionSubscription?.cancel();
    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: settings,
    ).listen(_handlePosition);
  }

  Future<void> _stopLocationStream() async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;
  }

  Future<void> _pauseSensorsAndLocationWhileIdle() async {
    await _stopLocationStream();
    await _heartRateSensorService.disconnectFromDeviceForBackgroundIdle();
    await _powerCadenceSensorService.disconnectFromDeviceForBackgroundIdle();
  }

  Future<void> _resumeSensorsAndLocationWhileIdle() async {
    await _heartRateSensorService.reconnectDeviceAfterBackgroundIdle();
    await _powerCadenceSensorService.reconnectDeviceAfterBackgroundIdle();
    await _startLocationStream();
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

  void _applyState(VoidCallback updates) {
    setState(updates);
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
      _lastAcceptedBearingDegrees = null;
      _smoothedSpeedMps = 0;
      if (_isRunning && position.altitude.isFinite) {
        _filteredAltitudeForClimb = position.altitude;
        _climbReferenceAltitude = position.altitude;
      }
      if (mounted) {
        setState(() {
          _data.speed = 0;
        });
      }
      return;
    }

    final deltaSeconds =
        now.difference(previousTimestamp).inMilliseconds / 1000;
    if (deltaSeconds <= 0) return;

    final distanceMeters = Geolocator.distanceBetween(
      previousPosition.latitude,
      previousPosition.longitude,
      position.latitude,
      position.longitude,
    );

    final rawSpeedMps = distanceMeters / deltaSeconds;
    final isLikelyMoving =
        (_smoothedSpeedMps > 1.5) || ((_data.cadence ?? 0) >= 20);
    final jitterThreshold = _adaptiveJitterThresholdMeters(
      accuracyMeters: position.accuracy,
      isLikelyMoving: isLikelyMoving,
    );
    final bearingDegrees = Geolocator.bearingBetween(
      previousPosition.latitude,
      previousPosition.longitude,
      position.latitude,
      position.longitude,
    );
    if (distanceMeters < jitterThreshold ||
        rawSpeedMps > 25 ||
        _failsContinuityChecks(
          candidateSpeedMps: rawSpeedMps,
          deltaSeconds: deltaSeconds,
          bearingDegrees: bearingDegrees,
        )) {
      if (mounted &&
          distanceMeters < jitterThreshold &&
          (_data.speed ?? 0) > 0) {
        _smoothedSpeedMps =
            _smoothSpeedMps(rawSpeedMps: 0, deltaSeconds: deltaSeconds);
        setState(() {
          _data.speed = _smoothedSpeedMps * 3.6;
        });
      }
      return;
    }
    _lastAcceptedPosition = position;
    _lastAcceptedTimestamp = now;
    _lastAcceptedBearingDegrees = bearingDegrees;

    _smoothedSpeedMps = _smoothSpeedMps(
      rawSpeedMps: rawSpeedMps,
      deltaSeconds: deltaSeconds,
    );
    final currentAltitude = position.altitude;
    var additionalClimb = 0.0;
    if (_isRunning && currentAltitude.isFinite) {
      final climbUpdate = updateClimbTracking(
        previousFilteredAltitude: _filteredAltitudeForClimb,
        previousClimbReferenceAltitude: _climbReferenceAltitude,
        currentAltitude: currentAltitude,
      );
      _filteredAltitudeForClimb = climbUpdate.filteredAltitude;
      _climbReferenceAltitude = climbUpdate.climbReferenceAltitude;
      additionalClimb = climbUpdate.additionalClimb;
    }
    if (mounted) {
      setState(() {
        _data.speed = _smoothedSpeedMps * 3.6;
        if (_isRunning) {
          _data.distance = (_data.distance ?? 0) + distanceMeters / 1000;
          if (additionalClimb > 0) {
            _data.totalClimb = (_data.totalClimb ?? 0) + additionalClimb;
          }
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
      _data.power3s = _power3sAverage.add(_currentPowerWatts);
      _data.power20min = _power20MinAverage.add(_currentPowerWatts);
    });

    _samples.add(
      _RideSample(
        timestamp: now,
        latitude: _latestPosition?.latitude,
        longitude: _latestPosition?.longitude,
        altitudeMeters: _latestPosition?.altitude,
        accuracyMeters: _latestPosition?.accuracy,
        gpsConfidence: _gpsConfidenceFromAccuracy(_latestPosition?.accuracy),
        power: _currentPowerWatts,
        cadence: _data.cadence,
        heartRate: _data.heartRate,
        distanceMeters: (_data.distance ?? 0) * 1000,
        speedMps: (_data.speed ?? 0) / 3.6,
      ),
    );
    unawaited(_HomeScreenRecovery(this)._persistRideCheckpoint());
    if (!kIsWeb && io.Platform.isAndroid && !_isAppInForeground) {
      unawaited(_showBackgroundRideNotification());
    }
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

    final canStartForegroundTracking =
        await _ensureForegroundTrackingPermission();
    if (!canStartForegroundTracking) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Notification permission is required.')),
      );
      return;
    }

    final readyToRun = await _prepareRideRuntime();
    if (!readyToRun) return;
    await _HomeScreenRecovery(this)._clearRideCheckpoint();

    setState(() {
      _isRunning = true;
      _data.distance = 0;
      _data.duration = Duration.zero;
      _data.avgSpeed = 0;
      _data.speed = 0;
      _data.power3s = 0;
      _data.power20min = 0;
      _data.totalClimb = 0;
      _startTime = DateTime.now();
      _samples.clear();
      _lastAcceptedPosition = null;
      _lastAcceptedTimestamp = null;
      _lastAcceptedBearingDegrees = null;
      _smoothedSpeedMps = 0;
      _filteredAltitudeForClimb = null;
      _climbReferenceAltitude = null;
      _leftBalanceAverage.clear();
      _rightBalanceAverage.clear();
      _power3sAverage.reset();
      _power20MinAverage.reset();
      _lastCheckpointSavedAt = null;
      _lastCheckpointSampleCount = 0;
    });

    _recordSample();
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
  }

  Future<bool> _prepareRideRuntime() async {
    if (_supportsBackgroundRideService) {
      try {
        await _configureBackgroundService();
        final started = await _backgroundService.startService();
        if (!started) {
          throw Exception('Unable to start ride tracking service.');
        }
      } catch (error, stackTrace) {
        debugPrint(
            'Failed to start ride tracking service: $error\n$stackTrace');
        if (!mounted) return false;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to start ride tracking service: $error'),
          ),
        );
        return false;
      }
    }
    if (_isMobileTrackingPlatform) {
      try {
        await WakelockPlus.enable();
      } catch (error, stackTrace) {
        debugPrint('Failed to enable wakelock: $error\n$stackTrace');
      }
    }
    return true;
  }

  Future<bool> _ensureForegroundTrackingPermission() async {
    if (kIsWeb || !io.Platform.isAndroid) return true;
    final status = await Permission.notification.request();
    return status.isGranted;
  }

  Future<void> _endRide() async {
    _recordingTimer?.cancel();
    _recordingTimer = null;
    await _HomeScreenRecovery(this)._stopActiveRideRuntime();

    setState(() {
      _isRunning = false;
    });
    if (!kIsWeb && io.Platform.isAndroid && _isAppInForeground) {
      try {
        await _startLocationStream();
      } catch (error, stackTrace) {
        debugPrint(
          'Failed to reconfigure location stream after ride end: $error\n$stackTrace',
        );
      }
    }
    if (!_isAppInForeground && _isMobileTrackingPlatform) {
      try {
        await _pauseSensorsAndLocationWhileIdle();
      } catch (error, stackTrace) {
        debugPrint(
          'Failed to pause sensors/location after ride end: $error\n$stackTrace',
        );
      }
    }

    await _HomeScreenExport(this)._finalizeRide(
      rideStartTime: _startTime,
      rideSamples: List<_RideSample>.from(_samples),
      completionPrefix: 'Ride ended.',
      preserveCheckpointOnFailure: false,
    );
  }

  String _escapeXmlText(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  String _formatDuration(Duration? d) {
    if (d == null) return 'N/A';
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _formatBalance() {
    return formatPowerBalance(_data.leftBalance, _data.rightBalance);
  }

  String _buildBackgroundRideNotificationContent() {
    final distanceKm = _data.distance ?? 0;
    return 'Duration ${_formatDuration(_data.duration)} · Distance ${distanceKm.toStringAsFixed(2)} km';
  }

  Future<StravaUploadDecision> _selectStravaUploadDecision() async {
    final bikes = await _stravaUploadService.listAthleteBikes();
    if (!mounted) {
      return const StravaUploadDecision(
        skipUpload: true,
        selectedGearId: null,
        clearGear: false,
      );
    }
    final decision = await showDialog<StravaUploadDecision>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Upload to Strava'),
        children: [
          if (bikes.isNotEmpty)
            for (final bike in bikes)
              SimpleDialogOption(
                onPressed: () {
                  Navigator.of(context).pop(
                    StravaUploadDecision(
                      skipUpload: false,
                      selectedGearId: bike.gearId,
                      clearGear: false,
                    ),
                  );
                },
                child:
                    Text(bike.isDefault ? '${bike.name} (default)' : bike.name),
              ),
          if (bikes.isEmpty)
            Semantics(
              label:
                  'No Strava bikes found. Reconnect Strava if you recently updated the app.',
              liveRegion: true,
              child: const ExcludeSemantics(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                  child: Text(
                    'No Strava bikes found. Reconnect Strava if you recently updated the app.',
                  ),
                ),
              ),
            ),
          SimpleDialogOption(
            onPressed: () {
              Navigator.of(context).pop(
                const StravaUploadDecision(
                  skipUpload: false,
                  selectedGearId: null,
                  clearGear: true,
                ),
              );
            },
            child: const Text('None'),
          ),
          SimpleDialogOption(
            onPressed: () {
              Navigator.of(context).pop(
                const StravaUploadDecision(
                  skipUpload: true,
                  selectedGearId: null,
                  clearGear: false,
                ),
              );
            },
            child: const Text("Don't send to Strava"),
          ),
        ],
      ),
    );
    return decision ??
        const StravaUploadDecision(
          skipUpload: true,
          selectedGearId: null,
          clearGear: false,
        );
  }

  bool get _isPowerSensorConnected =>
      _powerCadenceSensorService.state.value.isConnected;

  bool get _hasReliableGpsForSpeed {
    final latest = _latestPosition;
    if (latest == null) return false;
    return latest.accuracy > 0 && latest.accuracy <= 35;
  }

  double _adaptiveJitterThresholdMeters({
    required double accuracyMeters,
    required bool isLikelyMoving,
  }) {
    final normalizedAccuracy = accuracyMeters.clamp(3.0, 25.0).toDouble();
    if (isLikelyMoving) {
      return (normalizedAccuracy * 0.7).clamp(2.0, 12.0).toDouble();
    }
    return (normalizedAccuracy * 1.4).clamp(4.0, 20.0).toDouble();
  }

  double _smoothSpeedMps({
    required double rawSpeedMps,
    required double deltaSeconds,
  }) {
    if (deltaSeconds <= 0) return _smoothedSpeedMps;
    final alpha = deltaSeconds >= 1 ? 0.35 : (0.2 + (deltaSeconds * 0.15));
    final clampedAlpha = alpha.clamp(0.2, 0.6).toDouble();
    final smoothed =
        _smoothedSpeedMps + (rawSpeedMps - _smoothedSpeedMps) * clampedAlpha;
    if (!smoothed.isFinite || smoothed < 0) return 0;
    if (smoothed < 0.15 && rawSpeedMps < 0.2) return 0;
    return smoothed;
  }

  bool _failsContinuityChecks({
    required double candidateSpeedMps,
    required double deltaSeconds,
    required double bearingDegrees,
  }) {
    if (deltaSeconds <= 0) return true;

    final acceleration = (candidateSpeedMps - _smoothedSpeedMps) / deltaSeconds;
    if (acceleration > 3.5 || acceleration < -6.5) {
      return true;
    }

    final previousBearing = _lastAcceptedBearingDegrees;
    if (previousBearing == null ||
        candidateSpeedMps < 2 ||
        _smoothedSpeedMps < 2) {
      return false;
    }

    final headingDelta = _bearingDeltaDegrees(previousBearing, bearingDegrees);
    final headingRate = headingDelta / deltaSeconds;
    return headingRate > 95;
  }

  double _bearingDeltaDegrees(double from, double to) {
    final delta = (to - from).abs() % 360;
    return delta > 180 ? 360 - delta : delta;
  }

  double _gpsConfidenceFromAccuracy(double? accuracyMeters) {
    if (accuracyMeters == null ||
        !accuracyMeters.isFinite ||
        accuracyMeters <= 0) {
      return 0;
    }
    if (accuracyMeters <= 5) return 1;
    if (accuracyMeters >= 50) return 0;
    return ((50 - accuracyMeters) / 45).clamp(0, 1).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: _isRunning
          ? colorScheme.surface
          : Color.alphaBlend(
              colorScheme.error.withOpacity(0.30),
              colorScheme.surface,
            ),
      appBar: AppBar(
        title: const Text(kAppDisplayName),
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
            const SizedBox(height: 16),
            PowerBar(
              power: _isPowerSensorConnected ? _data.power3s : null,
              ftp: _ftp.toDouble(),
            ),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 2.0,
              children: [
                MetricTile(
                  title: 'Power (3s)',
                  value: _isPowerSensorConnected
                      ? (_data.power3s?.toStringAsFixed(0) ?? 'N/A')
                      : 'N/A',
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
                  title: 'Speed',
                  value: _data.speed?.toStringAsFixed(1) ?? 'N/A',
                  unit: 'km/h',
                  valueColor: _hasReliableGpsForSpeed
                      ? null
                      : Theme.of(context).colorScheme.error,
                ),
                MetricTile(
                  title: 'Duration',
                  value: _formatDuration(_data.duration),
                  unit: '',
                ),
                MetricTile(
                  title: 'Distance',
                  value: _data.distance?.toStringAsFixed(2) ?? 'N/A',
                  unit: 'km',
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
                  value: _isPowerSensorConnected
                      ? (_data.power20min?.toStringAsFixed(0) ?? 'N/A')
                      : 'N/A',
                  unit: 'W',
                ),
                MetricTile(
                  title: 'Total Climb',
                  value: _data.totalClimb?.toStringAsFixed(0) ?? 'N/A',
                  unit: 'm',
                ),
              ],
            ),
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
