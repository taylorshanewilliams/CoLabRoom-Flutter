import 'package:colabroom/features/toolbox/toolbox_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Toolbox used to be a tab, and a tab is built inside the shell's
/// Scaffold — which is what supplied the Material its search field requires.
/// Moved behind Account → Toolbox it is pushed onto a MaterialPageRoute, and
/// a route is not Material: the TextField threw on build and took the screen
/// down with it. Pumping it with nothing but a MaterialApp above reproduces
/// exactly that, and nothing else in the suite would have.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('the Toolbox builds on a route with no Scaffold above it',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ToolboxScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Guitar'), findsOneWidget);
  });

  testWidgets('searching narrows the categories', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ToolboxScreen()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'bass');
    await tester.pumpAndSettle();

    expect(find.text('Bass'), findsOneWidget);
    expect(find.text('Guitar'), findsNothing);
  });
}
