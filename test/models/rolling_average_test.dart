import 'package:flutter_test/flutter_test.dart';
import 'package:simple_bike_display/models/rolling_average.dart';

void main() {
  group('RollingAverage', () {
    test('returns average while filling the window', () {
      final average = RollingAverage(windowSize: 3);

      expect(average.add(10), 10);
      expect(average.add(20), 15);
      expect(average.add(30), 20);
    });

    test('replaces oldest value when window is full', () {
      final average = RollingAverage(windowSize: 3);

      average.add(10);
      average.add(20);
      average.add(30);

      expect(average.add(40), closeTo(30, 1e-9)); // 20,30,40
      expect(average.add(50), closeTo(40, 1e-9)); // 30,40,50
    });

    test('reset clears internal state', () {
      final average = RollingAverage(windowSize: 3);

      average.add(10);
      average.add(20);
      average.add(30);
      average.reset();

      expect(average.add(9), 9);
      expect(average.add(12), 10.5);
    });

    test('window size of one always returns latest sample', () {
      final average = RollingAverage(windowSize: 1);

      expect(average.add(5), 5);
      expect(average.add(8), 8);
      expect(average.add(2), 2);
    });
  });
}
