import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/lyric_review_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Review lyrics: which line you are on, and letting go of a line you remove.
///
/// The naming is the bug #411 found on its way past this screen. Every
/// correction field opens with the mis-heard words already in it, so the
/// `hintText` that was its only name — "Line 3" — is never built, and a
/// reader heard eleven fields say their words with nothing anywhere saying
/// which of them it was on. The buttons beside them all said "Remove line",
/// which is a column nobody can choose from either.
///
/// Every Musician, Same Song, 17 September 2026: a musician who cannot see
/// the screen has to be able to tell what they are typing into.
///
/// The disposal was reported alongside it as a leak, and it is not one —
/// `_removeLine` has disposed the controller it removes since the screen was
/// written. What was missing was anything holding that down, and the awkward
/// part of it is not the disposal but its timing: it happens while the field
/// is still built, a frame before the rebuild that drops it. So that is what
/// the last three cases are about, including the line that had the keyboard
/// on it when it went.

/// Five lines of two words each, split by pauses the grouper will honour
/// (from 650ms apart it starts a new line).
List<TranscriptWord> _fiveLines() {
  const words = <List<String>>[
    <String>['one', 'alpha'],
    <String>['two', 'bravo'],
    <String>['three', 'charlie'],
    <String>['four', 'delta'],
    <String>['five', 'echo'],
  ];
  final result = <TranscriptWord>[];
  for (var line = 0; line < words.length; line += 1) {
    final base = line * 2000;
    result.add(TranscriptWord(word: words[line][0], startMs: base, endMs: base + 300));
    result.add(TranscriptWord(word: words[line][1], startMs: base + 400, endMs: base + 700));
  }
  return result;
}

/// A tall phone, so all five lines are built and none is off the bottom.
Future<void> _openTheReview(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final controller = MusicBetaController(InMemoryMusicRepository.seeded());
  await controller.load();
  addTearDown(controller.dispose);
  final project = controller.rooms.first.projects.first;

  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: LyricReviewScreen(
        project: project,
        reference: ReferenceTrack(
          projectId: project.id,
          fileId: 'file-1',
          storagePath: 'takes/file-1.m4a',
          displayName: 'south of midnight 2.m4a',
          state: SongAnalysisState.ready,
          transcriptText: 'one alpha two bravo three charlie four delta five echo',
          transcriptWords: _fiveLines(),
        ),
      ),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

Finder _line(int index) => find.byKey(Key('review_lyric_line_$index'));

TextEditingController _controllerOf(WidgetTester tester, int index) =>
    tester.widget<TextField>(_line(index)).controller!;

/// Whether [notifier] has been disposed, asked of the one instance taken out
/// of the tree rather than of a counter: `debugAssertNotDisposed` throws for
/// a disposed one and returns true for a live one, so asking it is the
/// observation itself.
bool _isDisposed(ChangeNotifier notifier) {
  try {
    ChangeNotifier.debugAssertNotDisposed(notifier);
    return false;
  } on FlutterError {
    return true;
  }
}

void main() {
  testWidgets('the third line of five says it is line 3', (tester) async {
    final semantics = tester.ensureSemantics();

    await _openTheReview(tester);

    final data = tester.getSemantics(_line(2)).getSemanticsData();
    expect(data.label, 'Line 3');
    expect(data.value, contains('three'),
        reason: 'the name has to be on the node that holds the words, not above it');
    expect(data.flagsCollection.isTextField, isTrue,
        reason: 'the name arrives with the role, not instead of it');

    semantics.dispose();
  });

  testWidgets('a line emptied down to nothing still says which line it is',
      (tester) async {
    // The one state the old hint did cover. It is covered twice over now:
    // the painted hint folds into the name, so it is said twice on this one
    // line, which is repetition rather than silence.
    final semantics = tester.ensureSemantics();

    await _openTheReview(tester);
    await tester.enterText(_line(2), '');
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.getSemantics(_line(2)).getSemanticsData().label,
        startsWith('Line 3'));

    semantics.dispose();
  });

  testWidgets('the button beside a line says which line it removes',
      (tester) async {
    final semantics = tester.ensureSemantics();

    await _openTheReview(tester);

    expect(find.byTooltip('Remove line 3'), findsOneWidget);
    expect(find.byTooltip('Remove line'), findsNothing,
        reason: 'no two of these five say the same thing');
    // A tooltip is how the rest of the app names an icon button, and it is
    // what both readers say: the engine appends the node's tooltip to what
    // it announces.
    final data =
        tester.getSemantics(find.byTooltip('Remove line 3')).getSemanticsData();
    expect(data.tooltip, 'Remove line 3');
    expect(data.flagsCollection.isButton, isTrue);

    semantics.dispose();
  });

  testWidgets('removing line 2 lets go of exactly that line', (tester) async {
    await _openTheReview(tester);

    final before = <TextEditingController>[
      for (var i = 0; i < 5; i += 1) _controllerOf(tester, i),
    ];
    expect(before[1].text, 'two bravo');

    await tester.tap(find.byTooltip('Remove line 2'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(tester.takeException(), isNull,
        reason: 'nothing may be built against a controller that has gone');
    expect(_isDisposed(before[1]), isTrue,
        reason: 'the removed line lets go of its controller there and then');
    for (final kept in <TextEditingController>[
      before[0],
      before[2],
      before[3],
      before[4],
    ]) {
      expect(_isDisposed(kept), isFalse, reason: 'only the removed line is disposed');
    }

    // Four lines left, in order, and they still take typing.
    expect(_line(4), findsNothing);
    expect(_controllerOf(tester, 0).text, 'one alpha');
    expect(_controllerOf(tester, 1).text, 'three charlie');
    expect(_controllerOf(tester, 3).text, 'five echo');

    await tester.enterText(_line(1), 'three corrected');
    await tester.pump();
    expect(before[2].text, 'three corrected');
    await tester.enterText(_line(3), 'five corrected');
    await tester.pump();
    expect(before[4].text, 'five corrected');
    expect(tester.takeException(), isNull);

    // And the buttons renumber with the lines, so the fourth line of four is
    // the last one there is a button for.
    expect(find.byTooltip('Remove line 4'), findsOneWidget);
    expect(find.byTooltip('Remove line 5'), findsNothing);
  });

  testWidgets('the line the keyboard is on can be removed', (tester) async {
    // The case where a disposal a frame early would be felt: the removed
    // field is the one holding the text input connection.
    await _openTheReview(tester);
    final second = _controllerOf(tester, 1);

    await tester.tap(_line(1));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.enterText(_line(1), 'two corrected');
    await tester.pump();

    await tester.tap(find.byTooltip('Remove line 2'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(tester.takeException(), isNull);
    expect(_isDisposed(second), isTrue);

    await tester.enterText(_line(1), 'three corrected');
    await tester.pump();
    expect(_controllerOf(tester, 1).text, 'three corrected');
    expect(tester.takeException(), isNull);
  });

  testWidgets('every line can be removed, and then the screen closed',
      (tester) async {
    await _openTheReview(tester);
    final all = <TextEditingController>[
      for (var i = 0; i < 5; i += 1) _controllerOf(tester, i),
    ];

    for (var i = 0; i < 5; i += 1) {
      await tester.tap(find.byTooltip('Remove line 1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(tester.takeException(), isNull, reason: 'removing line ${i + 1} of five');
    }
    expect(find.byType(TextField), findsNothing);
    // Save is the only thing on the bar and there is nothing left to save.
    expect(
      tester.widget<TextButton>(find.byKey(const Key('save_reviewed_lyrics'))).onPressed,
      isNull,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(tester.takeException(), isNull,
        reason: 'closing the screen must not dispose anything a second time');
    for (final controller in all) {
      expect(_isDisposed(controller), isTrue);
    }
  });
}
