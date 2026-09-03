class TimeWindowAverage {
  TimeWindowAverage({required Duration window}) : _window = window;

  final Duration _window;
  final List<({DateTime timestamp, double value})> _samples = [];
  double _sum = 0;

  double add(DateTime timestamp, double value) {
    _samples.add((timestamp: timestamp, value: value));
    _sum += value;
    _prune(timestamp);
    return average!;
  }

  double? get average {
    if (_samples.isEmpty) return null;
    return _sum / _samples.length;
  }

  void clear() {
    _samples.clear();
    _sum = 0;
  }

  void _prune(DateTime now) {
    final cutoff = now.subtract(_window);
    while (_samples.isNotEmpty && _samples.first.timestamp.isBefore(cutoff)) {
      _sum -= _samples.removeAt(0).value;
    }
  }
}
