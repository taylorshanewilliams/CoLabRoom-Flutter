import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/practice_mark.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/features/workspace/practice_rules.dart';
import 'package:colabroom/features/workspace/song_reading_store.dart';
import 'package:colabroom/features/workspace/song_sheet_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A loop of two chords.
///
/// Every Musician, Same Song, 17 September 2026. What stops a beginner is
/// almost never a whole part: it is one change their hand cannot get across
/// in time. Holding that chord down puts the bar it lands in and the bar
/// before it on repeat at 60% — the bar loops from #362 and one of their
/// seven speeds, asked for without counting a single bar.
void main() {
  /// Twelve bars of half a second each: bar 1 starts at 0, bar 6 at 2500.
  const downbeats = <int>[
    0, 500, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 4500, 5000, 5500,
  ];

  group('the bars a change asks for', () {
    test('the bar it lands in, and the bar before it', () {
      // A change part-way through bar 6 drills bars 5 and 6: arriving at the
      // new chord is the thing that goes wrong, and it cannot be practised
      // from a standing start inside its own bar.
      final loop = changeLoop(
        changeMs: 2600,
        downbeatsMs: downbeats,
        songEndMs: 6000,
      )!;
      expect(loop.label, 'Bars 5–6');
      expect(loop.startMs, 2000);
      expect(loop.endMs, 3000);
      expect(loop.firstBar, 5);
      expect(loop.lastBar, 6);
    });

    test('a change on the downbeat belongs to the bar it starts', () {
      final loop = changeLoop(changeMs: 4000, downbeatsMs: downbeats)!;
      expect(loop.label, 'Bars 8–9');
      expect(loop.startMs, 3500);
    });

    test('a change in bar 1 has nothing in front of it', () {
      final loop = changeLoop(changeMs: 200, downbeatsMs: downbeats)!;
      expect(loop.label, 'Bar 1');
      expect(loop.startMs, 0);
      expect(loop.endMs, 500);
    });

    test('the last bar of the song ends where the recording does', () {
      final loop =
          changeLoop(changeMs: 5600, downbeatsMs: downbeats, songEndMs: 6200)!;
      expect(loop.label, 'Bars 11–12');
      expect(loop.endMs, 6200);
    });

    test('a change in the pickup, or no grid at all, is not two bars', () {
      // The band has said bar 1 is the third downbeat, so a change before it
      // is in the pickup — which has no bar numbers and is asked for by name.
      expect(changeLoop(changeMs: 200, downbeatsMs: downbeats, barOne: 3),
          isNull);
      expect(changeLoop(changeMs: 2600, downbeatsMs: const <int>[]), isNull);
    });

    test('bar 1 moving moves the bars a change asks for', () {
      final loop =
          changeLoop(changeMs: 2600, downbeatsMs: downbeats, barOne: 3)!;
      expect(loop.label, 'Bars 3–4');
      expect(loop.startMs, 2000, reason: 'the times do not move, the names do');
    });

    test('the speed is 60%, and it is one of the seven', () {
      expect(changeLoopRate, 0.6);
      expect(practiceRates, contains(changeLoopRate));
      expect(rateLabel(changeLoopRate), '60%');
      // So the arrows either side of it step from it like anywhere else.
      expect(rateStep(changeLoopRate, faster: true), 0.7);
      expect(rateStep(changeLoopRate, faster: false), 0.5);
    });
  });

  testWidgets('a chord held down in Perform puts its change on repeat',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: LivePerformanceScreen(
        project: _project('song-change'),
        analysis: _analysis('song-change'),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();

    // Nothing is on repeat and the song is at full speed.
    expect(find.text('1×'), findsOneWidget);

    await tester.longPress(find.byKey(const Key('edit_chord_2')));
    await tester.pumpAndSettle();
    // It says what it will do before it does it.
    expect(find.text('Loop this change'), findsOneWidget);
    expect(find.text('Bars 5–6 at 60%'), findsOneWidget);

    await tester.tap(find.byKey(const Key('loop_this_change')));
    await tester.pumpAndSettle();
    expect(find.text('Bars 5–6'), findsOneWidget);
    expect(find.text('60%'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('on the sheet it opens the song where it can be played',
      (tester) async {
    SimplerShapesStore.resetForTesting();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(520, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final asked = <PracticePart>[];
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SongSheetPanel(
            project: _project('song-change-sheet'),
            bundle: _analysis('song-change-sheet'),
            onReviewLyrics: null,
            onOpenLive: null,
            onPractise: asked.add,
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    await tester.longPress(find.byKey(const Key('edit_chord_2')));
    await tester.pumpAndSettle();
    expect(find.text('Loop this change'), findsOneWidget);
    await tester.tap(find.byKey(const Key('loop_this_change')));
    await tester.pumpAndSettle();

    // The sheet has no player, so what it hands on is the passage and the
    // speed — the same shape a practice mark opens Perform with.
    expect(asked, hasLength(1));
    expect(asked.single.label, 'Bars 5–6');
    expect(asked.single.rate, changeLoopRate);
    expect(asked.single.startMs, 2000);
    expect(asked.single.endMs, 3000);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    SimplerShapesStore.resetForTesting();
  });

  testWidgets('a chord on a song with no grid offers nothing', (tester) async {
    SimplerShapesStore.resetForTesting();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.physicalSize = const Size(520, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final asked = <PracticePart>[];
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SongSheetPanel(
            project: _project('song-no-grid'),
            bundle: _analysis('song-no-grid', downbeats: const <int>[]),
            onReviewLyrics: null,
            onOpenLive: null,
            onPractise: asked.add,
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    await tester.longPress(find.byKey(const Key('edit_chord_2')));
    await tester.pumpAndSettle();
    // No sheet, no offer, and nothing asked for: a loop over bars nobody
    // counted would be confidently wrong.
    expect(find.text('Loop this change'), findsNothing);
    expect(asked, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    SimplerShapesStore.resetForTesting();
  });
}

SongProject _project(String id) {
  final now = DateTime(2026, 9, 18);
  return SongProject(
    id: id,
    roomId: 'room',
    accountId: 'account',
    title: 'Weathervane',
    createdAt: now,
    updatedAt: now,
    contributions: <Contribution>[
      Contribution(
        id: 'line-1',
        projectId: id,
        authorId: 'user-1',
        authorName: 'Taylor',
        body: 'Turning in the wind',
        colorValue: 0xFFFF8A4C,
        createdAt: now,
        position: 1,
      ),
    ],
  );
}

/// A twelve-bar grid of half-second bars, with a chord change part-way
/// through bar 6.
SongAnalysisBundle _analysis(
  String id, {
  List<int> downbeats = const <int>[
    0, 500, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 4500, 5000, 5500,
  ],
}) =>
    SongAnalysisBundle(
      reference: ReferenceTrack(
        projectId: id,
        fileId: 'file',
        storagePath: 'room/$id/reference.m4a',
        displayName: 'Weathervane.m4a',
        state: SongAnalysisState.ready,
        durationMs: 6000,
        musicalKey: 'G',
        transcriptText: 'turning in the wind again',
        transcriptWords: const <TranscriptWord>[
          TranscriptWord(word: 'turning', startMs: 200, endMs: 800),
          TranscriptWord(word: 'in', startMs: 800, endMs: 1100),
          TranscriptWord(word: 'the', startMs: 1100, endMs: 1400),
          TranscriptWord(word: 'wind', startMs: 1400, endMs: 2200),
          TranscriptWord(word: 'again', startMs: 2600, endMs: 3400),
        ],
        downbeatsMs: downbeats,
      ),
      lyricCues: const <LyricSyncCue>[],
      chordCues: const <ChordCue>[
        ChordCue(id: 1, startMs: 200, endMs: 2600, chord: 'G', confidence: 0.9),
        ChordCue(id: 2, startMs: 2600, endMs: 3400, chord: 'C',
            confidence: 0.9),
      ],
    );
