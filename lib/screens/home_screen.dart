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

const int _fitEpochOffsetSeconds = 631065600;
const int _fitSportCycling = 2;
const int _fitActivityTypeManual = 0;
const double _minimumPowerForBalanceAverageWatts = 10;
const double _climbAltitudeSmoothingFactor = 0.25;
const double _minimumClimbGainMeters = 0.75;
const String _rideTrackingNotificationChannelId = 'ride_tracking';
const int _rideTrackingForegroundServiceNotificationId = 888;
const String _rideTrackingNotificationContent =
    'Ride recording active in background';

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
    required this.distanceMeters,
    required this.speedMps,
  });
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
  bool _isEnteringBackgroundRideMode = false;
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

  final FlutterBackgroundService _backgroundService = FlutterBackgroundService();

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

  bool get _isMobileTrackingPlatform =>
      !kIsWeb && (io.Platform.isAndroid || io.Platform.isIOS);
  bool get _supportsBackgroundRideService =>
      !kIsWeb && (io.Platform.isAndroid || io.Platform.isIOS);

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

    if (!_isRunning && _isMobileTrackingPlatform) {
      if (_isAppInForeground) {
        unawaited(_resumeSensorsAndLocationWhileIdle());
      } else if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.hidden ||
          state == AppLifecycleState.detached) {
        unawaited(_pauseSensorsAndLocationWhileIdle());
      }
      return;
    }

    if (!kIsWeb && io.Platform.isAndroid) {
      if (state == AppLifecycleState.resumed) {
        unawaited(_exitBackgroundRideMode());
        return;
      }
      if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.hidden ||
          state == AppLifecycleState.detached) {
        unawaited(_enterBackgroundRideMode());
      }
    }
  }

  Future<void> _enterBackgroundRideMode() async {
    if (kIsWeb || !io.Platform.isAndroid || !_isRunning || _isAppInForeground) {
      return;
    }
    if (_isEnteringBackgroundRideMode) return;
    _isEnteringBackgroundRideMode = true;
    try {
      await _configureBackgroundService();
      final serviceRunning = await _backgroundService.isRunning();
      if (!serviceRunning) {
        final started = await _backgroundService.startService();
        if (!started) {
          throw Exception('Unable to start ride tracking service.');
        }
      }
      _backgroundService.invoke('setAsForeground');
    } catch (error, stackTrace) {
      debugPrint(
        'Failed to enter Android background ride mode: $error\n$stackTrace',
      );
    } finally {
      _isEnteringBackgroundRideMode = false;
    }
    await _showBackgroundRideNotification();
  }

  Future<void> _exitBackgroundRideMode() async {
    await _hideBackgroundRideNotification(force: true);
    if (_serviceConfigured && !kIsWeb && io.Platform.isAndroid) {
      _backgroundService.invoke('stopService');
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

    await _positionSubscription?.cancel();
    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
      ),
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

    final deltaSeconds = now.difference(previousTimestamp).inMilliseconds / 1000;
    if (deltaSeconds <= 0) return;

    final distanceMeters = Geolocator.distanceBetween(
      previousPosition.latitude,
      previousPosition.longitude,
      position.latitude,
      position.longitude,
    );

    final rawSpeedMps = distanceMeters / deltaSeconds;
    final isLikelyMoving = (_smoothedSpeedMps > 1.5) || ((_data.cadence ?? 0) >= 20);
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
      if (mounted && distanceMeters < jitterThreshold && (_data.speed ?? 0) > 0) {
        _smoothedSpeedMps = _smoothSpeedMps(rawSpeedMps: 0, deltaSeconds: deltaSeconds);
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

    final canStartForegroundTracking = await _ensureForegroundTrackingPermission();
    if (!canStartForegroundTracking) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Notification permission is required.')),
      );
      return;
    }

    if (_supportsBackgroundRideService && !kIsWeb && io.Platform.isIOS) {
      try {
        await _configureBackgroundService();
        final started = await _backgroundService.startService();
        if (!started) {
          throw Exception('Unable to start ride tracking service.');
        }
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
        unawaited(_enterBackgroundRideMode());
      }
    }
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
    await _hideBackgroundRideNotification(force: true);
    if (_supportsBackgroundRideService && _serviceConfigured) {
      _backgroundService.invoke('stopService');
    }

    setState(() {
      _isRunning = false;
    });
    if (!_isAppInForeground && _isMobileTrackingPlatform) {
      await _pauseSensorsAndLocationWhileIdle();
    }

    final rideStartTime = _startTime;
    final rideMidpointTime = _samples.isEmpty
        ? rideStartTime
        : _samples.first.timestamp.add(
            Duration(
              milliseconds:
                  _samples.last.timestamp
                      .difference(_samples.first.timestamp)
                      .inMilliseconds ~/
                  2,
            ),
          );
    final fitFile = await _writeFitFile();
    final gpxFile = await _writeGpxFile();
    StravaUploadResult uploadResult = const StravaUploadResult.skipped();
    if (fitFile != null) {
      final stravaState = _stravaUploadService.state.value;
      if (stravaState.autoUploadEnabled && stravaState.isAuthenticated) {
        final decision = await _selectStravaUploadDecision();
        if (!mounted) return;
        final resolvedDecision = resolveStravaUploadDecision(decision);
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
    }
    if (!mounted) return;
    final rideSavedMessage = fitFile == null && gpxFile == null
        ? 'Ride ended. No files written (no samples).'
        : 'Ride saved. FIT: ${fitFile?.path ?? 'N/A'} GPX: ${gpxFile?.path ?? 'N/A'}';
    final uploadMessage =
        uploadResult.message == null ? '' : ' ${uploadResult.message}';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$rideSavedMessage$uploadMessage'),
      ),
    );
  }

  int _fitTimestamp(DateTime dt) {
    return dt.toUtc().millisecondsSinceEpoch ~/ 1000 - _fitEpochOffsetSeconds;
  }

  Future<_ExportedRideFile?> _writeFitFile() async {
    if (_samples.isEmpty) return null;

    final encoder = Encode();
    encoder.open();

    final start = _samples.first.timestamp;
    final end = _samples.last.timestamp;
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

  Future<_ExportedRideFile?> _writeGpxFile() async {
    if (_samples.isEmpty) return null;

    final start = _samples.first.timestamp;
    final fileName = 'ride_${start.toIso8601String().replaceAll(':', '-')}.gpx';

    final buffer = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln(
        '<gpx version="1.1" creator="sebastians-bike-display" xmlns="http://www.topografix.com/GPX/1/1" xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1" xmlns:sbd="https://sebastians-bike-display.dev/xmlschemas/TrackPointQuality/v1">',
      )
      ..writeln('<metadata><time>${start.toUtc().toIso8601String()}</time></metadata>')
      ..writeln('<trk><name>Ride ${start.toIso8601String()}</name><trkseg>');

    for (final sample in _samples) {
      if (sample.latitude == null || sample.longitude == null) {
        continue;
      }
      final altitude = sample.altitudeMeters;
      final hasAltitude = altitude != null && altitude.isFinite;
      final hasAccuracy = sample.accuracyMeters != null && sample.accuracyMeters!.isFinite;
      buffer.writeln(
        '<trkpt lat="${sample.latitude!.toStringAsFixed(7)}" lon="${sample.longitude!.toStringAsFixed(7)}">${hasAltitude ? '<ele>${altitude.toStringAsFixed(1)}</ele>' : ''}<time>${sample.timestamp.toUtc().toIso8601String()}</time><cmt>distance_km=${(sample.distanceMeters / 1000).toStringAsFixed(3)}</cmt><extensions><gpxtpx:TrackPointExtension>${sample.heartRate != null ? '<gpxtpx:hr>${sample.heartRate!.round()}</gpxtpx:hr>' : ''}${sample.cadence != null ? '<gpxtpx:cad>${sample.cadence!.round()}</gpxtpx:cad>' : ''}<gpxtpx:speed>${sample.speedMps.toStringAsFixed(2)}</gpxtpx:speed></gpxtpx:TrackPointExtension><sbd:power_w>${(sample.power ?? 0).toStringAsFixed(0)}</sbd:power_w>${hasAccuracy ? '<sbd:gps_accuracy_m>${sample.accuracyMeters!.toStringAsFixed(1)}</sbd:gps_accuracy_m>' : ''}<sbd:gps_confidence>${sample.gpsConfidence.toStringAsFixed(2)}</sbd:gps_confidence></extensions></trkpt>',
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
        uriOrPath = await _fileExportChannel.invokeMethod<String>(
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

  Future<StravaUploadDecision?> _selectStravaUploadDecision() async {
    final bikes = await _stravaUploadService.listAthleteBikes();
    if (!mounted) return null;
    return showDialog<StravaUploadDecision>(
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
                child: Text(bike.isDefault ? '${bike.name} (default)' : bike.name),
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
          SimpleDialogOption(
            onPressed: () {
              Navigator.of(context).pop();
            },
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  bool get _isPowerSensorConnected => _powerCadenceSensorService.state.value.isConnected;

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
    final smoothed = _smoothedSpeedMps + (rawSpeedMps - _smoothedSpeedMps) * clampedAlpha;
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
    if (previousBearing == null || candidateSpeedMps < 2 || _smoothedSpeedMps < 2) {
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
    if (accuracyMeters == null || !accuracyMeters.isFinite || accuracyMeters <= 0) {
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
              colorScheme.error.withOpacity(0.04),
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
                  valueColor:
                      _hasReliableGpsForSpeed ? null : Theme.of(context).colorScheme.error,
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
            const SizedBox(height: 16),
            PowerBar(
              power: _isPowerSensorConnected ? _data.power3s : null,
              ftp: _ftp.toDouble(),
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
