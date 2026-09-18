import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/song_sheet_panel.dart';
import 'package:colabroom/features/workspace/sung_vs_written.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What you sang, beside what you wrote.
///
/// Every Musician, Same Song, 17 September 2026, slice 37, finishing step 4
/// of "A Second Pair of Ears". The app held the transcript of what was sung,
/// with a time on every word, and the lines somebody typed, and nobody could
/// see them together. Now the song sheet can put them side by side, line by
/// line: a comparison with no score, no percentage and nothing called a
/// mistake, where each line that differs offers to take the sung words
/// across — one line at a time, never the page.
void main() {
  group('line by line', () {
    test('each line on the page is paired with what was sung at it', () {
      // Four lines typed, four breaths sung. The third was sung "cat" over a
      // page that says "dog".
      final rows = pairSungWithWritten(
        _song(<String>[
          'walking home',
          'hold on tight',
          'I walked the dog at night',
          'and the stars came out',
        ]),
        _sung(<String>[
          'walking home',
          'hold on tight',
          'I walked the cat at night',
          'and the stars came out',
        ]),
      );
      expect(rows.map((row) => row.line?.id),
          <String>['line-1', 'line-2', 'line-3', 'line-4']);
      expect(rows[0].readsTheSame, isTrue);
      expect(rows[1].readsTheSame, isTrue);
      expect(rows[3].readsTheSame, isTrue);

      final changed = rows[2];
      expect(changed.differs, isTrue);
      expect(changed.written, 'I walked the dog at night');
      expect(changed.sung, 'I walked the cat at night');
      expect(_notShared(changed.writtenWords), <String>['dog']);
      expect(_notShared(changed.sungWords), <String>['cat']);
    });

    test('punctuation and case are not differences', () {
      expect(comparableWord("Don't,"), 'dont');
      expect(comparableWord('Hold'), 'hold');
      expect(comparableWord('—'), '');

      final rows = pairSungWithWritten(
        _song(<String>["Don't stop — hold on!"]),
        _sung(<String>['dont Stop hold on.']),
      );
      expect(rows.single.readsTheSame, isTrue);
      // The dash is not a word, so it is not a word on one side only.
      expect(rows.single.writtenWords.every((word) => word.shared), isTrue);
    });

    test('a line sung in two breaths is one line on the page', () {
      final rows = pairSungWithWritten(
        _song(<String>['hold on tight hold on tight']),
        _sung(<String>['hold on tight', 'hold on tight']),
      );
      expect(rows.single.readsTheSame, isTrue);
      expect(rows.single.sung, 'hold on tight hold on tight');
    });

    test('a word sung inside a line goes with that line', () {
      final rows = pairSungWithWritten(
        _song(<String>['walked the dog', 'hold on tight']),
        _sung(<String>['walked the old dog', 'hold on tight']),
      );
      expect(rows.first.differs, isTrue);
      expect(rows.first.sung, 'walked the old dog');
      expect(_notShared(rows.first.sungWords), <String>['old']);
      expect(rows.first.writtenWords.every((word) => word.shared), isTrue);
      expect(rows.last.readsTheSame, isTrue);
    });

    test(
        'a line written after the recording, and a phrase sung that was '
        'never written, are each shown as what they are', () {
      final rows = pairSungWithWritten(
        _song(<String>['walking home', 'a verse written later', 'hold on tight']),
        _sung(<String>['walking home', 'hold on tight', 'ooh yeah ooh']),
      );
      expect(rows.length, 4);
      expect(rows[0].readsTheSame, isTrue);

      final later = rows[1];
      expect(later.line?.id, 'line-2');
      expect(later.onThePage, isTrue);
      expect(later.wasSung, isFalse);
      expect(later.differs, isFalse);

      expect(rows[2].readsTheSame, isTrue);

      final unwritten = rows[3];
      expect(unwritten.onThePage, isFalse);
      expect(unwritten.sung, 'ooh yeah ooh');
      expect(unwritten.differs, isFalse);
    });

    test('a line rewritten after the recording shows the old words beside '
        'the new', () {
      // Nothing in "night falls slow" was sung, and nothing in "I walked my
      // dog" is on the page. They fall in the same place, so they are paired,
      // and the writer sees both.
      final rows = pairSungWithWritten(
        _song(<String>['walking home', 'night falls slow', 'hold on tight']),
        _sung(<String>['walking home', 'I walked my dog', 'hold on tight']),
      );
      expect(rows.map((row) => row.line?.id),
          <String>['line-1', 'line-2', 'line-3']);
      final rewritten = rows[1];
      expect(rewritten.differs, isTrue);
      expect(rewritten.written, 'night falls slow');
      expect(rewritten.sung, 'I walked my dog');
      expect(rewritten.writtenWords.any((word) => word.shared), isFalse);
      expect(rewritten.sungWords.any((word) => word.shared), isFalse);

      // With a word in common the pair still reads as a pair, and the word
      // they share is shared.
      final shared = pairSungWithWritten(
        _song(<String>['walking home', 'the night is long', 'hold on tight']),
        _sung(<String>['walking home', 'I walked the dog', 'hold on tight']),
      )[1];
      expect(shared.differs, isTrue);
      expect(shared.sung, 'I walked the dog');
      expect(_notShared(shared.writtenWords), <String>['night', 'is', 'long']);
      expect(_notShared(shared.sungWords), <String>['I', 'walked', 'dog']);
    });

    test('with no words in common the lines are paired in order', () {
      final rows = pairSungWithWritten(
        _song(<String>['uno dos', 'tres cuatro']),
        _sung(<String>['one two', 'three four']),
      );
      expect(rows.map((row) => row.line?.id), <String>['line-1', 'line-2']);
      expect(rows[0].sung, 'one two');
      expect(rows[1].sung, 'three four');
      expect(rows.every((row) => row.differs), isTrue);
    });

    test('a song with no typed words offers nothing', () {
      expect(pairSungWithWritten(_song(<String>[]), _sung(<String>['walking home'])),
          isEmpty);
      // Blank lines, notes and section names are not words on the page.
      final blanks = _song(<String>[]).copyWith(contributions: <Contribution>[
        _line('c1', '   ', 1),
        _line('c2', 'Chorus', 2),
        Contribution(
          id: 'c3',
          projectId: 'song-sung',
          authorId: 'me',
          authorName: 'Me',
          body: 'try this softer',
          colorValue: 1,
          createdAt: DateTime(2026, 9, 17),
          position: 3,
          kind: ContributionKind.note,
        ),
      ]);
      expect(pairSungWithWritten(blanks, _sung(<String>['walking home'])), isEmpty);
    });

    test('a song with no transcript offers nothing', () {
      final written = _song(<String>['walking home']);
      expect(pairSungWithWritten(written, _sung(<String>[])), isEmpty);
      // Text alone, with no time on any word, is not a transcript this can
      // pair from -- and neither is no recording at all.
      final textOnly = _sung(<String>[]).copyWith(
        reference: ReferenceTrack(
          projectId: 'song-sung',
          fileId: 'file',
          storagePath: 'room/song-sung/reference.m4a',
          displayName: 'reference.m4a',
          state: SongAnalysisState.ready,
          transcriptText: 'walking home',
        ),
      );
      expect(pairSungWithWritten(written, textOnly), isEmpty);
      expect(
        pairSungWithWritten(
          written,
          const SongAnalysisBundle(
            reference: null,
            lyricCues: <LyricSyncCue>[],
            chordCues: <ChordCue>[],
          ),
        ),
        isEmpty,
      );
    });
  });

  group('on the song sheet', () {
    testWidgets('a difference is shown plainly, with no score', (tester) async {
      await _openTheSheet(
        tester,
        project: _song(<String>[
          'walking home',
          'hold on tight',
          'I walked the dog at night',
          'and the stars came out',
        ]),
        bundle: _sung(<String>[
          'walking home',
          'hold on tight',
          'I walked the cat at night',
          'and the stars came out',
        ]),
        onUseSung: (_, __) async {},
      );

      // Both lines, in the row for the line that differs.
      final row = find.byKey(const Key('sung_written_line-3'));
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.text('I walked the dog at night')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.text('I walked the cat at night')),
        findsOneWidget,
      );
      // The word on one side only is in the text colour; the words on both
      // sides fall back. Nothing is red.
      expect(_colorOfWord(tester, row, 'dog'), AppColors.text);
      expect(_colorOfWord(tester, row, 'cat'), AppColors.text);
      expect(_colorOfWord(tester, row, 'walked'), AppColors.muted);

      // The lines that read the same say so, and offer nothing.
      expect(find.text('Sung as written'), findsNWidgets(3));
      expect(find.text('Use what was sung'), findsOneWidget);
      expect(find.byKey(const Key('use_sung_line-3')), findsOneWidget);

      // A comparison, not a mark.
      final sheet = find.byKey(const Key('sung_and_written_sheet'));
      for (final text in tester
          .widgetList<Text>(find.descendant(of: sheet, matching: find.byType(Text)))) {
        final words = (text.data ?? text.textSpan?.toPlainText() ?? '').toLowerCase();
        expect(words.contains('%'), isFalse, reason: 'a percentage: $words');
        for (final mark in <String>['score', 'mistake', 'wrong', 'accura', 'match', 'error']) {
          expect(words.contains(mark), isFalse, reason: 'a mark: $words');
        }
      }
    });

    testWidgets('taking one line across changes that line and nothing else',
        (tester) async {
      // Through the controller and the in-memory repository, the same write
      // as editing the line by hand.
      final controller = MusicBetaController(InMemoryMusicRepository.seeded());
      await controller.load();
      final room = controller.rooms.firstWhere((room) => room.id == 'room-1');
      var song = await controller.createSong(room, 'Hold On');
      for (final body in <String>[
        'walking home',
        'hold on tight',
        'I walked the dog at night',
        'and the stars came out',
      ]) {
        await controller.addContribution(song, body);
      }
      song = _fromController(controller, song.id);
      final changed = song.contributions[2];
      expect(changed.body, 'I walked the dog at night');

      await _openTheSheet(
        tester,
        project: song,
        bundle: _sung(<String>[
          'walking home',
          'hold on tight',
          'I walked the cat at night',
          'and the stars came out',
        ]),
        onUseSung: controller.updateContribution,
      );
      await tester.tap(find.byKey(Key('use_sung_${changed.id}')));
      await tester.pumpAndSettle();

      final after = _fromController(controller, song.id);
      expect(after.contributions.map((line) => line.body), <String>[
        'walking home',
        'hold on tight',
        'I walked the cat at night',
        'and the stars came out',
      ]);
      // The same line, one revision on; not a new one.
      final taken = after.contributions[2];
      expect(taken.id, changed.id);
      expect(taken.authorId, changed.authorId);
      expect(taken.revision, changed.revision + 1);

      // The row now reads as sung as written, and offers nothing more.
      expect(find.text('Sung as written'), findsNWidgets(4));
      expect(find.text('Use what was sung'), findsNothing);
    });

    testWidgets('somebody who may only look can read it and not change it',
        (tester) async {
      await _openTheSheet(
        tester,
        project: _song(<String>['walking home', 'I walked the dog at night']),
        bundle: _sung(<String>['walking home', 'I walked the cat at night']),
        onUseSung: null,
      );
      expect(find.byKey(const Key('sung_written_line-2')), findsOneWidget);
      expect(find.text('I walked the cat at night'), findsOneWidget);
      expect(find.text('Use what was sung'), findsNothing);
    });

    testWidgets('a song with nothing typed offers nothing', (tester) async {
      await _pumpThePanel(
        tester,
        project: _song(<String>[]),
        bundle: _sung(<String>['walking home']),
      );
      expect(find.byKey(const Key('sung_and_written')), findsNothing);
    });

    testWidgets('a song with no transcript offers nothing', (tester) async {
      await _pumpThePanel(
        tester,
        project: _song(<String>['walking home']),
        bundle: _sung(<String>[]),
      );
      expect(find.byKey(const Key('sung_and_written')), findsNothing);
    });
  });
}

List<String> _notShared(List<ComparedWord> words) => <String>[
      for (final word in words)
        if (!word.shared) word.text,
    ];

/// The colour a word in [row] is drawn in: the span that holds exactly that
/// word, inside the row's rich text.
Color _colorOfWord(WidgetTester tester, Finder row, String word) {
  for (final text in tester
      .widgetList<Text>(find.descendant(of: row, matching: find.byType(Text)))) {
    final span = text.textSpan;
    if (span == null) continue;
    Color? found;
    span.visitChildren((child) {
      if (child is TextSpan && child.text == word) {
        found = child.style?.color;
        return false;
      }
      return true;
    });
    if (found != null) return found!;
  }
  throw StateError('"$word" is not in the row');
}

SongProject _fromController(MusicBetaController controller, String id) =>
    controller.rooms
        .expand((room) => room.projects)
        .firstWhere((project) => project.id == id);

Future<void> _pumpThePanel(
  WidgetTester tester, {
  required SongProject project,
  required SongAnalysisBundle bundle,
  Future<void> Function(Contribution line, String words)? onUseSung,
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  // The width the other sheet tests use; the panel's toolbar overflows the
  // test font narrower than this, and that row is not what is on trial here.
  tester.view.physicalSize = const Size(520, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: SingleChildScrollView(
        child: SongSheetPanel(
          project: project,
          bundle: bundle,
          onReviewLyrics: null,
          onOpenLive: null,
          onUseSung: onUseSung,
        ),
      ),
    ),
  ));
  await tester.pump();
  await tester.pump();
}

Future<void> _openTheSheet(
  WidgetTester tester, {
  required SongProject project,
  required SongAnalysisBundle bundle,
  required Future<void> Function(Contribution line, String words)? onUseSung,
}) async {
  await _pumpThePanel(tester, project: project, bundle: bundle, onUseSung: onUseSung);
  await tester.ensureVisible(find.byKey(const Key('sung_and_written')));
  await tester.tap(find.byKey(const Key('sung_and_written')));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('sung_and_written_sheet')), findsOneWidget);
}

Contribution _line(String id, String body, double position) => Contribution(
      id: id,
      projectId: 'song-sung',
      authorId: 'me',
      authorName: 'Me',
      body: body,
      colorValue: 0xFFFF8A4C,
      createdAt: DateTime(2026, 9, 17),
      position: position,
    );

/// A song with these lines typed on its page, in this order.
SongProject _song(List<String> lines) {
  final at = DateTime(2026, 9, 17);
  return SongProject(
    id: 'song-sung',
    roomId: 'room',
    accountId: 'me',
    title: 'Hold On',
    createdAt: at,
    updatedAt: at,
    contributions: <Contribution>[
      for (var i = 0; i < lines.length; i += 1)
        _line('line-${i + 1}', lines[i], i + 1.0),
    ],
  );
}

/// A recording that sang these phrases, one breath each, with a time on
/// every word: words four hundred milliseconds long with a tenth of a second
/// between them, and a pause between breaths long enough for the sheet to
/// break a line there.
SongAnalysisBundle _sung(List<String> breaths) {
  final words = <TranscriptWord>[];
  var at = 2000;
  for (final breath in breaths) {
    for (final word in breath.split(' ')) {
      words.add(TranscriptWord(word: word, startMs: at, endMs: at + 400));
      at += 500;
    }
    at += 1500;
  }
  return SongAnalysisBundle(
    reference: ReferenceTrack(
      projectId: 'song-sung',
      fileId: 'file',
      storagePath: 'room/song-sung/reference.m4a',
      displayName: 'Hold On.m4a',
      state: SongAnalysisState.ready,
      durationMs: at + 2000,
      musicalKey: 'G',
      transcriptText: words.map((word) => word.word).join(' '),
      transcriptWords: words,
    ),
    lyricCues: const <LyricSyncCue>[],
    chordCues: const <ChordCue>[],
  );
}
