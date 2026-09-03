import 'dart:async';

const Duration aggressiveSavedSensorReconnectInterval = Duration(seconds: 5);
const Duration backedOffSavedSensorReconnectInterval = Duration(seconds: 30);
const Duration aggressiveSavedSensorReconnectWindow = Duration(minutes: 1);
const Duration savedSensorReconnectTimeout = Duration(minutes: 5);
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
    this.interval = aggressiveSavedSensorReconnectInterval,
    this.autoStartTimer = true,
  });

  static final SavedSensorReconnectCoordinator instance =
      SavedSensorReconnectCoordinator();

  final Duration interval;
  final bool autoStartTimer;
  final Map<String, _SavedSensorReconnectEntry> _attempts =
      <String, _SavedSensorReconnectEntry>{};
  Timer? _timer;
  int _nextIndex = 0;

  void register(String key, Future<void> Function() attempt) {
    final existing = _attempts[key];
    if (existing != null) {
      existing.attempt = attempt;
    } else {
      _attempts[key] = _SavedSensorReconnectEntry(
        attempt: attempt,
        startedAt: DateTime.now(),
      );
    }
    if (autoStartTimer) {
      _ensureTimer();
    }
  }

  void reset(String key, Future<void> Function() attempt) {
    _attempts[key] = _SavedSensorReconnectEntry(
      attempt: attempt,
      startedAt: DateTime.now(),
    );
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
    return takeNextTurnAt(DateTime.now());
  }

  String? takeNextTurnAt(DateTime now) {
    if (_attempts.isEmpty) return null;
    final keys = _attempts.keys.toList(growable: false);
    for (var offset = 0; offset < keys.length; offset += 1) {
      final index = (_nextIndex + offset) % keys.length;
      final key = keys[index];
      final entry = _attempts[key]!;
      if (!_canAttempt(entry, now)) {
        continue;
      }
      entry.lastAttemptAt = now;
      _nextIndex = (index + 1) % keys.length;
      return key;
    }
    return null;
  }

  void _ensureTimer() {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) {
      final now = DateTime.now();
      final key = takeNextTurnAt(now);
      if (key == null) {
        if (!_hasPendingAttempts(now)) {
          _timer?.cancel();
          _timer = null;
        }
        return;
      }
      final attempt = _attempts[key]?.attempt;
      if (attempt != null) {
        unawaited(attempt());
      }
    });
  }

  bool _canAttempt(_SavedSensorReconnectEntry entry, DateTime now) {
    final elapsed = now.difference(entry.startedAt);
    if (elapsed >= savedSensorReconnectTimeout) {
      return false;
    }
    final interval = elapsed < aggressiveSavedSensorReconnectWindow
        ? aggressiveSavedSensorReconnectInterval
        : backedOffSavedSensorReconnectInterval;
    final lastAttemptAt = entry.lastAttemptAt;
    return lastAttemptAt == null || now.difference(lastAttemptAt) >= interval;
  }

  bool _hasPendingAttempts(DateTime now) {
    return _attempts.values.any(
      (entry) => now.difference(entry.startedAt) < savedSensorReconnectTimeout,
    );
  }
}

class _SavedSensorReconnectEntry {
  _SavedSensorReconnectEntry({
    required this.attempt,
    required this.startedAt,
  });

  Future<void> Function() attempt;
  final DateTime startedAt;
  DateTime? lastAttemptAt;
}
