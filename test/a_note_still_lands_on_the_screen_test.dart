import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/widgets/note_that_fits.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A snackbar the app shows is still on the screen at the largest text size.
///
/// iOS's largest accessibility size reaches Flutter as 3.12x, and the app
/// stopped clamping it (Every Musician, Same Song, 17 September 2026). At that
/// size Perform's "the recording could not be loaded" note is over 500 logical
/// pixels tall on a 390-wide phone. A floating snackbar is positioned upwards
/// from whichever is higher of the record button and the tab bar, and on a
/// phone at that text size the arithmetic ran out: in a debug build Flutter
/// throws "Floating SnackBar presented off screen" while it lays out, and in a
/// release build — where that assertion is gone — the sentence is simply drawn
/// where nobody can see it.
///
/// Which is the bad half. The person who cannot read small type is the person
/// who never gets told why the song is playing silently.
///
/// Found by the render harness: `test_render/` walks Perform at 3.12x and the
/// throw was sitting in `build/eyes/REPORT.md` under "Threw while drawing",
/// counted but failing nothing. It fails the walk now, which is why this is
/// fixed here rather than written down. The walk over the real shell is the
/// test that would catch this coming back; what is checked here is the piece
/// it turns on, which is that the box has a ceiling and the words are all
/// still inside it at full size.
void main() {
  /// Roughly what a snackbar is measured against in this app: a record button
  /// over a tab bar. Not the real shell — the walk in `test_render/` is where
  /// the real one is drawn — but enough to put a floating snackbar under the
  /// same rule.
  Widget shell(GlobalKey<ScaffoldMessengerState> messengerKey, double scale) {
    return MaterialApp(
      theme: CoLabRoomTheme.dark(),
      scaffoldMessengerKey: messengerKey,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: const SizedBox.expand(),
        floatingActionButton: FloatingActionButton(
            onPressed: () {}, child: const Icon(Icons.mic_rounded)),
        bottomNavigationBar: SafeArea(
          top: false,
          child: NavigationBar(destinations: const <Widget>[
            NavigationDestination(icon: Icon(Icons.home_rounded), label: 'Home'),
            NavigationDestination(
                icon: Icon(Icons.library_music_rounded), label: 'Songs'),
            NavigationDestination(
                icon: Icon(Icons.forum_rounded), label: 'Messages'),
          ]),
        ),
      ),
    );
  }

  const Size phone = Size(390, 844);

  Future<void> show(WidgetTester tester, double scale, Widget content) async {
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final messengerKey = GlobalKey<ScaffoldMessengerState>();
    await tester.pumpWidget(shell(messengerKey, scale));
    messengerKey.currentState!.showSnackBar(SnackBar(content: content));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 750));
  }

  testWidgets('a note at the largest text size is drawn on the screen',
      (tester) async {
    await show(tester, 3.12, const NoteThatFits(recordingNotLoaded));

    expect(tester.takeException(), isNull,
        reason: 'the snackbar was positioned off the screen');

    final RenderBox box = tester.renderObject<RenderBox>(find.byType(SnackBar));
    final Offset topLeft = box.localToGlobal(Offset.zero);
    expect(topLeft.dy, greaterThanOrEqualTo(0),
        reason: 'the top of the note is above the top of the phone');
    expect(topLeft.dy + box.size.height, lessThanOrEqualTo(phone.height),
        reason: 'the bottom of the note is below the bottom of the phone');
  });

  testWidgets('the words are all there, at the size that was asked for',
      (tester) async {
    // The ceiling is on the box, not on the type: the sentence is laid out at
    // 3.12x and scrolls inside a box that fits. Nothing is shrunk to fit,
    // which is the rule the app has for its own text everywhere else.
    await show(tester, 3.12, const NoteThatFits(recordingNotLoaded));

    final RenderBox held =
        tester.renderObject<RenderBox>(find.byType(NoteThatFits));
    final RenderBox text =
        tester.renderObject<RenderBox>(find.text(recordingNotLoaded));

    expect(held.size.height, lessThan(phone.height * 0.46),
        reason: 'a passing note should never take half the screen');
    expect(text.size.height, greaterThan(held.size.height),
        reason: 'at 3.12x this sentence is taller than the box holding it, so '
            'this test is not quietly passing on a note that fits anyway');
    expect(find.byType(SingleChildScrollView), findsOneWidget,
        reason: 'the rest of the sentence has to be reachable');
  });

  testWidgets('at an ordinary text size the note is its own height',
      (tester) async {
    // The bound is a ceiling, not a shape: nothing about the usual case
    // changes, and a note that fits is still exactly as tall as its words.
    await show(tester, 1.0, const NoteThatFits(recordingNotLoaded));

    expect(tester.takeException(), isNull);
    final RenderBox held =
        tester.renderObject<RenderBox>(find.byType(NoteThatFits));
    final RenderBox text =
        tester.renderObject<RenderBox>(find.text(recordingNotLoaded));
    expect(held.size.height, text.size.height);
  });
}
