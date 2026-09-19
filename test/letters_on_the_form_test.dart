import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/chord_chart_view.dart';
import 'package:colabroom/features/workspace/chord_sheet_export.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:colabroom/services/chord_chart.dart';
import 'package:colabroom/services/follow_me.dart';
import 'package:colabroom/services/rehearsal_letters.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Letters on the form, and a short code for the whole song.
///
/// Every Musician, Same Song, 17 September 2026: a band at rehearsal says
/// "from B", and a chart says "I A A B A C B B O". Neither is a thing this
/// app could say, although the analysis has known the shape of every song
/// since sections were found. The letters are derived from that shape and
/// never stored, so a rename cannot renumber the form and a re-analysis
/// re-derives it.
void main() {
  final day = DateTime(2026, 9, 18);

  /// Twelve bars of half a second each: 0, 500, 1000 ... 5500.
  const downbeats = <int>[
    0, 500, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 4500, 5000, 5500,
  ];

  /// A song with a shape a band would recognise: an intro, two verses with a
  /// chorus between them, and a tag on the end.
  const sections = <StructureSection>[
    StructureSection(startMs: 0, endMs: 1000, label: 'Intro', groupIndex: 0),
    StructureSection(startMs: 1000, endMs: 2500, label: 'Verse', groupIndex: 1),
    StructureSection(startMs: 2500, endMs: 4000, label: 'Chorus', groupIndex: 2),
    StructureSection(startMs: 4000, endMs: 5000, label: 'Verse', groupIndex: 1),
    StructureSection(startMs: 5000, endMs: 6000, label: 'Outro', groupIndex: 3),
  ];

  group('a letter for every part', () {
    test('repeats share a letter, and the intro and the outro are named', () {
      final letters = rehearsalLetters(sections);
      expect(letters.map((letter) => letter.letter), <String>['I', 'A', 'B', 'A', 'O']);
      expect(arrangementCode(letters), 'I A B A O');
      // The letter belongs to the part, so it carries the part's name and
      // where it runs — which is what a tap on one has to know.
      expect(letters[2].label, 'Chorus');
      expect(letters[2].startMs, 2500);
      expect(letters[2].endMs, 4000);
    });

    test('a rename changes the name beside the letter and not the letter', () {
      final renamed = <StructureSection>[
        for (final section in sections)
          section.label == 'Chorus'
              ? section.copyWith(customLabel: 'the big one')
              : section,
      ];
      final letters = rehearsalLetters(renamed);
      expect(arrangementCode(letters), 'I A B A O',
          reason: 'calling the chorus something else does not make it C');
      expect(letters[2].label, 'the big one');
    });

    test('the letters come back in order however the sections arrive', () {
      final shuffled = <StructureSection>[
        sections[3],
        sections[0],
        sections[4],
        sections[2],
        sections[1],
      ];
      expect(arrangementCode(rehearsalLetters(shuffled)), 'I A B A O');
    });

    test('an analysis that already letters its parts keeps those letters', () {
      // The chroma path names parts "A", "B", "C" rather than "Verse" and
      // "Chorus"; derived letters have to agree with the names already on
      // the timeline rather than fight them.
      const lettered = <StructureSection>[
        StructureSection(startMs: 0, endMs: 1000, label: 'A'),
        StructureSection(startMs: 1000, endMs: 2000, label: 'B'),
        StructureSection(startMs: 2000, endMs: 3000, label: 'A'),
      ];
      expect(arrangementCode(rehearsalLetters(lettered)), 'A B A');
    });

    test('I and O are left to the intro and the outro', () {
      final many = <StructureSection>[
        for (var index = 0; index < 10; index += 1)
          StructureSection(
            startMs: index * 1000,
            endMs: index * 1000 + 1000,
            label: 'Part $index',
          ),
      ];
      final letters = rehearsalLetters(many).map((letter) => letter.letter);
      expect(letters, <String>['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'J', 'K']);
    });

    test('a song with no sections has no letters and no code', () {
      expect(rehearsalLetters(const <StructureSection>[]), isEmpty);
      expect(arrangementCode(rehearsalLetters(const <StructureSection>[])), '');
    });
  });

  group('where a jump lands', () {
    test('on the downbeat the part begins on', () {
      expect(sectionDownbeatMs(2500, downbeats), 2500);
      // A boundary that drifted a little goes back to the downbeat rather
      // than dropping the player inside the bar before it.
      expect(sectionDownbeatMs(2520, downbeats), 2500);
    });

    test('without a beat grid, the part\'s own start stands', () {
      expect(sectionDownbeatMs(2500, const <int>[]), 2500);
    });

    test('a part that begins before the first downbeat is still jumped to', () {
      // Bar 1 moves the numbers in the margin and not one millisecond of the
      // recording (0161), so the pickup is a place you can go.
      expect(sectionDownbeatMs(200, const <int>[400, 900]), 200);
    });
  });

  group('the letters on the chart', () {
    List<ChartRow> rows() => buildChartRows(
          buildChartBars(
            cues: <ChordCue>[
              for (var index = 0; index < 12; index += 1)
                ChordCue(
                  startMs: index * 500,
                  endMs: index * 500 + 500,
                  chord: index.isEven ? 'G:maj' : 'C:maj',
                  confidence: 0.9,
                ),
            ],
            beatsMs: <int>[
              for (var index = 0; index < 48; index += 1) index * 125,
            ],
            downbeatsMs: downbeats,
            sections: sections,
          ),
        );

    test('every section row carries its letter beside its name', () {
      final named = <String>[
        for (final row in rows())
          if (row.sectionLabel != null) '${row.sectionLetter} ${row.sectionLabel}',
      ];
      expect(named, <String>['I Intro', 'A Verse', 'B Chorus', 'A Verse', 'O Outro']);
    });

    testWidgets('the code is written at the top of the chart', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ChordChartView(
              rows: rows(),
              transpose: 0,
              fontScale: 1,
              arrangement: arrangementCode(rehearsalLetters(sections)),
            ),
          ),
        ),
      ));
      await tester.pump();

      expect(
        tester.widget<Text>(find.byKey(const Key('chart_arrangement'))).data,
        'I A B A O',
      );
      expect(find.text('B  CHORUS'), findsOneWidget);
    });

    testWidgets('a song with no sections shows nothing', (tester) async {
      final bare = buildChartRows(buildChartBars(
        cues: <ChordCue>[
          ChordCue(startMs: 0, endMs: 500, chord: 'G:maj', confidence: 0.9),
        ],
        beatsMs: const <int>[0, 125, 250, 375],
        downbeatsMs: downbeats,
      ));
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ChordChartView(
              rows: bare,
              transpose: 0,
              fontScale: 1,
              arrangement: arrangementCode(
                rehearsalLetters(const <StructureSection>[]),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();

      expect(find.byKey(const Key('chart_arrangement')), findsNothing);
      expect(bare.every((row) => row.sectionLetter == null), isTrue);
    });
  });

  group('the letters on the printed page', () {
    MusicianSheetLine sung(String body, {required int startMs}) =>
        MusicianSheetLine(
          contributionId: null,
          body: body,
          section: false,
          startMs: startMs,
          endMs: startMs + 900,
          chords: const <ChordCue>[],
          approximateTiming: false,
        );

    SongProject song() => SongProject(
          id: 'song-letters',
          roomId: 'room',
          accountId: 'account',
          title: 'Weathervane',
          createdAt: day,
          updatedAt: day,
        );

    test('a folded-in heading carries the letter of its part', () {
      final lines = ChordSheetExport.withSectionNames(
        <MusicianSheetLine>[
          sung('turning in the wind', startMs: 1000),
          sung('again and again', startMs: 2500),
          sung('a second verse now', startMs: 4000),
        ],
        sections,
      );
      expect(
        <String>[
          for (final line in lines)
            if (line.section) '${line.letter} ${line.body}',
        ],
        <String>['A Verse', 'B Chorus', 'A Verse'],
      );
      // And the heading a printed page writes puts the letter first.
      expect(
        ChordSheetExport.textLine(
          lines.firstWhere((line) => line.section),
          transpose: 0,
        ).heading,
        'A  VERSE',
      );
    });

    test('a heading with no letter prints exactly as it always did', () {
      expect(
        ChordSheetExport.textLine(
          MusicianSheetLine(
            contributionId: 'c1',
            body: 'Kate\'s bit',
            section: true,
            startMs: 0,
            endMs: 0,
            chords: const <ChordCue>[],
            approximateTiming: false,
          ),
          transpose: 0,
        ).heading,
        'KATE\'S BIT',
      );
    });

    test('the chart prints the code under the title, and the letters', () async {
      final document = ChordSheetExport.chartDocument(
        project: song(),
        lines: ChordSheetExport.withSectionNames(
          <MusicianSheetLine>[
            sung('turning in the wind', startMs: 1000),
            sung('again and again', startMs: 2500),
          ],
          sections,
        ),
        transpose: 0,
        musicalKey: 'G',
        bpm: 96,
        arrangement: arrangementCode(rehearsalLetters(sections)),
      );

      final printed = _pdfWords(await document.save());
      // The title, the facts, then the shape of the song, then the chart.
      expect(printed, startsWith('Weathervane Key of G · 96 bpm I A B A O'));
      expect(printed, contains('A VERSE'));
      expect(printed, contains('B CHORUS'));
    });

    test('a song with no sections prints no code at all', () async {
      final document = ChordSheetExport.chartDocument(
        project: song(),
        lines: <MusicianSheetLine>[sung('turning in the wind', startMs: 1000)],
        transpose: 0,
        musicalKey: 'G',
        arrangement: arrangementCode(rehearsalLetters(const <StructureSection>[])),
      );

      expect(_pdfWords(await document.save()), 'Weathervane Key of G turning in the wind');
    });
  });

  group('on the screen', () {
    final project = SongProject(
      id: 'song-letters',
      roomId: 'room',
      accountId: 'account',
      title: 'Weathervane',
      createdAt: day,
      updatedAt: day,
      contributions: <Contribution>[
        Contribution(
          id: 'line-1',
          projectId: 'song-letters',
          authorId: 'u2',
          authorName: 'Jess',
          body: 'Turning in the wind',
          colorValue: 0xFFFF8A4C,
          createdAt: day,
          position: 1,
        ),
      ],
    );
    const bundle = SongAnalysisBundle(
      reference: ReferenceTrack(
        projectId: 'song-letters',
        fileId: 'file',
        storagePath: 'room/song-letters/reference.m4a',
        displayName: 'Weathervane.m4a',
        state: SongAnalysisState.ready,
        durationMs: 6000,
        downbeatsMs: downbeats,
        transcriptText: 'turning in the wind',
        transcriptWords: <TranscriptWord>[
          TranscriptWord(word: 'turning', startMs: 0, endMs: 800),
          TranscriptWord(word: 'in', startMs: 800, endMs: 1100),
          TranscriptWord(word: 'the', startMs: 1100, endMs: 1400),
          TranscriptWord(word: 'wind', startMs: 1400, endMs: 2200),
        ],
        structureSections: sections,
      ),
      lyricCues: <LyricSyncCue>[],
      chordCues: <ChordCue>[],
    );

    Future<void> sized(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    testWidgets('a tap on a letter lands on that part\'s first downbeat',
        (tester) async {
      await sized(tester);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(project: project, analysis: bundle),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byKey(const Key('live_letters')), findsOneWidget);
      expect(find.text('I'), findsOneWidget);
      expect(find.text('O'), findsOneWidget);

      // The second verse: it starts at 4000 of a 6000ms recording, on the
      // ninth downbeat.
      await tester.tap(find.byKey(const Key('live_letter_3')));
      await tester.pump();
      expect(
        tester.widget<Slider>(find.byKey(const Key('live_seek'))).value,
        closeTo(0.667, 0.01),
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('jumping ends a loop', (tester) async {
      await sized(tester);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(project: project, analysis: bundle),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      // The practice row scrolls, so the part chips are reached the way a
      // thumb reaches them.
      final loopChip = find.byKey(const Key('live_loop_0'));
      await tester.scrollUntilVisible(
        loopChip,
        80,
        scrollable: find.descendant(
          of: find.byKey(const Key('live_practice_row')),
          matching: find.byType(Scrollable),
        ),
      );
      bool looping() => tester
          .widget<ChoiceChip>(
              find.descendant(of: loopChip, matching: find.byType(ChoiceChip)))
          .selected;

      // The intro on repeat, then "from A": the song runs on into the verse
      // rather than being pulled back into the intro.
      await tester.tap(loopChip);
      await tester.pump();
      expect(looping(), isTrue);

      await tester.tap(find.byKey(const Key('live_letter_1')));
      await tester.pump();
      expect(looping(), isFalse);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a song with no sections has no row of letters', (tester) async {
      await sized(tester);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project,
          analysis: const SongAnalysisBundle(
            reference: ReferenceTrack(
              projectId: 'song-letters',
              fileId: 'file',
              storagePath: 'room/song-letters/reference.m4a',
              displayName: 'Weathervane.m4a',
              state: SongAnalysisState.ready,
              durationMs: 6000,
              downbeatsMs: downbeats,
              transcriptText: 'turning in the wind',
              transcriptWords: <TranscriptWord>[
                TranscriptWord(word: 'turning', startMs: 0, endMs: 800),
                TranscriptWord(word: 'wind', startMs: 1400, endMs: 2200),
              ],
            ),
            lyricCues: <LyricSyncCue>[],
            chordCues: <ChordCue>[],
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byKey(const Key('live_letters')), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('a jump by letter travels', () {
    test('it is a seek with the repeat taken off, which Follow me carries', () {
      // Nothing new goes on the wire. The leader's screen moves the song and
      // clears the loop; both are already in every heartbeat, so the jump
      // reaches the room the way a section jump always has.
      const before = FollowState(
        sheet: true,
        synced: true,
        playing: true,
        positionMs: 2600,
        rate: 1,
        sentAt: 1000000,
        loopStartMs: 2500,
        loopEndMs: 4000,
      );
      final after = FollowState(
        sheet: true,
        synced: true,
        playing: true,
        positionMs: sectionDownbeatMs(4000, downbeats),
        rate: 1,
        sentAt: 1000100,
      );
      expect(before.sameDecisions(after), isFalse);
      expect(worthSending(before, after), isTrue);

      final heard = FollowState.fromJson(after.toJson())!;
      expect(heard.looping, isFalse);
      expect(heard.positionMs, 4000);
      expect(followTargetMs(heard, heard.sentAt + 500), 4500);
    });
  });
}

/// The words a PDF actually puts on the page, in order.
///
/// The `pdf` package writes each run of text as its own show operator inside
/// a deflated content stream, so the only way to read a printed page back is
/// to inflate the streams and collect the runs. Joined with single spaces:
/// where a word sits on the page is the layout's business, and this is about
/// what it says.
String _pdfWords(Uint8List bytes) {
  final raw = latin1.decode(bytes, allowInvalid: true);
  final text = StringBuffer();
  var at = 0;
  while (true) {
    final start = raw.indexOf('stream', at);
    if (start < 0) break;
    var from = start + 'stream'.length;
    if (from < raw.length && raw[from] == '\r') from += 1;
    if (from < raw.length && raw[from] == '\n') from += 1;
    final end = raw.indexOf('endstream', from);
    if (end < 0) break;
    at = end + 'endstream'.length;
    List<int> inflated;
    try {
      inflated = ZLibCodec().decode(bytes.sublist(from, end));
    } on FormatException {
      continue;
    }
    text.write(latin1.decode(inflated, allowInvalid: true));
  }
  return RegExp(r'\[\(([^)]*)\)\]TJ')
      .allMatches(text.toString())
      .map((match) => match.group(1)!)
      .where((word) => word.trim().isNotEmpty)
      .join(' ');
}
