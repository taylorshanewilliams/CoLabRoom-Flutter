import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/chord_sheet_export.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:colabroom/features/workspace/song_sheet_panel.dart';
import 'package:colabroom/services/project_export_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A chart you can hand somebody.
///
/// Every Musician, Same Song, 17 September 2026: the app draws the chords
/// over the words and then could not get that page off the phone. Print was
/// the lyrics on their own — the half a player does not need — and there was
/// no way at all to give the song to a worship team running Planning Center
/// or OnSong, both of which read ChordPro.
///
/// Three things have to hold. A chord lands over the word it changes on, and
/// stays there once it is text. The ChordPro carries the title, the key, the
/// tempo and the sections, in the key the person is actually reading in. And
/// a song the room did not write hands out its chords without its words, in
/// both formats, exactly as the lyric export already does.

final DateTime _when = DateTime(2026, 9, 17);

SongProject _song({SongOrigin? origin, String title = 'Midnight Signal'}) =>
    SongProject(
      id: 'song-1',
      roomId: 'room-1',
      accountId: 'account-1',
      title: title,
      createdAt: _when,
      updatedAt: _when,
      songOrigin: origin,
    );

ChordCue _cue(String chord, int startMs) => ChordCue(
      startMs: startMs,
      endMs: startMs + 1600,
      chord: chord,
      confidence: 0.9,
    );

/// A line whose words have real timestamps, which is what puts a chord over
/// a particular word rather than over a proportional guess.
MusicianSheetLine _sung(
  String body, {
  required int startMs,
  required List<ChordCue> chords,
  int msPerWord = 600,
}) {
  final words =
      body.split(' ').where((word) => word.isNotEmpty).toList(growable: false);
  return MusicianSheetLine(
    contributionId: null,
    body: words.join(' '),
    section: false,
    startMs: startMs,
    endMs: startMs + words.length * msPerWord,
    chords: chords,
    approximateTiming: false,
    wordStartsMs: <int>[
      for (var index = 0; index < words.length; index += 1)
        startMs + index * msPerWord,
    ],
  );
}

MusicianSheetLine _sectionLine(String label, int startMs) => MusicianSheetLine(
      contributionId: null,
      body: label,
      section: true,
      startMs: startMs,
      endMs: startMs,
      chords: const <ChordCue>[],
      approximateTiming: false,
    );

/// Verse, then chorus, six words each, a chord every other word.
List<MusicianSheetLine> _twoSections() => <MusicianSheetLine>[
      _sectionLine('Verse', 0),
      _sung(
        'Streetlights blur like a warning sign',
        startMs: 0,
        chords: <ChordCue>[_cue('G:maj', 0), _cue('C:maj', 1200)],
      ),
      _sectionLine('Chorus', 3600),
      _sung(
        'Hold on the night is long',
        startMs: 3600,
        chords: <ChordCue>[_cue('D:maj', 3600), _cue('E:min', 4800)],
      ),
    ];

void main() {
  group('a chord sits over the word it changes on', () {
    test('the chord row lines up with the word row, column for column', () {
      final line = ChordSheetExport.textLine(
        _sung(
          'Streetlights blur like a warning sign',
          startMs: 0,
          chords: <ChordCue>[_cue('G:maj', 0), _cue('C:maj', 1200)],
        ),
        transpose: 0,
      );

      expect(line.words, 'Streetlights blur like a warning sign');
      // Third word, third column position — counted rather than eyeballed,
      // because "looks about right" is exactly the bug this shape exists to
      // make impossible.
      expect(line.chords.indexOf('G'), 0);
      expect(
        line.chords.indexOf('C'),
        line.words.indexOf('like'),
      );
    });

    test('two chords never touch, and the word moves rather than the chord',
        () {
      // A long chord name over a short word: "Cmaj7" is five characters and
      // "a" is one, so the next chord has nowhere to go unless the words
      // give way. They do — two chords run together read as a third chord
      // that is neither of them.
      final line = ChordSheetExport.textLine(
        _sung(
          'a b c d',
          startMs: 0,
          chords: <ChordCue>[_cue('C:maj7', 0), _cue('G:maj', 600)],
        ),
        transpose: 0,
      );

      expect(line.chords, 'Cmaj7 G');
      expect(line.words, 'a     b c d');
      expect(line.chords.indexOf('G'), line.words.indexOf('b'));
    });

    test('the reader\'s own key is what comes out', () {
      final line = ChordSheetExport.textLine(
        _sung(
          'one two',
          startMs: 0,
          chords: <ChordCue>[_cue('G:maj', 0), _cue('A:min', 600)],
        ),
        transpose: 3,
        musicalKey: 'G',
      );

      // Up three from G is Bb, a flat key, so its sixth is written Gm and
      // not F#m. The sheet on screen says the same, through the same call.
      expect(line.chords.trim().split(RegExp(r'\s+')), <String>['Bb', 'Cm']);
    });

    test('a diminished chord survives becoming text', () {
      // chordDisplay writes this one with ° and ♭, which no built-in PDF
      // font draws and no ChordPro reader parses.
      expect(ChordSheetExport.plainChordName('C°'), 'Cdim');
      expect(ChordSheetExport.plainChordName('Am7♭5'), 'Am7b5');
      expect(ChordSheetExport.plainChordName('F♯m'), 'F#m');
    });
  });

  group('a line too wide for the page breaks without losing its place', () {
    test('both rows break at the same column and keep their alignment', () {
      final line = ChordSheetExport.textLine(
        _sung(
          'one two three four five six seven eight',
          startMs: 0,
          chords: <ChordCue>[_cue('G:maj', 0), _cue('C:maj', 3000)],
        ),
        transpose: 0,
      );
      final pieces = ChordSheetExport.wrap(line, columns: 20);

      expect(pieces.length, greaterThan(1));
      for (final piece in pieces) {
        expect(piece.words.length, lessThanOrEqualTo(20));
        expect(piece.chords.length, lessThanOrEqualTo(20));
      }
      // Nothing is dropped and no word is cut in half.
      expect(
        pieces.map((piece) => piece.words).join(' ').split(RegExp(r'\s+')),
        <String>['one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight'],
      );
      // The chord still names the word it named before the break.
      final withC = pieces.firstWhere((piece) => piece.chords.contains('C'));
      expect(withC.chords.indexOf('C'), withC.words.indexOf('six'));
    });

    test('a line that fits comes back as one line', () {
      const line = ChartTextLine(chords: 'G   C', words: 'one two');
      expect(ChordSheetExport.wrap(line, columns: 40).single.words, 'one two');
    });
  });

  group('the song as ChordPro', () {
    test('a known song comes out exactly like this', () {
      final text = ChordSheetExport.chordPro(
        project: _song(origin: SongOrigin.ours),
        lines: _twoSections(),
        transpose: 0,
        musicalKey: 'G',
        bpm: 96.4,
      );

      expect(text, '''
{title: Midnight Signal}
{key: G}
{tempo: 96}

{comment: Verse}
[G]Streetlights blur [C]like a warning sign

{start_of_chorus}
[D]Hold on [Em]the night is long
{end_of_chorus}
''');
    });

    test('an unanalyzed song still exports, without inventing a key', () {
      final text = ChordSheetExport.chordPro(
        project: _song(),
        lines: <MusicianSheetLine>[
          _sung('just the words', startMs: 0, chords: const <ChordCue>[]),
        ],
        transpose: 0,
      );

      expect(text, isNot(contains('{key:')));
      expect(text, isNot(contains('{tempo:')));
      expect(text, contains('just the words'));
    });

    test('the key follows the transpose, like everything else on the page',
        () {
      final text = ChordSheetExport.chordPro(
        project: _song(),
        lines: _twoSections(),
        transpose: 2,
        musicalKey: 'G',
      );

      expect(text, contains('{key: A}'));
      expect(text, contains('[A]Streetlights'));
    });

    test('a brace in a title cannot end the directive early', () {
      final text = ChordSheetExport.chordPro(
        project: _song(title: 'Song {one}'),
        lines: const <MusicianSheetLine>[],
        transpose: 0,
      );
      expect(text, startsWith('{title: Song (one)}'));
    });
  });

  group('somebody else\'s song hands out its chords and not its words', () {
    test('the ChordPro carries the chords alone, and says why', () {
      final text = ChordSheetExport.chordPro(
        project: _song(origin: SongOrigin.cover),
        lines: _twoSections(),
        transpose: 0,
        musicalKey: 'G',
      );

      expect(text, contains('{comment: ${ProjectExportService.wordsStayHome}}'));
      expect(text, contains('[G] [C]'));
      expect(text, contains('{start_of_chorus}'));
      expect(text, isNot(contains('Streetlights')));
      // Not one word of either line, only the shape they sat in.
      for (final word in <String>['blur', 'warning', 'Hold', 'long']) {
        expect(text, isNot(contains(word)));
      }
    });

    test('the chart carries the chords alone too', () {
      final line = ChordSheetExport.textLine(
        _sung(
          'Streetlights blur like a warning sign',
          startMs: 0,
          chords: <ChordCue>[_cue('G:maj', 0), _cue('C:maj', 1200)],
        ),
        transpose: 0,
        wordsTravel: false,
      );

      expect(line.words, isEmpty);
      expect(line.chords, 'G  C');
    });

    test('our own song and an unanswered one both keep their words', () {
      for (final origin in <SongOrigin?>[null, SongOrigin.ours]) {
        expect(ProjectExportService.wordsTravel(_song(origin: origin)), isTrue);
        final text = ChordSheetExport.chordPro(
          project: _song(origin: origin),
          lines: _twoSections(),
          transpose: 0,
        );
        expect(text, contains('Streetlights'));
        expect(text, isNot(contains(ProjectExportService.wordsStayHome)));
      }
    });
  });

  group('the section names come from the recording', () {
    test('a heading is written above the line it governs', () {
      final lines = ChordSheetExport.withSectionNames(
        <MusicianSheetLine>[
          _sung('first line here', startMs: 0, chords: const <ChordCue>[]),
          _sung('second line here', startMs: 8000, chords: const <ChordCue>[]),
        ],
        const <StructureSection>[
          StructureSection(startMs: 0, endMs: 8000, label: 'Verse'),
          // Starting a beat after the singer comes in, which is where a
          // chorus usually starts from.
          StructureSection(startMs: 8400, endMs: 16000, label: 'Chorus'),
        ],
      );

      expect(
        lines.map((line) => line.section ? '[${line.body}]' : line.body),
        <String>['[Verse]', 'first line here', '[Chorus]', 'second line here'],
      );
    });

    test('lines that already carry their own sections are left alone', () {
      final typed = _twoSections();
      expect(
        ChordSheetExport.withSectionNames(
          typed,
          const <StructureSection>[
            StructureSection(startMs: 0, endMs: 900, label: 'Intro'),
          ],
        ),
        same(typed),
      );
    });

    test('a heading with nothing under it is not written', () {
      final lines = ChordSheetExport.withSectionNames(
        <MusicianSheetLine>[
          _sung('the only line', startMs: 9000, chords: const <ChordCue>[]),
        ],
        const <StructureSection>[
          StructureSection(startMs: 0, endMs: 4000, label: 'Intro'),
          StructureSection(startMs: 4000, endMs: 12000, label: 'Verse'),
        ],
      );

      // "Intro" and "Verse" back to back name a part the page does not show.
      expect(lines.where((line) => line.section).map((line) => line.body),
          <String>['Verse']);
    });
  });

  group('the chart as a PDF', () {
    test('it builds, on one page, with the words and the chords in it',
        () async {
      final document = ChordSheetExport.chartDocument(
        project: _song(origin: SongOrigin.ours),
        lines: _twoSections(),
        transpose: 0,
        musicalKey: 'G',
        bpm: 96,
      );

      final bytes = await document.save();
      expect(bytes, isNotEmpty);
      expect(document.document.pdfPageList.pages.length, 1);
    });

    test('a long song runs onto a second page', () async {
      final document = ChordSheetExport.chartDocument(
        project: _song(),
        lines: <MusicianSheetLine>[
          for (var index = 0; index < 120; index += 1)
            _sung(
              'a line of words number $index',
              startMs: index * 4000,
              chords: <ChordCue>[_cue('G:maj', index * 4000)],
            ),
        ],
        transpose: 0,
      );

      await document.save();
      expect(document.document.pdfPageList.pages.length, greaterThan(1));
    });

    test('the page is as many Courier columns wide as the arithmetic says',
        () {
      // 8.5 inches at 72 points, less two 46-point margins, over Courier's
      // fixed 0.6-of-the-point-size advance at 10 point.
      expect(ChordSheetExport.chartColumns, ((612 - 92) / 6).floor());
    });
  });

  group('a curly apostrophe does not stop the print', () {
    test('the fonts every reader has are Latin-1, so the text is folded', () {
      expect(
        ProjectExportService.printable('don’t — “stop”…'),
        'don\'t - "stop"...',
      );
      // Beyond the fold it is a question mark on the page rather than an
      // export that throws.
      expect(ProjectExportService.printable('你好'), '??');
      // Latin-1 itself is left alone, accents and all.
      expect(ProjectExportService.printable('café · señor'),
          'café · señor');
    });

    test('the chart prints a song full of smart quotes', () async {
      final document = ChordSheetExport.chartDocument(
        project: _song(origin: SongOrigin.cover),
        lines: <MusicianSheetLine>[
          _sung(
            'don’t “stop” now…',
            startMs: 0,
            chords: <ChordCue>[_cue('G:maj', 0)],
          ),
        ],
        transpose: 0,
        musicalKey: 'G',
      );
      // The cover sentence has an em dash in it, so this used to be two
      // different ways of throwing on one page.
      expect(await document.save(), isNotEmpty);
    });

    test('the folded word keeps its width, so the chord stays over it', () {
      final line = ChordSheetExport.textLine(
        _sung(
          'yes… no',
          startMs: 0,
          chords: <ChordCue>[_cue('G:maj', 0), _cue('C:maj', 600)],
        ),
        transpose: 0,
      );
      // "yes…" is four characters and "yes..." is six. Folding before the
      // columns are counted is what keeps C over "no".
      expect(line.words, 'yes... no');
      expect(line.chords.indexOf('C'), line.words.indexOf('no'));
    });

    test('the sentence a cover prints instead of its words is printable', () {
      // It has an em dash in it, which Latin-1 has no room for — so the
      // lyric print, which has written this since the cover gate landed,
      // threw rather than printing.
      expect(ProjectExportService.wordsStayHome, contains('—'));
      expect(
        ProjectExportService.printable(ProjectExportService.wordsStayHome),
        isNot(contains('—')),
      );
    });
  });

  group('both ways out are on the page', () {
    testWidgets('the sheet offers the chart and the ChordPro file',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      // 520, like the other test that pumps this panel. Its toolbar row of
      // segments and icon buttons already overflows a 390-wide phone on
      // origin/main, above anything this slice added.
      tester.view.physicalSize = const Size(520, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_panel(_readableSong()));
      await tester.pump();

      // Spelled out on the page rather than behind an icon: handing a chart
      // to a player who does not use this app is not something anybody goes
      // hunting through a menu for.
      expect(find.byKey(const Key('print_chord_chart')), findsOneWidget);
      expect(find.byKey(const Key('send_as_chordpro')), findsOneWidget);
      expect(find.text('Send as ChordPro'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a song with nothing on its sheet offers neither',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      // 520, like the other test that pumps this panel. Its toolbar row of
      // segments and icon buttons already overflows a 390-wide phone on
      // origin/main, above anything this slice added.
      tester.view.physicalSize = const Size(520, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_panel(const SongAnalysisBundle(
        reference: null,
        lyricCues: <LyricSyncCue>[],
        chordCues: <ChordCue>[],
      )));
      await tester.pump();

      // A button that prints an empty page is a button that reads as broken.
      expect(find.byKey(const Key('print_chord_chart')), findsNothing);
      expect(find.byKey(const Key('send_as_chordpro')), findsNothing);
    });
  });
}

Widget _panel(SongAnalysisBundle bundle) => MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SongSheetPanel(
            project: _song(origin: SongOrigin.ours),
            bundle: bundle,
            onReviewLyrics: null,
            onOpenLive: null,
          ),
        ),
      ),
    );

/// A recording with words and chords in it, which is what the Song Sheet
/// builds its lines from.
SongAnalysisBundle _readableSong() => const SongAnalysisBundle(
      reference: ReferenceTrack(
        projectId: 'song-1',
        fileId: 'file-1',
        storagePath: 'room/song/reference.wav',
        displayName: 'reference.wav',
        state: SongAnalysisState.ready,
        durationMs: 12000,
        musicalKey: 'G',
        bpm: 96,
        transcriptWords: <TranscriptWord>[
          TranscriptWord(word: 'Streetlights', startMs: 0, endMs: 600),
          TranscriptWord(word: 'blur', startMs: 600, endMs: 1200),
        ],
      ),
      lyricCues: <LyricSyncCue>[],
      chordCues: <ChordCue>[
        ChordCue(startMs: 0, endMs: 1600, chord: 'G:maj', confidence: 0.9),
      ],
    );

