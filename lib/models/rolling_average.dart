class RollingAverage {
  final List<double> _samples;
  int _index = 0;
  int _count = 0;
  double _accumulator = 0;

  RollingAverage({required int windowSize})
      : assert(windowSize > 0),
        _samples = List<double>.filled(windowSize, 0);

  double add(double value) {
    if (_count == _samples.length) {
      _accumulator -= _samples[_index];
    } else {
      _count += 1;
    }

    _samples[_index] = value;
    _accumulator += value;
    _index = (_index + 1) % _samples.length;

    return _accumulator / _count;
  }

  void reset() {
    _index = 0;
    _count = 0;
    _accumulator = 0;
    for (var i = 0; i < _samples.length; i += 1) {
      _samples[i] = 0;
    }
  }
}
