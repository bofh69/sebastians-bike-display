import 'package:flutter_test/flutter_test.dart';
import 'package:simple_bike_display/main.dart';

void main() {
  testWidgets('Home screen shows Start button', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Power (3s)'), findsOneWidget);
    expect(find.text('Heart Rate'), findsOneWidget);
  });

  testWidgets('Start button toggles to End', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.ensureVisible(find.text('Start'));
    await tester.tap(find.text('Start'));
    await tester.pump();
    expect(find.text('End'), findsOneWidget);
  });
}
