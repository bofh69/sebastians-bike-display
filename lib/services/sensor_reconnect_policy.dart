import 'dart:async';

const Duration savedSensorReconnectInterval = Duration(seconds: 15);
const String heartRateReconnectKey = 'heart_rate';
const String powerCadenceReconnectKey = 'power_cadence';

bool shouldRetrySavedSensorConnection({
  required String? deviceId,
  required bool isConnected,
  required bool isConnecting,
  required bool isScanning,
}) {
  return deviceId != null &&
      deviceId.isNotEmpty &&
      !isConnected &&
      !isConnecting &&
      !isScanning;
}

class SavedSensorReconnectCoordinator {
  SavedSensorReconnectCoordinator({
    this.interval = savedSensorReconnectInterval,
    this.autoStartTimer = true,
  });

  static final SavedSensorReconnectCoordinator instance =
      SavedSensorReconnectCoordinator();

  final Duration interval;
  final bool autoStartTimer;
  final Map<String, Future<void> Function()> _attempts =
      <String, Future<void> Function()>{};
  Timer? _timer;
  int _nextIndex = 0;

  void register(String key, Future<void> Function() attempt) {
    _attempts[key] = attempt;
    if (autoStartTimer) {
      _ensureTimer();
    }
  }

  void unregister(String key) {
    final removedIndex = _attempts.keys.toList(growable: false).indexOf(key);
    _attempts.remove(key);
    if (_attempts.isEmpty) {
      _timer?.cancel();
      _timer = null;
      _nextIndex = 0;
      return;
    }
    if (removedIndex >= 0 && removedIndex < _nextIndex) {
      _nextIndex -= 1;
    }
    _nextIndex %= _attempts.length;
  }

  String? takeNextTurn() {
    if (_attempts.isEmpty) return null;
    final keys = _attempts.keys.toList(growable: false);
    final key = keys[_nextIndex % keys.length];
    _nextIndex = (_nextIndex + 1) % keys.length;
    return key;
  }

  void _ensureTimer() {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) {
      final key = takeNextTurn();
      if (key == null) {
        _timer?.cancel();
        _timer = null;
        return;
      }
      final attempt = _attempts[key];
      if (attempt != null) {
        unawaited(attempt());
      }
    });
  }
}
