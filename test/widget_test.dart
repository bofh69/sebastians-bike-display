import 'package:flutter_test/flutter_test.dart';
import 'package:simple_bike_display/main.dart';
import 'package:simple_bike_display/screens/home_screen.dart';
import 'package:simple_bike_display/services/power_cadence_sensor_service.dart';

void main() {
  test('formatPowerBalance preserves fractional balance values', () {
    expect(formatPowerBalance(49.5, 50.5), '49.5/50.5');
    expect(formatPowerBalance(50, 50), '50/50');
    expect(formatPowerBalance(null, 50), 'N/A');
  });

  test('parsePowerBalance decodes half-percent values', () {
    expect(
      parsePowerBalance(flags: 0x0003, rawPedalBalance: 200),
      (leftBalance: 100.0, rightBalance: 0.0),
    );
    expect(
      parsePowerBalance(flags: 0x0001, rawPedalBalance: 34),
      (leftBalance: 17.0, rightBalance: 83.0),
    );
  });

  test('parsePowerBalance treats the flag bit as left-referenced', () {
    expect(
      parsePowerBalance(flags: 0x0003, rawPedalBalance: 40),
      (leftBalance: 20.0, rightBalance: 80.0),
    );
  });

  testWidgets('Home screen shows Start button', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Power (3s)'), findsOneWidget);
    expect(find.text('Heart Rate'), findsOneWidget);
    expect(find.text('Total Climb'), findsOneWidget);
  });

  testWidgets('Start button toggles to End', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.ensureVisible(find.text('Start'));
    await tester.tap(find.text('Start'));
    await tester.pump();
    expect(find.text('End'), findsOneWidget);
  });
}
