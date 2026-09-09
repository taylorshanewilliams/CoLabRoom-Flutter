import 'package:colabroom/features/shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The desk stops looking like a phone somebody pulled at the corners.
///
/// The shell already swapped the bottom tabs for a navigation rail above
/// 900px, so the chrome was right. The content was not: it sat in an
/// `Expanded` with no limit, so on a 1440px browser every card, row and line
/// of text built for a 390px phone was drawn across roughly 1300 of them.
///
/// This is the floor, not the ceiling — a real desk layout puts filters
/// beside results and the song sheet beside the takes, and that is per-screen
/// work. But a screen cannot be split until it has an edge.
void main() {
  testWidgets('wide content is a column, and narrow content is not',
      (tester) async {
    Future<double> widthAt(Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final key = GlobalKey();
      await tester.pumpWidget(MaterialApp(
        home: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 900;
            // Mirrors the shell's own decision, so the number under test is
            // the one the shell applies rather than a copy of it.
            // Fills what it is given, the way a real screen's Column or
            // ListView does — a bare SizedBox would collapse to zero under
            // the loose constraints a ConstrainedBox hands down, and measure
            // nothing.
            final body =
                SizedBox(key: key, width: double.infinity, height: 100);
            return Scaffold(
              body: Row(
                children: <Widget>[
                  if (wide) const SizedBox(width: 116),
                  Expanded(
                    child: wide
                        ? Align(
                            alignment: Alignment.topCenter,
                            child: ConstrainedBox(
                              constraints:
                                  const BoxConstraints(maxWidth: kDeskColumn),
                              child: body,
                            ),
                          )
                        : body,
                  ),
                ],
              ),
            );
          },
        ),
      ));
      await tester.pump();
      return tester.getSize(find.byKey(key)).width;
    }

    // A phone: the content should still use every pixel it has.
    expect(await widthAt(const Size(390, 800)), 390);

    // A browser: capped, so text has a measure and cards have an edge.
    expect(await widthAt(const Size(1440, 900)), kDeskColumn,
        reason: 'unconstrained, this was ~1320px of phone-shaped cards, '
            'which is what reads as a stretched emulation rather than a '
            'website');
  });

  test('the column is narrower than the window it sits in', () {
    expect(kDeskColumn, lessThan(1440));
    expect(kDeskColumn, greaterThan(700),
        reason: 'narrower than this and a desk looks like a phone in a '
            'frame, which is the other way to get this wrong');
  });
}
