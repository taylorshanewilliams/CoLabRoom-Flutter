import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/openmic/open_mic_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A person card says what somebody plays, never how much of it they have done.
///
/// The Open Mic listed "drums · 12" and "11 songs · 6 people" under one person
/// and "nothing recorded here yet" under the next. Each figure was honest on
/// its own; stacked down a screen they are a scoreboard, and the person who
/// joined this week is at the bottom of it every time. That is the ladder the
/// closeness ordering exists to avoid, so the numbers are gone and a claim is
/// drawn in the same place and shape as a recording (Taylor, 17 September
/// 2026: "whichever you think is more useful and best for the brand").
Future<MusicBetaController> _openMic(WidgetTester tester) async {
  final repository = InMemoryMusicRepository.seeded();
  final controller = MusicBetaController(repository);
  await controller.load();
  addTearDown(controller.dispose);
  tester.view.physicalSize = const Size(390, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: Scaffold(body: OpenMicScreen(repository: repository, showTopBar: false)),
    ),
  ));
  for (var i = 0; i < 6; i += 1) {
    await tester.pump(const Duration(milliseconds: 300));
  }
  return controller;
}

/// Every piece of text on screen, offstage included.
List<String> _words(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text, skipOffstage: false))
    .map((text) => text.data ?? '')
    .toList(growable: false);

void main() {
  testWidgets('the parts somebody plays are named, not counted', (tester) async {
    await _openMic(tester);

    // Mara has recorded vocal and harmony; Dev has recorded drums. The seeded
    // repository counts them (9, 4 and 12), and the cards say none of it.
    expect(find.text('vocal', skipOffstage: false), findsWidgets);
    expect(find.text('drums', skipOffstage: false), findsWidgets);
    for (final word in _words(tester)) {
      expect(word, isNot(matches(RegExp(r'^(vocal|harmony|drums|bass|lead|rhythm|keys)\s·\s\d+$'))),
          reason: 'a part with a tally beside it is a score: "$word"');
    }
  });

  testWidgets('no card totals up songs or people', (tester) async {
    await _openMic(tester);

    for (final word in _words(tester)) {
      expect(word, isNot(matches(RegExp(r'\d+\s+(song|songs)\s·\s\d+\s+(person|people)'))),
          reason: 'the record of how much somebody has done is not on a card: "$word"');
      expect(word, isNot(contains('nothing recorded here yet')),
          reason: 'a card never says what somebody has not done');
      expect(word, isNot(contains('Has not recorded anything here yet')),
          reason: 'a card never says what somebody has not done');
    }
  });

  testWidgets('somebody with nothing recorded still shows what they play', (tester) async {
    await _openMic(tester);

    // Sam Reyes is in the seeded room with plays set and nothing recorded. The
    // card carries their parts in the same place a recorded part would sit, so
    // a new musician's card is the same shape as everybody else's.
    expect(find.text('Sam Reyes', skipOffstage: false), findsOneWidget);
    expect(find.text('lead', skipOffstage: false), findsWidgets);
    expect(find.text('rhythm', skipOffstage: false), findsWidgets);
  });
}
