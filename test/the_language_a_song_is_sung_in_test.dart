import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/chord_sheet_export.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:colabroom/features/workspace/musician_song_sheet.dart';
import 'package:colabroom/features/workspace/song_sheet_panel.dart';
import 'package:colabroom/services/song_analysis_service.dart';
import 'package:colabroom/services/song_language.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every Musician, Same Song, 17 September 2026, world traditions item 3.
///
/// The sheet assumed one way of writing words down: left to right, with
/// spaces between them. These are the two songs that assumption got wrong,
/// and the third song — an English one — that has to come out of every
/// change here exactly as it went in.
void main() {
  group('a language tag', () {
    test('is kept in one spelling however it is typed', () {
      expect(languageTagTyped('ar'), 'ar');
      expect(languageTagTyped(' AR '), 'ar');
      expect(languageTagTyped('zh-hans'), 'zh-Hans');
      expect(languageTagTyped('pt-br'), 'pt-BR');
      expect(languageTagTyped('es-419'), 'es-419');
      // Not a tag, and a name is not a tag either: the page and the
      // transcriber are driven by the code, and "Arabic" drives neither.
      expect(languageTagTyped('Arabic'), isNull);
      expect(languageTagTyped('ar-EG-cairo'), isNull);
      expect(languageTagTyped(''), isNull);
      expect(languageTagTyped(null), isNull);
    });

    test('says which way a song is read and what a chord sits over', () {
      expect(readsRightToLeft('ar'), isTrue);
      expect(readsRightToLeft('he'), isTrue);
      expect(readsRightToLeft('fa'), isTrue);
      expect(readsRightToLeft('ur'), isTrue);
      expect(readsRightToLeft('en'), isFalse);
      // A song nobody has answered for is read the way this app always read
      // one. Nothing is inferred from the words themselves.
      expect(readsRightToLeft(null), isFalse);

      expect(anchorsByCharacter('zh'), isTrue);
      expect(anchorsByCharacter('ja'), isTrue);
      expect(anchorsByCharacter('th'), isTrue);
      // Korean is written in its own script and spaces its words, so it
      // splits the way English does.
      expect(anchorsByCharacter('ko'), isFalse);
      expect(anchorsByCharacter('en'), isFalse);
      expect(anchorsByCharacter(null), isFalse);
    });

    test('offers what the writer already said they sing in', () {
      // 0156 keeps words, not tags, and keeps them folded. A tradition is
      // not a language and is simply not offered.
      expect(
        languageTagsSuggestedBy(<String>['portuguese', 'carnatic', 'mandarin']),
        <String>['pt', 'zh'],
      );
      expect(languageTagsSuggestedBy(const <String>[]), isEmpty);
    });
  });

  group('the pieces a chord sits over', () {
    test('are words in a language that writes them with spaces', () {
      expect(
        lyricUnits('Streetlights blur in the rain', language: 'en'),
        <String>['Streetlights', 'blur', 'in', 'the', 'rain'],
      );
      // And with no language at all, which is every song until somebody
      // says: exactly what splitting on white space always did.
      expect(
        lyricUnits('Streetlights blur in the rain'),
        <String>['Streetlights', 'blur', 'in', 'the', 'rain'],
      );
    });

    test('are characters in a script that does not space them', () {
      expect(
        lyricUnits('月光落在窗前', language: 'zh'),
        <String>['月', '光', '落', '在', '窗', '前'],
      );
      // A Thai vowel sign written above a consonant, and the tone mark
      // above that, are one thing to read and one thing to hang a chord
      // over — so the pieces are grapheme clusters and not code points.
      expect(
        lyricUnits('ที่นี่', language: 'th'),
        <String>['ที่', 'นี่'],
      );
    });
  });

  group('an Arabic song', () {
    test('anchors its chords to the words, right to left', () async {
      final lines = _arabicLines(language: 'ar');
      expect(lines.length, 1);
      expect(lines.first.units, <String>['الليل', 'يمر', 'على', 'النهر']);

      final placements = chordPlacementsForLine(
        wordCount: lines.first.units.length,
        lineStartMs: lines.first.startMs,
        lineEndMs: lines.first.endMs,
        chords: lines.first.chords,
        wordStartsMs: lines.first.wordStartsMs,
      );
      // The first chord belongs to the first word — which, on this song, is
      // the one furthest right on the page.
      expect(placements[0]?.chord, 'G');
      expect(placements[3]?.chord, 'C');
    });

    testWidgets('is drawn from the right, with its chords over it',
        (tester) async {
      await tester.pumpWidget(_sheet(_arabicLines(language: 'ar')));
      await tester.pumpAndSettle();

      // The words are laid out right to left, so the first word of the line
      // is further right than the last.
      expect(
        Directionality.of(tester.element(find.text('الليل'))),
        TextDirection.rtl,
      );
      expect(
        tester.getCenter(find.text('الليل')).dx,
        greaterThan(tester.getCenter(find.text('النهر')).dx),
      );
      // And each chord sits over the word it changes on, so the chord order
      // runs the same way the words do.
      expect(
        tester.getCenter(find.text('G')).dx,
        greaterThan(tester.getCenter(find.text('C')).dx),
      );
      // The chord is over the start of its word, which on this page is the
      // word's right-hand end.
      expect(
        tester.getTopRight(find.text('G')).dx,
        closeTo(tester.getTopRight(find.text('الليل')).dx, 6),
      );
    });

    testWidgets('and the same words with nothing said run the other way',
        (tester) async {
      await tester.pumpWidget(_sheet(_arabicLines(language: null)));
      await tester.pumpAndSettle();

      // Nothing is inferred from the characters. A song nobody has answered
      // for is laid out exactly as this app always laid one out — which for
      // these words is wrong, and is the reason the question is asked.
      expect(
        Directionality.of(tester.element(find.text('الليل'))),
        TextDirection.ltr,
      );
      expect(
        tester.getCenter(find.text('G')).dx,
        lessThan(tester.getCenter(find.text('C')).dx),
      );
    });
  });

  group('a Chinese song', () {
    test('anchors its chords by character', () {
      final lines = _chineseLines(language: 'zh');
      expect(lines.length, 1);
      final line = lines.first;
      // No spaces between the characters: a line of Chinese spaced out one
      // character at a time is a line no reader of it has ever seen.
      expect(line.body, '月光落在窗前');
      expect(line.units, <String>['月', '光', '落', '在', '窗', '前']);
      // One start per character, so the timing is real rather than a guess
      // spread across the whole line.
      expect(line.wordStartsMs, <int>[0, 500, 1000, 1500, 2000, 2500]);

      final placements = chordPlacementsForLine(
        wordCount: line.units.length,
        lineStartMs: line.startMs,
        lineEndMs: line.endMs,
        chords: line.chords,
        wordStartsMs: line.wordStartsMs,
      );
      expect(placements[0]?.chord, 'G');
      expect(placements[4]?.chord, 'C');
    });

    testWidgets('draws each character with its own place for a chord',
        (tester) async {
      await tester.pumpWidget(_sheet(_chineseLines(language: 'zh')));
      await tester.pumpAndSettle();

      for (final character in <String>['月', '光', '落', '在', '窗', '前']) {
        expect(find.text(character), findsOneWidget, reason: character);
      }
      // The second chord used to land on the first character beside the
      // first chord, because a line with no spaces in it is one word.
      expect(
        tester.getTopLeft(find.text('C')).dx,
        closeTo(tester.getTopLeft(find.text('窗')).dx, 6),
      );
      expect(
        tester.getCenter(find.text('G')).dx,
        lessThan(tester.getCenter(find.text('C')).dx),
      );
    });

    test('with nothing said is laid out as today', () {
      final line = _chineseLines(language: null).first;
      // Joined with spaces and split on them: three pieces, not six. Wrong
      // for this song, and unchanged from what every song did before.
      expect(line.body, '月光 落在 窗前');
      expect(line.units, <String>['月光', '落在', '窗前']);
      expect(line.wordStartsMs, <int>[0, 1000, 2000]);
    });

    test('prints a chart that agrees with the sheet', () {
      final line = _chineseLines(language: 'zh').first;
      final chart = ChordSheetExport.textLine(line, transpose: 0);
      // The chart counts the same pieces the sheet does, so the chord that
      // is over the fifth character on screen is over the fifth column on
      // paper. The characters themselves print as '?': the built-in PDF
      // fonts are Latin-1 (see ProjectExportService.printable), which this
      // slice does not change.
      expect(chart.words.length, 6);
      expect(chart.chords.indexOf('G'), 0);
      expect(chart.chords.indexOf('C'), 4);
    });
  });

  group('an English song', () {
    test('is split, anchored and laid out exactly as before', () {
      final now = DateTime(2026, 9, 18);
      final project = SongProject(
        id: 'song-1',
        roomId: 'room-1',
        accountId: 'account-1',
        title: 'Midnight Signal',
        createdAt: now,
        updatedAt: now,
        contributions: <Contribution>[
          Contribution(
            id: 'line-1',
            projectId: 'song-1',
            authorId: 'user-1',
            authorName: 'Taylor',
            body: 'Streetlights blur in the rain',
            colorValue: 0xFFFF8A4C,
            createdAt: now,
            position: 1024,
          ),
        ],
      );
      const bundle = SongAnalysisBundle(
        reference: ReferenceTrack(
          projectId: 'song-1',
          fileId: 'file-1',
          storagePath: 'room/song/reference.wav',
          displayName: 'reference.wav',
          state: SongAnalysisState.ready,
          durationMs: 4000,
        ),
        lyricCues: <LyricSyncCue>[],
        chordCues: <ChordCue>[],
      );

      final lines = buildMusicianSheetLines(project, bundle);
      expect(lines.single.language, isNull);
      expect(
        lines.single.units,
        <String>['Streetlights', 'blur', 'in', 'the', 'rain'],
      );
    });
  });

  group('what the transcriber is told', () {
    test('carries the language the room said the song is sung in', () {
      final request = transcribeRequest(
        _song(language: 'ar'),
        'room/song/vocals.mp3',
      );
      expect(request['language'], 'ar');
      expect(request['storagePath'], 'room/song/vocals.mp3');
    });

    test('says nothing about the language when nobody has', () {
      // Whisper then detects it, which is what it did before this and what
      // it still does for every song nobody has answered for.
      final request = transcribeRequest(_song(), 'room/song/vocals.mp3');
      expect(request.containsKey('language'), isFalse);
    });

    test('is folded to one spelling, whatever is stored', () {
      final request =
          transcribeRequest(_song(language: 'ZH-hans'), 'room/song/a.mp3');
      expect(request['language'], 'zh-Hans');
    });
  });

  group('saying what a song is sung in', () {
    test('is the owner or an editor, and nobody else', () async {
      final repository = InMemoryMusicRepository.seeded();

      await repository.setSongLanguage('song-1', 'ar');
      expect(await _languageOf(repository, 'song-1'), 'ar');

      // The editor in the seeded room. It is usually the singer who
      // noticed, not the person who owns the catalog.
      repository.currentUserId = 'preview-jess';
      await repository.setSongLanguage('song-1', 'he');
      expect(await _languageOf(repository, 'song-1'), 'he');

      // Somebody with no role in the room at all: the case the null-safety
      // in 0163's guard is for, refused here in the same words.
      repository.currentUserId = 'somebody-else';
      await expectLater(
        repository.setSongLanguage('song-1', 'fa'),
        throwsA(isA<StateError>()),
      );
      expect(await _languageOf(repository, 'song-1'), 'he');
    });

    test('takes the answer away again with a null', () async {
      final repository = InMemoryMusicRepository.seeded();
      await repository.setSongLanguage('song-1', 'ar');
      await repository.setSongLanguage('song-1', null);
      expect(await _languageOf(repository, 'song-1'), isNull);
    });

    test('stores a tag and never a word', () async {
      final repository = InMemoryMusicRepository.seeded();
      await repository.setSongLanguage('song-1', 'Arabic');
      expect(await _languageOf(repository, 'song-1'), isNull);
      await repository.setSongLanguage('song-1', 'zh-hans');
      expect(await _languageOf(repository, 'song-1'), 'zh-Hans');
    });
  });

  group('the sheet', () {
    testWidgets('says what the song is sung in, under its title',
        (tester) async {
      await tester.pumpWidget(_sheet(
        _arabicLines(language: 'ar'),
        language: 'ar',
        onLanguage: (_) async => null,
      ));
      await tester.pumpAndSettle();

      expect(find.text('Sung in Arabic'), findsOneWidget);
      expect(find.byKey(const Key('song_sheet_sung_in')), findsOneWidget);
    });

    testWidgets('asks the question of somebody who can answer it',
        (tester) async {
      await tester.pumpWidget(_sheet(
        _arabicLines(language: null),
        onLanguage: (_) async => null,
      ));
      await tester.pumpAndSettle();
      expect(find.text('Say what it is sung in'), findsOneWidget);
    });

    testWidgets('and asks nobody who cannot', (tester) async {
      await tester.pumpWidget(_sheet(_arabicLines(language: null)));
      await tester.pumpAndSettle();
      // A question nobody can answer is not worth the line it is written on.
      expect(find.text('Say what it is sung in'), findsNothing);
      expect(find.byKey(const Key('song_sheet_sung_in')), findsNothing);
    });
  });

  group('after somebody says what it is sung in', () {
    testWidgets('the sheet offers to listen again, once, and never does it '
        'on its own', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final service = _ListensAgain();
      await tester.pumpWidget(_panel(service));
      await tester.pumpAndSettle();

      // Nothing is offered until somebody answers the question.
      expect(find.byKey(const Key('listen_again_question')), findsNothing);

      await tester.tap(find.byKey(const Key('song_sheet_sung_in')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('song_language_search')),
        'Arabic',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('song_language_ar')));
      await tester.pumpAndSettle();

      expect(service.said, 'ar');
      // The page turns round on the next frame, not on the next correction:
      // the sheet's lines are worked out once and cached, and the answer has
      // to throw that away.
      expect(
        Directionality.of(tester.element(find.text('night'))),
        TextDirection.rtl,
      );
      // Asked, not done: listening again costs money and replaces words
      // somebody may have corrected by hand.
      expect(service.listened, 0);
      final question = tester.widget<Text>(
        find.byKey(const Key('listen_again_question')),
      );
      expect(question.data, contains('Arabic'));

      await tester.tap(find.byKey(const Key('listen_again_yes')));
      await tester.pumpAndSettle();
      expect(service.listened, 1);
      // And the question is over: it belonged to the answer that was just
      // given, not to the page.
      expect(find.byKey(const Key('listen_again_question')), findsNothing);
    });

    testWidgets('and leaving the words alone ends the question', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final service = _ListensAgain();
      await tester.pumpWidget(_panel(service));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('song_sheet_sung_in')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('song_language_ar')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('listen_again_leave')));
      await tester.pumpAndSettle();

      expect(service.listened, 0);
      expect(find.byKey(const Key('listen_again_question')), findsNothing);
    });
  });
}

/// The sheet panel, wired the way SongAnalysisScreen wires it: the song
/// carries the answer, so saying it changes the project the panel is
/// holding.
class _Panel extends StatefulWidget {
  const _Panel({required this.service});

  final _ListensAgain service;

  @override
  State<_Panel> createState() => _PanelState();
}

class _PanelState extends State<_Panel> {
  SongProject _project = _song();
  late SongAnalysisBundle _bundle = widget.service.bundle;

  @override
  Widget build(BuildContext context) {
    return SongSheetPanel(
      project: _project,
      bundle: _bundle,
      onReviewLyrics: null,
      onOpenLive: null,
      analysisService: widget.service,
      onSetLanguage: (language) async {
        widget.service.said = language;
        setState(() => _project = _project.copyWith(language: language));
      },
      onAnalysisChanged: (bundle) => setState(() => _bundle = bundle),
    );
  }
}

Widget _panel(_ListensAgain service) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: _Panel(service: service))),
    );

/// An analysis service that remembers being asked to listen again.
class _ListensAgain extends SongAnalysisService {
  _ListensAgain() : super(client: null);

  SongAnalysisBundle bundle = const SongAnalysisBundle(
    reference: ReferenceTrack(
      projectId: 'song-1',
      fileId: 'file-1',
      storagePath: 'room/song/reference.wav',
      displayName: 'reference.wav',
      state: SongAnalysisState.ready,
      durationMs: 4000,
      transcriptText: 'the night passes over the river',
      transcriptWords: <TranscriptWord>[
        TranscriptWord(word: 'the', startMs: 0, endMs: 900),
        TranscriptWord(word: 'night', startMs: 1000, endMs: 1900),
      ],
    ),
    lyricCues: <LyricSyncCue>[],
    chordCues: <ChordCue>[
      ChordCue(id: 1, startMs: 0, endMs: 1900, chord: 'G', confidence: 0.9),
    ],
  );

  String? said;
  int listened = 0;

  @override
  Future<SongAnalysisBundle> load(String projectId) async => bundle;

  @override
  Future<SongAnalysisBundle> transcribeAgain({
    required SongProject project,
    required SongAnalysisBundle bundle,
  }) async {
    listened += 1;
    return this.bundle;
  }
}

/// One Arabic line of four words, each with a real sung timing, and two
/// chords: one on the first word and one on the last.
List<MusicianSheetLine> _arabicLines({required String? language}) {
  return transcriptSheetLines(
    transcriptWords: const <TranscriptWord>[
      TranscriptWord(word: 'الليل', startMs: 0, endMs: 900),
      TranscriptWord(word: 'يمر', startMs: 1000, endMs: 1900),
      TranscriptWord(word: 'على', startMs: 2000, endMs: 2900),
      TranscriptWord(word: 'النهر', startMs: 3000, endMs: 3900),
    ],
    transcriptText: null,
    chordCues: const <ChordCue>[
      ChordCue(id: 1, startMs: 0, endMs: 2900, chord: 'G', confidence: 0.9),
      ChordCue(id: 2, startMs: 3000, endMs: 3900, chord: 'C', confidence: 0.9),
    ],
    durationMs: 4000,
    language: language,
  );
}

/// One Chinese line of three two-character words, and two chords: one at the
/// top of the line and one on the fifth character.
List<MusicianSheetLine> _chineseLines({required String? language}) {
  return transcriptSheetLines(
    transcriptWords: const <TranscriptWord>[
      TranscriptWord(word: '月光', startMs: 0, endMs: 1000),
      TranscriptWord(word: '落在', startMs: 1000, endMs: 2000),
      TranscriptWord(word: '窗前', startMs: 2000, endMs: 3000),
    ],
    transcriptText: null,
    chordCues: const <ChordCue>[
      ChordCue(id: 1, startMs: 0, endMs: 1900, chord: 'G', confidence: 0.9),
      ChordCue(id: 2, startMs: 2000, endMs: 3000, chord: 'C', confidence: 0.9),
    ],
    durationMs: 3000,
    language: language,
  );
}

SongProject _song({String? language}) {
  final now = DateTime(2026, 9, 18);
  return SongProject(
    id: 'song-1',
    roomId: 'room-1',
    accountId: 'account-1',
    title: 'A Song',
    createdAt: now,
    updatedAt: now,
    language: language,
  );
}

Widget _sheet(
  List<MusicianSheetLine> lines, {
  String? language,
  Future<String?> Function(String?)? onLanguage,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: MusicianSongSheet(
          title: 'A Song',
          lines: lines,
          musicalKey: 'G major',
          transpose: 0,
          fontScale: 1,
          showChords: true,
          language: language,
          onLanguage: onLanguage,
        ),
      ),
    ),
  );
}

Future<String?> _languageOf(
  InMemoryMusicRepository repository,
  String projectId,
) async {
  final rooms = await repository.loadRooms();
  for (final room in rooms) {
    for (final project in room.projects) {
      if (project.id == projectId) return project.language;
    }
  }
  return null;
}
