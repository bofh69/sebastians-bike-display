import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sensor_reconnect_policy.dart';

const String _heartRateDeviceIdPrefKey = 'hr_device_id';
const String _heartRateDeviceNamePrefKey = 'hr_device';
final Uuid _heartRateServiceUuid = Uuid.parse('180D');
final Uuid _heartRateMeasurementUuid = Uuid.parse('2A37');
final Uuid _batteryServiceUuid = Uuid.parse('180F');
final Uuid _batteryLevelUuid = Uuid.parse('2A19');

class HeartRateDiscoveredDevice {
  const HeartRateDiscoveredDevice({
    required this.device,
    required this.name,
  });

  final DiscoveredDevice device;
  final String name;

  String get id => device.id;
}

class HeartRateSensorState {
  const HeartRateSensorState({
    this.deviceId,
    this.deviceName,
    this.isScanning = false,
    this.isConnecting = false,
    this.isConnected = false,
    this.heartRate,
    this.batteryLevel,
    this.scanResults = const <HeartRateDiscoveredDevice>[],
    this.errorMessage,
  });

  final String? deviceId;
  final String? deviceName;
  final bool isScanning;
  final bool isConnecting;
  final bool isConnected;
  final double? heartRate;
  final int? batteryLevel;
  final List<HeartRateDiscoveredDevice> scanResults;
  final String? errorMessage;

  HeartRateSensorState copyWith({
    Object? deviceId = _sentinel,
    Object? deviceName = _sentinel,
    bool? isScanning,
    bool? isConnecting,
    bool? isConnected,
    Object? heartRate = _sentinel,
    Object? batteryLevel = _sentinel,
    List<HeartRateDiscoveredDevice>? scanResults,
    Object? errorMessage = _sentinel,
  }) {
    return HeartRateSensorState(
      deviceId: identical(deviceId, _sentinel) ? this.deviceId : deviceId as String?,
      deviceName:
          identical(deviceName, _sentinel) ? this.deviceName : deviceName as String?,
      isScanning: isScanning ?? this.isScanning,
      isConnecting: isConnecting ?? this.isConnecting,
      isConnected: isConnected ?? this.isConnected,
      heartRate: identical(heartRate, _sentinel) ? this.heartRate : heartRate as double?,
      batteryLevel:
          identical(batteryLevel, _sentinel) ? this.batteryLevel : batteryLevel as int?,
      scanResults: scanResults ?? this.scanResults,
      errorMessage:
          identical(errorMessage, _sentinel) ? this.errorMessage : errorMessage as String?,
    );
  }
}

class HeartRateSensorService {
  HeartRateSensorService._();

  static final HeartRateSensorService instance = HeartRateSensorService._();

  final ValueNotifier<HeartRateSensorState> state =
      ValueNotifier(const HeartRateSensorState());

  SharedPreferences? _prefs;
  FlutterReactiveBle? _ble;
  String? _deviceId;
  StreamSubscription<DiscoveredDevice>? _scanSubscription;
  StreamSubscription<ConnectionStateUpdate>? _connectionSubscription;
  StreamSubscription<List<int>>? _heartRateSubscription;
  StreamSubscription<List<int>>? _batterySubscription;
  Timer? _heartRateStaleTimer;
  bool _initialized = false;
  bool _connectingToSavedDevice = false;
  Future<void>? _initializationFuture;
  bool _hasConnectedSinceLastRetryReset = false;
  bool _allowSavedDeviceReconnect = true;

  FlutterReactiveBle get _bleInstance => _ble ??= FlutterReactiveBle();

  Future<void> initialize() {
    return _initializationFuture ??= _initialize();
  }

  Future<void> _initialize() async {
    if (_initialized) return;
    _initialized = true;

    _prefs = await SharedPreferences.getInstance();
    _setState(
      state.value.copyWith(
        deviceId: _prefs!.getString(_heartRateDeviceIdPrefKey),
        deviceName: _prefs!.getString(_heartRateDeviceNamePrefKey),
        errorMessage: null,
      ),
    );

    final savedDeviceId = state.value.deviceId;
    if (savedDeviceId != null && savedDeviceId.isNotEmpty) {
      unawaited(_connectToSavedDevice());
    }
  }

  Future<List<HeartRateDiscoveredDevice>> scanForDevices() async {
    await initialize();
    SavedSensorReconnectCoordinator.instance.reset(
      heartRateReconnectKey,
      _connectToSavedDevice,
    );
    _setState(
      state.value.copyWith(
        isScanning: true,
        errorMessage: null,
        scanResults: const <HeartRateDiscoveredDevice>[],
      ),
    );

    final discovered = <String, HeartRateDiscoveredDevice>{};
    final completer = Completer<List<HeartRateDiscoveredDevice>>();

    try {
      await _ensureBluetoothPermissions();
      await _ensureBluetoothReady();
      await _scanSubscription?.cancel();
      _scanSubscription = _bleInstance
          .scanForDevices(
            withServices: <Uuid>[_heartRateServiceUuid],
            scanMode: ScanMode.lowLatency,
          )
          .listen((device) {
            final name = _bestDeviceName(device.name) ?? device.id;
            discovered[device.id] = HeartRateDiscoveredDevice(
              device: device,
              name: name,
            );
            _setState(
              state.value.copyWith(
                scanResults: discovered.values.toList(growable: false),
              ),
            );
          }, onError: (Object error) {
            if (completer.isCompleted) return;
            completer.completeError(error);
          });
      unawaited(
        Future<void>.delayed(const Duration(seconds: 8)).then((_) async {
          await _scanSubscription?.cancel();
          _scanSubscription = null;
          if (!completer.isCompleted) {
            completer.complete(state.value.scanResults);
          }
        }),
      );
      return await completer.future;
    } on _HeartRateSensorException catch (error) {
      _setState(
        state.value.copyWith(
          errorMessage: error.message,
          scanResults: const <HeartRateDiscoveredDevice>[],
        ),
      );
      return const <HeartRateDiscoveredDevice>[];
    } on PlatformException catch (error) {
      _setState(
        state.value.copyWith(
          errorMessage: error.message ?? 'Bluetooth scan failed.',
          scanResults: const <HeartRateDiscoveredDevice>[],
        ),
      );
      return const <HeartRateDiscoveredDevice>[];
    } on MissingPluginException {
      _setState(
        state.value.copyWith(
          errorMessage: 'Bluetooth is unavailable on this device.',
          scanResults: const <HeartRateDiscoveredDevice>[],
        ),
      );
      return const <HeartRateDiscoveredDevice>[];
    } on Exception catch (error) {
      _setState(
        state.value.copyWith(
          errorMessage: _errorMessage(error, fallback: 'Bluetooth scan failed.'),
          scanResults: const <HeartRateDiscoveredDevice>[],
        ),
      );
      return const <HeartRateDiscoveredDevice>[];
    } catch (_) {
      _setState(
        state.value.copyWith(
          errorMessage: 'Bluetooth scan failed.',
          scanResults: const <HeartRateDiscoveredDevice>[],
        ),
      );
      return const <HeartRateDiscoveredDevice>[];
    } finally {
      await _scanSubscription?.cancel();
      _scanSubscription = null;
      _setState(state.value.copyWith(isScanning: false));
    }
  }

  Future<void> pairDevice(HeartRateDiscoveredDevice discoveredDevice) async {
    await initialize();
    await _prefs?.setString(_heartRateDeviceIdPrefKey, discoveredDevice.id);
    await _prefs?.setString(_heartRateDeviceNamePrefKey, discoveredDevice.name);
    _setState(
      state.value.copyWith(
        deviceId: discoveredDevice.id,
        deviceName: discoveredDevice.name,
        errorMessage: null,
      ),
    );

    await _disconnectCurrentDevice();
    await _connectToDeviceId(discoveredDevice.id, reconnecting: false);
  }

  Future<void> refreshBatteryLevel() async {
    final deviceId = _deviceId;
    if (deviceId == null || !state.value.isConnected) return;
    try {
      final batteryValue = await _bleInstance.readCharacteristic(
        QualifiedCharacteristic(
          serviceId: _batteryServiceUuid,
          characteristicId: _batteryLevelUuid,
          deviceId: deviceId,
        ),
      );
      _updateBatteryLevel(batteryValue);
    } on MissingPluginException {
      // Ignore when plugins are unavailable during tests.
    } on PlatformException {
      // Ignore transient read failures.
    } on Exception {
      // Ignore transient read failures.
    }
  }

  Future<void> disconnectFromDeviceForBackgroundIdle() async {
    await initialize();
    _allowSavedDeviceReconnect = false;
    SavedSensorReconnectCoordinator.instance.unregister(heartRateReconnectKey);
    await _disconnectCurrentDevice();
    _setState(
      state.value.copyWith(
        isConnected: false,
        isConnecting: false,
        isScanning: false,
        heartRate: null,
        batteryLevel: null,
      ),
    );
  }

  Future<void> reconnectDeviceAfterBackgroundIdle() async {
    await initialize();
    _allowSavedDeviceReconnect = true;
    final savedDeviceId = state.value.deviceId;
    if (savedDeviceId == null ||
        savedDeviceId.isEmpty ||
        state.value.isConnected ||
        state.value.isConnecting) {
      return;
    }
    await _connectToSavedDevice();
  }

  Future<void> _connectToSavedDevice() async {
    if (_connectingToSavedDevice) return;
    final savedDeviceId = state.value.deviceId;
    if (savedDeviceId == null || savedDeviceId.isEmpty) return;

    _connectingToSavedDevice = true;
    try {
      await _connectToDeviceId(savedDeviceId, reconnecting: true);
    } finally {
      _connectingToSavedDevice = false;
    }
  }

  Future<void> _connectToDeviceId(
    String deviceId, {
    required bool reconnecting,
  }) async {
    await _cancelCharacteristicSubscriptions();
    await _connectionSubscription?.cancel();
    _setState(
      state.value.copyWith(
        isConnecting: true,
        isConnected: false,
        errorMessage: null,
        batteryLevel: null,
        heartRate: null,
      ),
    );

    try {
      await _ensureBluetoothPermissions();
      await _ensureBluetoothReady();
      _deviceId = deviceId;
      _connectionSubscription = (reconnecting
              ? _bleInstance.connectToAdvertisingDevice(
                  id: deviceId,
                  withServices: <Uuid>[_heartRateServiceUuid],
                  prescanDuration: const Duration(seconds: 5),
                  servicesWithCharacteristicsToDiscover: <Uuid, List<Uuid>>{
                    _heartRateServiceUuid: <Uuid>[_heartRateMeasurementUuid],
                    _batteryServiceUuid: <Uuid>[_batteryLevelUuid],
                  },
                  connectionTimeout: const Duration(seconds: 10),
                )
              : _bleInstance.connectToDevice(
                  id: deviceId,
                  servicesWithCharacteristicsToDiscover: <Uuid, List<Uuid>>{
                    _heartRateServiceUuid: <Uuid>[_heartRateMeasurementUuid],
                    _batteryServiceUuid: <Uuid>[_batteryLevelUuid],
                  },
                  connectionTimeout: const Duration(seconds: 10),
                ))
          .listen((update) {
        final isConnected =
            update.connectionState == DeviceConnectionState.connected;
        final isConnecting =
            update.connectionState == DeviceConnectionState.connecting;
        if (isConnected) {
          _hasConnectedSinceLastRetryReset = true;
        }
        _setState(
          state.value.copyWith(
            isConnected: isConnected,
            isConnecting: isConnecting,
            batteryLevel: isConnected ? state.value.batteryLevel : null,
            heartRate: isConnected ? state.value.heartRate : null,
          ),
        );
        if (isConnected) {
          unawaited(_startCharacteristicSubscriptions(deviceId));
        } else if (update.connectionState == DeviceConnectionState.disconnected) {
          unawaited(_cancelCharacteristicSubscriptions());
          _setState(state.value.copyWith(batteryLevel: null, heartRate: null));
          if (_hasConnectedSinceLastRetryReset) {
            SavedSensorReconnectCoordinator.instance.reset(
              heartRateReconnectKey,
              _connectToSavedDevice,
            );
            _hasConnectedSinceLastRetryReset = false;
          }
        }
      }, onError: (Object error) {
        _setState(
          state.value.copyWith(
            isConnecting: false,
            isConnected: false,
            errorMessage: _errorMessage(
              error,
              fallback: 'Failed to connect to heart rate monitor.',
            ),
          ),
        );
      });
    } on _HeartRateSensorException catch (error) {
      _setState(
        state.value.copyWith(
          isConnecting: false,
          isConnected: false,
          errorMessage: error.message,
        ),
      );
      _deviceId = null;
    }
  }

  Future<void> _startCharacteristicSubscriptions(String deviceId) async {
    try {
      await _cancelCharacteristicSubscriptions();
      _heartRateSubscription = _bleInstance
          .subscribeToCharacteristic(
            QualifiedCharacteristic(
              serviceId: _heartRateServiceUuid,
              characteristicId: _heartRateMeasurementUuid,
              deviceId: deviceId,
            ),
          )
          .listen(_updateHeartRate);
      _batterySubscription = _bleInstance
          .subscribeToCharacteristic(
            QualifiedCharacteristic(
              serviceId: _batteryServiceUuid,
              characteristicId: _batteryLevelUuid,
              deviceId: deviceId,
            ),
          )
          .listen(
            _updateBatteryLevel,
            onError: (_) {},
          );
      await refreshBatteryLevel();
    } on PlatformException catch (error) {
      _setState(
        state.value.copyWith(
          errorMessage:
              error.message ?? 'Failed to read heart rate monitor services.',
        ),
      );
    } on MissingPluginException {
      _setState(
        state.value.copyWith(errorMessage: 'Bluetooth is unavailable on this device.'),
      );
    } on Exception catch (error) {
      _setState(
        state.value.copyWith(
          errorMessage: _errorMessage(
            error,
            fallback: 'Failed to read heart rate monitor services.',
          ),
        ),
      );
    } catch (_) {
      _setState(
        state.value.copyWith(
          errorMessage: 'Failed to read heart rate monitor services.',
        ),
      );
    }
  }

  Future<void> _ensureBluetoothReady() async {
    try {
      await _bleInstance.initialize();
      var status = _bleInstance.status;
      if (status == BleStatus.unknown) {
        status = await _bleInstance.statusStream.firstWhere(
          (value) => value != BleStatus.unknown,
        );
      }

      if (status == BleStatus.ready) {
        return;
      }

      throw _HeartRateSensorException(_statusMessage(status));
    } on UnimplementedError {
      throw const _HeartRateSensorException('Bluetooth is unavailable on this device.');
    } on MissingPluginException {
      throw const _HeartRateSensorException('Bluetooth is unavailable on this device.');
    }
  }

  Future<void> _ensureBluetoothPermissions() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    final statuses = await <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    final hasAllPermissions = statuses.values.every((status) => status.isGranted);
    if (!hasAllPermissions) {
      throw const _HeartRateSensorException('Bluetooth permission is required.');
    }
  }

  Future<void> _disconnectCurrentDevice() async {
    SavedSensorReconnectCoordinator.instance.unregister(heartRateReconnectKey);
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    await _cancelCharacteristicSubscriptions();
    _heartRateStaleTimer?.cancel();
    _heartRateStaleTimer = null;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    _deviceId = null;
    _hasConnectedSinceLastRetryReset = false;
  }

  Future<void> _cancelCharacteristicSubscriptions() async {
    await _heartRateSubscription?.cancel();
    await _batterySubscription?.cancel();
    _heartRateSubscription = null;
    _batterySubscription = null;
    _heartRateStaleTimer?.cancel();
    _heartRateStaleTimer = null;
  }

  void _updateHeartRate(List<int> value) {
    final heartRate = _parseHeartRate(value);
    if (heartRate == null) return;
    _setState(state.value.copyWith(heartRate: heartRate.toDouble()));
    _scheduleHeartRateStaleTimer();
  }

  void _scheduleHeartRateStaleTimer() {
    _heartRateStaleTimer?.cancel();
    _heartRateStaleTimer = Timer(const Duration(seconds: 5), () {
      final currentState = state.value;
      if (!currentState.isConnected || currentState.heartRate == null) return;
      _setState(currentState.copyWith(heartRate: null));
    });
  }

  void _updateBatteryLevel(List<int> value) {
    if (value.isEmpty) return;
    final batteryLevel = value.first;
    _setState(
      state.value.copyWith(
        batteryLevel: batteryLevel < 0 ? 0 : (batteryLevel > 100 ? 100 : batteryLevel),
      ),
    );
  }

  int? _parseHeartRate(List<int> value) {
    if (value.length < 2) return null;
    final flags = value.first;
    final isUint16 = (flags & 0x01) != 0;

    if (isUint16) {
      if (value.length < 3) return null;
      return value[1] | (value[2] << 8);
    }

    return value[1];
  }

  String? _bestDeviceName(String? name) {
    final trimmedName = name?.trim();
    return trimmedName == null || trimmedName.isEmpty ? null : trimmedName;
  }

  void _setState(HeartRateSensorState nextState) {
    state.value = nextState;
    final currentState = state.value;
    if (_allowSavedDeviceReconnect &&
        shouldRetrySavedSensorConnection(
      deviceId: currentState.deviceId,
      isConnected: currentState.isConnected,
      isConnecting: currentState.isConnecting,
      isScanning: currentState.isScanning,
    )) {
      SavedSensorReconnectCoordinator.instance.register(
        heartRateReconnectKey,
        _connectToSavedDevice,
      );
      return;
    }
    SavedSensorReconnectCoordinator.instance.unregister(heartRateReconnectKey);
  }

  String _statusMessage(BleStatus status) {
    switch (status) {
      case BleStatus.unsupported:
        return 'Bluetooth LE is not supported.';
      case BleStatus.unauthorized:
        return 'Bluetooth permission is required.';
      case BleStatus.poweredOff:
        return 'Turn on Bluetooth to continue.';
      case BleStatus.locationServicesDisabled:
        return 'Enable location services to scan for sensors.';
      case BleStatus.ready:
      case BleStatus.unknown:
        return 'Bluetooth is unavailable on this device.';
    }
  }

  String _errorMessage(Object error, {required String fallback}) {
    if (error is PlatformException) {
      return error.message ?? fallback;
    }
    return fallback;
  }
}

class _HeartRateSensorException implements Exception {
  const _HeartRateSensorException(this.message);

  final String message;

  @override
  String toString() => message;
}

const Object _sentinel = Object();
