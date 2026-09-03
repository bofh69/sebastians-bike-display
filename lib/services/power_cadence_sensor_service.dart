import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _powerDeviceIdPrefKey = 'power_device_id';
const String _powerDeviceNamePrefKey = 'power_device';
final Uuid _cyclingPowerServiceUuid = Uuid.parse('1818');
final Uuid _cyclingPowerMeasurementUuid = Uuid.parse('2A63');
final Uuid _cyclingSpeedCadenceServiceUuid = Uuid.parse('1816');
final Uuid _cscMeasurementUuid = Uuid.parse('2A5B');
final Uuid _batteryServiceUuid = Uuid.parse('180F');
final Uuid _batteryLevelUuid = Uuid.parse('2A19');

class PowerCadenceDiscoveredDevice {
  const PowerCadenceDiscoveredDevice({
    required this.device,
    required this.name,
  });

  final DiscoveredDevice device;
  final String name;

  String get id => device.id;
}

class PowerCadenceSensorState {
  const PowerCadenceSensorState({
    this.deviceId,
    this.deviceName,
    this.isScanning = false,
    this.isConnecting = false,
    this.isConnected = false,
    this.power,
    this.cadence,
    this.batteryLevel,
    this.scanResults = const <PowerCadenceDiscoveredDevice>[],
    this.errorMessage,
  });

  final String? deviceId;
  final String? deviceName;
  final bool isScanning;
  final bool isConnecting;
  final bool isConnected;
  final double? power;
  final double? cadence;
  final int? batteryLevel;
  final List<PowerCadenceDiscoveredDevice> scanResults;
  final String? errorMessage;

  PowerCadenceSensorState copyWith({
    Object? deviceId = _sentinel,
    Object? deviceName = _sentinel,
    bool? isScanning,
    bool? isConnecting,
    bool? isConnected,
    Object? power = _sentinel,
    Object? cadence = _sentinel,
    Object? batteryLevel = _sentinel,
    List<PowerCadenceDiscoveredDevice>? scanResults,
    Object? errorMessage = _sentinel,
  }) {
    return PowerCadenceSensorState(
      deviceId: identical(deviceId, _sentinel) ? this.deviceId : deviceId as String?,
      deviceName:
          identical(deviceName, _sentinel) ? this.deviceName : deviceName as String?,
      isScanning: isScanning ?? this.isScanning,
      isConnecting: isConnecting ?? this.isConnecting,
      isConnected: isConnected ?? this.isConnected,
      power: identical(power, _sentinel) ? this.power : power as double?,
      cadence: identical(cadence, _sentinel) ? this.cadence : cadence as double?,
      batteryLevel:
          identical(batteryLevel, _sentinel) ? this.batteryLevel : batteryLevel as int?,
      scanResults: scanResults ?? this.scanResults,
      errorMessage:
          identical(errorMessage, _sentinel) ? this.errorMessage : errorMessage as String?,
    );
  }
}

class PowerCadenceSensorService {
  PowerCadenceSensorService._();

  static final PowerCadenceSensorService instance = PowerCadenceSensorService._();

  final ValueNotifier<PowerCadenceSensorState> state =
      ValueNotifier(const PowerCadenceSensorState());

  SharedPreferences? _prefs;
  FlutterReactiveBle? _ble;
  String? _deviceId;
  StreamSubscription<DiscoveredDevice>? _scanSubscription;
  StreamSubscription<ConnectionStateUpdate>? _connectionSubscription;
  StreamSubscription<List<int>>? _powerSubscription;
  StreamSubscription<List<int>>? _cadenceSubscription;
  StreamSubscription<List<int>>? _batterySubscription;
  Timer? _powerStaleTimer;
  Timer? _cadenceStaleTimer;
  bool _initialized = false;
  bool _connectingToSavedDevice = false;
  Future<void>? _initializationFuture;
  int? _lastPowerCrankRevolutions;
  int? _lastPowerCrankEventTime;
  int? _lastCscCrankRevolutions;
  int? _lastCscCrankEventTime;

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
        deviceId: _prefs!.getString(_powerDeviceIdPrefKey),
        deviceName: _prefs!.getString(_powerDeviceNamePrefKey),
        errorMessage: null,
      ),
    );

    final savedDeviceId = state.value.deviceId;
    if (savedDeviceId != null && savedDeviceId.isNotEmpty) {
      unawaited(_connectToSavedDevice());
    }
  }

  Future<List<PowerCadenceDiscoveredDevice>> scanForDevices() async {
    await initialize();
    _setState(
      state.value.copyWith(
        isScanning: true,
        errorMessage: null,
        scanResults: const <PowerCadenceDiscoveredDevice>[],
      ),
    );

    final discovered = <String, PowerCadenceDiscoveredDevice>{};
    final completer = Completer<List<PowerCadenceDiscoveredDevice>>();

    try {
      await _ensureBluetoothPermissions();
      await _ensureBluetoothReady();
      await _scanSubscription?.cancel();
      _scanSubscription = _bleInstance
          .scanForDevices(
            withServices: <Uuid>[
              _cyclingPowerServiceUuid,
              _cyclingSpeedCadenceServiceUuid,
            ],
            scanMode: ScanMode.lowLatency,
          )
          .listen((device) {
            final name = _bestDeviceName(device.name) ?? device.id;
            discovered[device.id] = PowerCadenceDiscoveredDevice(
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
    } on _PowerCadenceSensorException catch (error) {
      _setState(
        state.value.copyWith(
          errorMessage: error.message,
          scanResults: const <PowerCadenceDiscoveredDevice>[],
        ),
      );
      return const <PowerCadenceDiscoveredDevice>[];
    } on PlatformException catch (error) {
      _setState(
        state.value.copyWith(
          errorMessage: error.message ?? 'Bluetooth scan failed.',
          scanResults: const <PowerCadenceDiscoveredDevice>[],
        ),
      );
      return const <PowerCadenceDiscoveredDevice>[];
    } on MissingPluginException {
      _setState(
        state.value.copyWith(
          errorMessage: 'Bluetooth is unavailable on this device.',
          scanResults: const <PowerCadenceDiscoveredDevice>[],
        ),
      );
      return const <PowerCadenceDiscoveredDevice>[];
    } on Exception catch (error) {
      _setState(
        state.value.copyWith(
          errorMessage: _errorMessage(error, fallback: 'Bluetooth scan failed.'),
          scanResults: const <PowerCadenceDiscoveredDevice>[],
        ),
      );
      return const <PowerCadenceDiscoveredDevice>[];
    } catch (_) {
      _setState(
        state.value.copyWith(
          errorMessage: 'Bluetooth scan failed.',
          scanResults: const <PowerCadenceDiscoveredDevice>[],
        ),
      );
      return const <PowerCadenceDiscoveredDevice>[];
    } finally {
      await _scanSubscription?.cancel();
      _scanSubscription = null;
      _setState(state.value.copyWith(isScanning: false));
    }
  }

  Future<void> pairDevice(PowerCadenceDiscoveredDevice discoveredDevice) async {
    await initialize();
    await _prefs?.setString(_powerDeviceIdPrefKey, discoveredDevice.id);
    await _prefs?.setString(_powerDeviceNamePrefKey, discoveredDevice.name);
    _setState(
      state.value.copyWith(
        deviceId: discoveredDevice.id,
        deviceName: discoveredDevice.name,
        errorMessage: null,
      ),
    );

    await _disconnectCurrentDevice();
    await _connectToDeviceId(discoveredDevice.id);
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

  Future<void> _connectToSavedDevice() async {
    if (_connectingToSavedDevice) return;
    final savedDeviceId = state.value.deviceId;
    if (savedDeviceId == null || savedDeviceId.isEmpty) return;

    _connectingToSavedDevice = true;
    try {
      await _connectToDeviceId(savedDeviceId);
    } finally {
      _connectingToSavedDevice = false;
    }
  }

  Future<void> _connectToDeviceId(String deviceId) async {
    await _cancelCharacteristicSubscriptions();
    await _connectionSubscription?.cancel();
    _setState(
      state.value.copyWith(
        isConnecting: true,
        isConnected: false,
        errorMessage: null,
        batteryLevel: null,
        power: null,
        cadence: null,
      ),
    );

    try {
      await _ensureBluetoothPermissions();
      await _ensureBluetoothReady();
      _deviceId = deviceId;
      _connectionSubscription = _bleInstance
          .connectToDevice(
            id: deviceId,
            connectionTimeout: const Duration(seconds: 10),
          )
          .listen((update) {
            final isConnected =
                update.connectionState == DeviceConnectionState.connected;
            final isConnecting =
                update.connectionState == DeviceConnectionState.connecting;
            _setState(
              state.value.copyWith(
                isConnected: isConnected,
                isConnecting: isConnecting,
                batteryLevel: isConnected ? state.value.batteryLevel : null,
                power: isConnected ? state.value.power : null,
                cadence: isConnected ? state.value.cadence : null,
              ),
            );
            if (isConnected) {
              unawaited(_startCharacteristicSubscriptions(deviceId));
            } else if (update.connectionState ==
                DeviceConnectionState.disconnected) {
              unawaited(_cancelCharacteristicSubscriptions());
              _setState(
                state.value.copyWith(batteryLevel: null, power: null, cadence: null),
              );
            }
          }, onError: (Object error) {
            _setState(
              state.value.copyWith(
                isConnecting: false,
                isConnected: false,
                errorMessage: _errorMessage(
                  error,
                  fallback: 'Failed to connect to power/cadence sensor.',
                ),
              ),
            );
          });
    } on _PowerCadenceSensorException catch (error) {
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
      _powerSubscription = await _subscribeToOptionalCharacteristic(
        characteristic: QualifiedCharacteristic(
          serviceId: _cyclingPowerServiceUuid,
          characteristicId: _cyclingPowerMeasurementUuid,
          deviceId: deviceId,
        ),
        onData: _updateCyclingPowerData,
      );
      _cadenceSubscription = await _subscribeToOptionalCharacteristic(
        characteristic: QualifiedCharacteristic(
          serviceId: _cyclingSpeedCadenceServiceUuid,
          characteristicId: _cscMeasurementUuid,
          deviceId: deviceId,
        ),
        onData: _updateCyclingCadenceData,
      );
      _batterySubscription = await _subscribeToOptionalCharacteristic(
        characteristic: QualifiedCharacteristic(
          serviceId: _batteryServiceUuid,
          characteristicId: _batteryLevelUuid,
          deviceId: deviceId,
        ),
        onData: _updateBatteryLevel,
      );
      await refreshBatteryLevel();
    } on PlatformException catch (error) {
      _setState(
        state.value.copyWith(
          errorMessage: error.message ?? 'Failed to read power/cadence services.',
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
            fallback: 'Failed to read power/cadence services.',
          ),
        ),
      );
    } catch (_) {
      _setState(
        state.value.copyWith(
          errorMessage: 'Failed to read power/cadence services.',
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

      throw _PowerCadenceSensorException(_statusMessage(status));
    } on UnimplementedError {
      throw const _PowerCadenceSensorException(
        'Bluetooth is unavailable on this device.',
      );
    } on MissingPluginException {
      throw const _PowerCadenceSensorException(
        'Bluetooth is unavailable on this device.',
      );
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
      throw const _PowerCadenceSensorException('Bluetooth permission is required.');
    }
  }

  Future<void> _disconnectCurrentDevice() async {
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    await _cancelCharacteristicSubscriptions();
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    _deviceId = null;
    _lastPowerCrankRevolutions = null;
    _lastPowerCrankEventTime = null;
    _lastCscCrankRevolutions = null;
    _lastCscCrankEventTime = null;
  }

  Future<void> _cancelCharacteristicSubscriptions() async {
    await _powerSubscription?.cancel();
    await _cadenceSubscription?.cancel();
    await _batterySubscription?.cancel();
    _powerSubscription = null;
    _cadenceSubscription = null;
    _batterySubscription = null;
    _powerStaleTimer?.cancel();
    _powerStaleTimer = null;
    _cadenceStaleTimer?.cancel();
    _cadenceStaleTimer = null;
  }

  Future<StreamSubscription<List<int>>?> _subscribeToOptionalCharacteristic({
    required QualifiedCharacteristic characteristic,
    required void Function(List<int> value) onData,
  }) async {
    try {
      return _bleInstance
          .subscribeToCharacteristic(characteristic)
          .listen(onData, onError: (_) {});
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } on Exception {
      return null;
    }
  }

  void _updateCyclingPowerData(List<int> value) {
    if (value.length < 4) return;

    final flags = value[0] | (value[1] << 8);
    final rawPower = value[2] | (value[3] << 8);
    final signedPower = rawPower >= 0x8000 ? rawPower - 0x10000 : rawPower;
    final power = signedPower < 0 ? 0.0 : signedPower.toDouble();
    var cadence = state.value.cadence;
    var hasCadenceUpdate = false;

    var offset = 4;
    if ((flags & 0x0001) != 0) {
      offset += 1;
    }
    if ((flags & 0x0004) != 0) {
      offset += 2;
    }
    if ((flags & 0x0010) != 0) {
      offset += 6;
    }
    if ((flags & 0x0020) != 0 && value.length >= offset + 4) {
      final crankRevolutions = value[offset] | (value[offset + 1] << 8);
      final crankEventTime = value[offset + 2] | (value[offset + 3] << 8);
      final parsedCadence = _calculateCadenceFromCrankData(
        crankRevolutions: crankRevolutions,
        crankEventTime: crankEventTime,
        previousCrankRevolutions: _lastPowerCrankRevolutions,
        previousCrankEventTime: _lastPowerCrankEventTime,
      );
      _lastPowerCrankRevolutions = crankRevolutions;
      _lastPowerCrankEventTime = crankEventTime;
      if (parsedCadence != null) {
        cadence = parsedCadence;
        hasCadenceUpdate = true;
      }
    }

    _setState(
      state.value.copyWith(
        power: power,
        cadence: cadence,
      ),
    );
    _schedulePowerStaleTimer();
    if (hasCadenceUpdate) {
      _scheduleCadenceStaleTimer();
    }
  }

  void _updateCyclingCadenceData(List<int> value) {
    if (value.isEmpty) return;

    final flags = value[0];
    var offset = 1;
    if ((flags & 0x01) != 0) {
      if (value.length < offset + 6) return;
      offset += 6;
    }

    if ((flags & 0x02) == 0 || value.length < offset + 4) {
      return;
    }

    final crankRevolutions = value[offset] | (value[offset + 1] << 8);
    final crankEventTime = value[offset + 2] | (value[offset + 3] << 8);
    final cadence = _calculateCadenceFromCrankData(
      crankRevolutions: crankRevolutions,
      crankEventTime: crankEventTime,
      previousCrankRevolutions: _lastCscCrankRevolutions,
      previousCrankEventTime: _lastCscCrankEventTime,
    );
    _lastCscCrankRevolutions = crankRevolutions;
    _lastCscCrankEventTime = crankEventTime;
    if (cadence == null) return;

    _setState(state.value.copyWith(cadence: cadence));
    _scheduleCadenceStaleTimer();
  }

  double? _calculateCadenceFromCrankData({
    required int crankRevolutions,
    required int crankEventTime,
    required int? previousCrankRevolutions,
    required int? previousCrankEventTime,
  }) {
    if (previousCrankRevolutions == null || previousCrankEventTime == null) {
      return null;
    }

    var deltaRevolutions = crankRevolutions - previousCrankRevolutions;
    if (deltaRevolutions < 0) {
      deltaRevolutions += 0x10000;
    }
    var deltaTime = crankEventTime - previousCrankEventTime;
    if (deltaTime < 0) {
      deltaTime += 0x10000;
    }

    if (deltaTime <= 0) return null;
    if (deltaRevolutions <= 0) return 0;
    final cadence = (deltaRevolutions * 60 * 1024) / deltaTime;
    if (!cadence.isFinite) return null;
    return cadence < 0 ? 0 : cadence.toDouble();
  }

  void _schedulePowerStaleTimer() {
    _powerStaleTimer?.cancel();
    _powerStaleTimer = Timer(const Duration(seconds: 3), () {
      final currentState = state.value;
      if (!currentState.isConnected) return;
      if ((currentState.power ?? 0) == 0) {
        return;
      }
      _setState(currentState.copyWith(power: 0.0));
    });
  }

  void _scheduleCadenceStaleTimer() {
    _cadenceStaleTimer?.cancel();
    _cadenceStaleTimer = Timer(const Duration(seconds: 3), () {
      final currentState = state.value;
      if (!currentState.isConnected) return;
      if ((currentState.cadence ?? 0) == 0) {
        return;
      }
      _setState(currentState.copyWith(cadence: 0.0));
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

  String? _bestDeviceName(String? name) {
    final trimmedName = name?.trim();
    return trimmedName == null || trimmedName.isEmpty ? null : trimmedName;
  }

  void _setState(PowerCadenceSensorState nextState) {
    state.value = nextState;
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

class _PowerCadenceSensorException implements Exception {
  const _PowerCadenceSensorException(this.message);

  final String message;

  @override
  String toString() => message;
}

const Object _sentinel = Object();
