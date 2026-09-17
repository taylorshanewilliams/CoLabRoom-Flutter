import 'package:colabroom/app/colabroom_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The button on a snackbar reads on the snackbar.
///
/// "Undo" on a declined invitation came back in the theme's default action
/// colour, a dark teal, on the raised navy of the bar: there, but only just
/// (web preview, 17 September 2026). It is the one control somebody has a
/// few seconds to find.
double _wcag(Color a, Color b) {
  final one = a.computeLuminance();
  final two = b.computeLuminance();
  return ((one > two ? one : two) + 0.05) / ((one > two ? two : one) + 0.05);
}

void main() {
  testWidgets('a snackbar action is painted in a colour that reads on the bar', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('Declined. They will be told.'),
                action: SnackBarAction(label: 'Undo', onPressed: () {}),
              ),
            ),
            child: const Text('Show'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Show'));
    await tester.pumpAndSettle();

    final label = find.descendant(of: find.byType(SnackBarAction), matching: find.text('Undo'));
    final element = tester.element(label);
    final painted = DefaultTextStyle.of(element).style.merge(tester.widget<Text>(label).style).color ??
        Theme.of(element).snackBarTheme.actionTextColor!;
    final ground = Theme.of(element).snackBarTheme.backgroundColor!;

    expect(_wcag(painted, ground), greaterThanOrEqualTo(4.5), reason: 'Undo must read on the snackbar');
  });
}
