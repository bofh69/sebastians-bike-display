import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _heartRateDeviceIdPrefKey = 'hr_device_id';
const String _heartRateDeviceNamePrefKey = 'hr_device';
final Guid _heartRateServiceGuid = Guid('180D');
final Guid _heartRateMeasurementGuid = Guid('2A37');
final Guid _batteryServiceGuid = Guid('180F');
final Guid _batteryLevelGuid = Guid('2A19');

class HeartRateDiscoveredDevice {
  const HeartRateDiscoveredDevice({
    required this.device,
    required this.name,
  });

  final BluetoothDevice device;
  final String name;

  String get id => device.remoteId.str;
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
  BluetoothDevice? _device;
  BluetoothCharacteristic? _batteryCharacteristic;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  StreamSubscription<List<int>>? _heartRateSubscription;
  StreamSubscription<List<int>>? _batterySubscription;
  bool _initialized = false;
  bool _connectingToSavedDevice = false;
  Future<void>? _initializationFuture;

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
    _setState(
      state.value.copyWith(
        isScanning: true,
        errorMessage: null,
        scanResults: const <HeartRateDiscoveredDevice>[],
      ),
    );

    final discovered = <String, HeartRateDiscoveredDevice>{};
    StreamSubscription<List<ScanResult>>? subscription;

    try {
      await _ensureBluetoothReady();
      subscription = FlutterBluePlus.onScanResults.listen((results) {
        for (final result in results) {
          final device = result.device;
          final name =
              _bestDeviceName(device.platformName, result.advertisementData.advName) ??
              device.remoteId.str;
          discovered[device.remoteId.str] = HeartRateDiscoveredDevice(
            device: device,
            name: name,
          );
        }
        _setState(
          state.value.copyWith(scanResults: discovered.values.toList(growable: false)),
        );
      });

      await FlutterBluePlus.startScan(
        withServices: <Guid>[_heartRateServiceGuid],
        timeout: const Duration(seconds: 8),
      );
      await FlutterBluePlus.isScanning.where((value) => value == false).first;
      return state.value.scanResults;
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
    } catch (_) {
      _setState(
        state.value.copyWith(
          errorMessage: 'Bluetooth scan failed.',
          scanResults: const <HeartRateDiscoveredDevice>[],
        ),
      );
      return const <HeartRateDiscoveredDevice>[];
    } finally {
      await subscription?.cancel();
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
    await _connectToDevice(discoveredDevice.device, autoConnect: true);
  }

  Future<void> refreshBatteryLevel() async {
    final batteryCharacteristic = _batteryCharacteristic;
    if (batteryCharacteristic == null || !state.value.isConnected) return;
    try {
      final batteryValue = await batteryCharacteristic.read();
      _updateBatteryLevel(batteryValue);
    } on PlatformException {
      // Ignore transient read failures.
    } on MissingPluginException {
      // Ignore when plugins are unavailable during tests.
    }
  }

  Future<void> _connectToSavedDevice() async {
    if (_connectingToSavedDevice) return;
    final savedDeviceId = state.value.deviceId;
    if (savedDeviceId == null || savedDeviceId.isEmpty) return;

    _connectingToSavedDevice = true;
    try {
      await _connectToDevice(BluetoothDevice.fromId(savedDeviceId), autoConnect: true);
    } finally {
      _connectingToSavedDevice = false;
    }
  }

  Future<void> _connectToDevice(
    BluetoothDevice device, {
    required bool autoConnect,
  }) async {
    await _cancelCharacteristicSubscriptions();
    await _connectionSubscription?.cancel();

    _device = device;
    _batteryCharacteristic = null;
    _connectionSubscription = device.connectionState.listen((connectionState) {
      if (connectionState == BluetoothConnectionState.disconnected &&
          state.value.isConnecting) {
        return;
      }
      final isConnected = connectionState == BluetoothConnectionState.connected;
      _setState(
        state.value.copyWith(
          isConnected: isConnected,
          isConnecting: false,
          batteryLevel: isConnected ? state.value.batteryLevel : null,
          heartRate: isConnected ? state.value.heartRate : null,
        ),
      );
      if (isConnected) {
        unawaited(_discoverServices(device));
      } else {
        _batteryCharacteristic = null;
        unawaited(_cancelCharacteristicSubscriptions());
        _setState(state.value.copyWith(batteryLevel: null, heartRate: null));
      }
    });

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
      await _ensureBluetoothReady();
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }
      if (autoConnect) {
        await device.connect(autoConnect: true, mtu: null);
      } else {
        await device.connect();
      }
    } on _HeartRateSensorException catch (error) {
      _setState(
        state.value.copyWith(
          isConnecting: false,
          errorMessage: error.message,
        ),
      );
    } on PlatformException catch (error) {
      _setState(
        state.value.copyWith(
          isConnecting: false,
          errorMessage: error.message ?? 'Failed to connect to heart rate monitor.',
        ),
      );
    } on MissingPluginException {
      _setState(
        state.value.copyWith(
          isConnecting: false,
          errorMessage: 'Bluetooth is unavailable on this device.',
        ),
      );
    } catch (_) {
      _setState(
        state.value.copyWith(
          isConnecting: false,
          errorMessage: 'Failed to connect to heart rate monitor.',
        ),
      );
    }
  }

  Future<void> _discoverServices(BluetoothDevice device) async {
    try {
      final services = await device.discoverServices();
      BluetoothCharacteristic? heartRateCharacteristic;
      BluetoothCharacteristic? batteryCharacteristic;

      for (final service in services) {
        if (service.uuid == _heartRateServiceGuid) {
          for (final characteristic in service.characteristics) {
            if (characteristic.uuid == _heartRateMeasurementGuid) {
              heartRateCharacteristic = characteristic;
            }
          }
        } else if (service.uuid == _batteryServiceGuid) {
          for (final characteristic in service.characteristics) {
            if (characteristic.uuid == _batteryLevelGuid) {
              batteryCharacteristic = characteristic;
            }
          }
        }
      }

      await _cancelCharacteristicSubscriptions();

      if (heartRateCharacteristic != null) {
        _heartRateSubscription = heartRateCharacteristic.onValueReceived.listen(
          _updateHeartRate,
        );
        await heartRateCharacteristic.setNotifyValue(true);
      }

      if (batteryCharacteristic != null) {
        _batteryCharacteristic = batteryCharacteristic;
        _batterySubscription = batteryCharacteristic.onValueReceived.listen(
          _updateBatteryLevel,
        );
        if (batteryCharacteristic.properties.notify ||
            batteryCharacteristic.properties.indicate) {
          await batteryCharacteristic.setNotifyValue(true);
        }
        if (batteryCharacteristic.properties.read) {
          final batteryValue = await batteryCharacteristic.read();
          _updateBatteryLevel(batteryValue);
        }
      }
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
      if (await FlutterBluePlus.isSupported == false) {
        throw const _HeartRateSensorException('Bluetooth LE is not supported.');
      }

      if (!kIsWeb && io.Platform.isAndroid) {
        final adapterState = FlutterBluePlus.adapterStateNow;
        if (adapterState != BluetoothAdapterState.on) {
          await FlutterBluePlus.turnOn();
        }
      }

      final adapterState = FlutterBluePlus.adapterStateNow;
      if (adapterState != BluetoothAdapterState.on &&
          adapterState != BluetoothAdapterState.unknown) {
        throw const _HeartRateSensorException('Turn on Bluetooth to continue.');
      }
    } on MissingPluginException {
      throw const _HeartRateSensorException('Bluetooth is unavailable on this device.');
    }
  }

  Future<void> _disconnectCurrentDevice() async {
    await _cancelCharacteristicSubscriptions();
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;

    final device = _device;
    _device = null;
    _batteryCharacteristic = null;

    if (device == null) return;
    try {
      await device.disconnect();
    } on PlatformException {
      // Ignore disconnect failures when replacing the device.
    } on MissingPluginException {
      // Ignore when plugins are unavailable during tests.
    }
  }

  Future<void> _cancelCharacteristicSubscriptions() async {
    await _heartRateSubscription?.cancel();
    await _batterySubscription?.cancel();
    _heartRateSubscription = null;
    _batterySubscription = null;
  }

  void _updateHeartRate(List<int> value) {
    final heartRate = _parseHeartRate(value);
    if (heartRate == null) return;
    _setState(state.value.copyWith(heartRate: heartRate.toDouble()));
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

  String? _bestDeviceName(String? platformName, String? advName) {
    final trimmedPlatformName = platformName?.trim();
    if (trimmedPlatformName != null && trimmedPlatformName.isNotEmpty) {
      return trimmedPlatformName;
    }

    final trimmedAdvName = advName?.trim();
    if (trimmedAdvName != null && trimmedAdvName.isNotEmpty) {
      return trimmedAdvName;
    }

    return null;
  }

  void _setState(HeartRateSensorState nextState) {
    state.value = nextState;
  }
}

class _HeartRateSensorException implements Exception {
  const _HeartRateSensorException(this.message);

  final String message;

  @override
  String toString() => message;
}

const Object _sentinel = Object();
