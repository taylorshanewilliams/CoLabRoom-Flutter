import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/features/workspace/making_the_sheet.dart';
import 'package:colabroom/services/audio_analysis_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The wait is minutes long and it is the app's best minute.
///
/// What is worth locking down is not how it looks but what it *says*: the
/// stages are the pipeline's own, the finished ones stay on screen so the wait
/// accumulates rather than loops, and nobody is ever told they have to watch.
Future<void> _pump(WidgetTester tester, double fraction) async {
  tester.view.physicalSize = const Size(360, 690);
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = 1.3;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  await tester.pumpWidget(MaterialApp(
    theme: CoLabRoomTheme.dark(),
    home: Scaffold(
      body: SingleChildScrollView(
        child: MakingTheSheet(
          progress: SongAnalysisProgress('working', fraction),
          songTitle: 'Midnight Signal',
        ),
      ),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 60));
}

void main() {
  testWidgets('it says what is happening, at a size somebody can read',
      (tester) async {
    await _pump(tester, 0.02);
    expect(tester.takeException(), isNull);

    // "Separating the instruments" is a genuinely interesting sentence and it
    // used to be rendered at 10.5px in grey.
    final headline = tester.widget<Text>(
      find.text('Listening to your recording'),
    );
    expect(headline.style?.fontSize, greaterThan(18),
        reason: 'the best minute in the app is in disclaimer type again');
  });

  testWidgets('the wait accumulates rather than loops', (tester) async {
    await _pump(tester, 0.6);
    expect(tester.takeException(), isNull);

    // Everything already done stays on screen. A bar that loops tells you
    // nothing has happened; a list that grows shows the song being understood.
    expect(find.text('Listening to your recording'), findsOneWidget);
    expect(find.text('Separating the instruments'), findsOneWidget);
    expect(find.text('Working out every chord'), findsOneWidget);

    // The one happening right now is the headline.
    expect(find.text('Writing down the words you sang'), findsOneWidget);

    // And what has not happened yet is not claimed. A wait that ticks off
    // work nobody has done is worse than one that says nothing.
    expect(find.text('Putting the song sheet together'), findsNothing);
  });

  testWidgets('nobody is told they have to watch', (tester) async {
    await _pump(tester, 0.3);
    // The wait is minutes long and songwriting is what the app is for.
    expect(
      find.textContaining('This keeps going without you'),
      findsOneWidget,
      reason: 'somebody was left thinking they had to sit through it',
    );
  });

  testWidgets('it draws at the smallest phone and the largest text',
      (tester) async {
    for (final fraction in <double>[0.0, 0.15, 0.5, 0.95, 1.0]) {
      await _pump(tester, fraction);
      expect(tester.takeException(), isNull,
          reason: 'the sheet-making panel broke at $fraction');
    }
  });
}
