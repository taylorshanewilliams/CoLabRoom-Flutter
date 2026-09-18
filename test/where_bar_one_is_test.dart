import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/practice_mark.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/chord_chart_view.dart';
import 'package:colabroom/features/workspace/count_in.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:colabroom/features/workspace/practice_rules.dart';
import 'package:colabroom/services/chord_beat_grid.dart';
import 'package:colabroom/services/chord_chart.dart';
import 'package:colabroom/services/follow_me.dart';
import 'package:colabroom/services/midi_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Say where bar 1 is.
///
/// Bar numbers came off the analysis downbeats with bar 1 as the first of
/// them (#362), which is right for a song that starts on its own downbeat and
/// a bar out for every song with a pickup phrase or a count-in left on the
/// front of the recording. A teacher holding the printed part then says "bars
/// nine to twelve" and means a different passage from the one the app puts on
/// repeat, and the pickup itself could not be looped at all because it had no
/// number to be asked for by (Every Musician, Same Song, 17 September 2026;
/// Taylor's default, decision 4 after wave 1).
void main() {
  final day = DateTime(2026, 9, 18);

  /// Twelve downbeats half a second apart. The first two are a count-in on
  /// the recording, so the band's bar 1 is the third of them, at 1000ms.
  const downbeats = <int>[
    0, 500, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 4500, 5000, 5500,
  ];
  const barOne = 3;

  const sections = <StructureSection>[
    StructureSection(startMs: 1000, endMs: 3000, label: 'Verse'),
    StructureSection(startMs: 3000, endMs: 6000, label: 'Chorus'),
  ];

  group('the numbering shifts with the setting', () {
    test('bar 1 is the downbeat the band says it is', () {
      expect(barNumberAt(1000, downbeats, barOne: barOne), 1);
      expect(barNumberAt(1499, downbeats, barOne: barOne), 1);
      expect(barNumberAt(5000, downbeats, barOne: barOne), 9);
      // Past the end of the grid, the last bar it has.
      expect(barNumberAt(999999, downbeats, barOne: barOne), 10);
      // And with nobody having said anything, exactly what it always was.
      expect(barNumberAt(5000, downbeats), 11);
      expect(barNumberAt(1000, downbeats), 3);
    });

    test('nothing ahead of bar 1 is given a number', () {
      // The count-in on the front of the recording. Not bar 1, not bar 0, and
      // never a negative: it is the pickup, and it is asked for by name.
      expect(barNumberAt(0, downbeats, barOne: barOne), isNull);
      expect(barNumberAt(999, downbeats, barOne: barOne), isNull);
      expect(barNumberAt(-200, downbeats, barOne: barOne), isNull);
    });

    test('a bar 1 past the end of a shorter re-analysis is pulled inside it',
        () {
      // The setting lives on the song and the downbeats come from the
      // recording, so a re-analysis that finds a shorter grid can leave a
      // song counting from a bar it no longer has.
      expect(barOneIndex(9, 4), 3);
      expect(numberedBarCount(9, 4), 1);
      expect(barNumberAt(1500, const <int>[0, 500, 1000, 1500], barOne: 9), 1);
    });

    test('a song with no downbeats is exactly as it was', () {
      expect(barNumberAt(1000, const <int>[], barOne: barOne), isNull);
      expect(barLoop(firstBar: 1, lastBar: 4, downbeatsMs: const <int>[],
          barOne: barOne), isNull);
      expect(pickupLoop(const <int>[], barOne: barOne), isNull);
      expect(
        loopFor(1000, 2000, sections: sections, barOne: barOne),
        isNull,
        reason: 'a time range is not bars when there is no grid to count on',
      );
    });
  });

  group('bar loops count from it', () {
    test('a bar starts and ends where the band counts it', () {
      expect(barStartMs(1, downbeats, barOne: barOne), 1000);
      expect(barStartMs(9, downbeats, barOne: barOne), 5000);
      expect(barEndMs(9, downbeats, barOne: barOne), 5500);
      expect(barEndMs(10, downbeats, barOne: barOne, songEndMs: 6000), 6000);
      // Unmoved, the same bars are where they always were.
      expect(barStartMs(9, downbeats), 4000);
    });

    test('a run of bars is the passage the printed part names', () {
      final loop =
          barLoop(firstBar: 9, lastBar: 10, downbeatsMs: downbeats,
              songEndMs: 6000, barOne: barOne)!;
      expect(loop.label, 'Bars 9–10');
      expect(loop.startMs, 5000);
      expect(loop.endMs, 6000);
      // The same two seconds, unmoved, are bars 11 and 12.
      expect(
        barLoop(firstBar: 11, lastBar: 12, downbeatsMs: downbeats,
            songEndMs: 6000)!.startMs,
        5000,
      );
      // Ten bars, not twelve: the two ahead of bar 1 are the pickup, and
      // asking for bar 11 of a ten-bar song gets bar 10.
      expect(numberedBarCount(barOne, downbeats.length), 10);
      expect(
        barLoop(firstBar: 11, lastBar: 14, downbeatsMs: downbeats,
            songEndMs: 6000, barOne: barOne)!.label,
        'Bar 10',
      );
    });
  });

  group('the pickup is a thing you can ask for', () {
    test('it runs from the top of the recording to bar 1', () {
      final pickup = pickupLoop(downbeats, barOne: barOne)!;
      expect(pickup.label, 'Pickup');
      expect(pickup.startMs, 0);
      expect(pickup.endMs, 1000);
    });

    test('a song that starts on its own downbeat has none', () {
      expect(pickupLoop(downbeats), isNull);
      expect(pickupLoop(downbeats, barOne: 1), isNull);
    });

    test('it reads back as the pickup, the way a section reads back', () {
      expect(
        loopFor(0, 1000, sections: sections, downbeatsMs: downbeats,
            barOne: barOne)?.label,
        'Pickup',
      );
      // And past the end of it, back to its own start.
      final pickup = pickupLoop(downbeats, barOne: barOne);
      expect(keepInside(const Duration(milliseconds: 1000), pickup),
          Duration.zero);
    });

    test('a number below one is a word, never a number', () {
      expect(barsLabel(0, 0), 'Pickup');
      expect(barsLabel(0, 3), 'Pickup–bar 3');
      expect(barsLabel(9, 10), 'Bars 9–10');
    });
  });

  group('everything that names bars agrees', () {
    test('Follow me sends two times, and both ends name the same bars', () {
      final bars = barLoop(firstBar: 9, lastBar: 10, downbeatsMs: downbeats,
          songEndMs: 6000, barOne: barOne)!;
      final sent = FollowState(
        sheet: true,
        synced: true,
        playing: true,
        positionMs: 5200,
        rate: 0.7,
        sentAt: day.millisecondsSinceEpoch,
        loopStartMs: bars.startMs,
        loopEndMs: bars.endMs,
      );
      final heard = FollowState.fromJson(sent.toJson())!;
      // The leader never sends the words. The follower works them out from
      // its own copy of the same song, which carries the same bar 1.
      final followed = loopFor(
        heard.loopStartMs,
        heard.loopEndMs,
        sections: sections,
        downbeatsMs: downbeats,
        barOne: barOne,
      )!;
      expect(followed.label, 'Bars 9–10');
      expect(followed, bars);
    });

    test('the chord chart numbers the margin the same way', () {
      final bars = buildChartBars(
        cues: const <ChordCue>[
          ChordCue(id: 1, chord: 'G', startMs: 0, endMs: 1000,
              confidence: 0.9),
          ChordCue(id: 2, chord: 'C', startMs: 1000, endMs: 5000,
              confidence: 0.9),
          ChordCue(id: 3, chord: 'D', startMs: 5000, endMs: 6000,
              confidence: 0.9),
        ],
        beatsMs: const <int>[],
        downbeatsMs: downbeats,
        sections: sections,
        barOne: barOne,
      );
      // Every bar of the recording is still drawn -- the pickup is music
      // somebody plays -- it simply has no number.
      expect(bars.first.number, 0);
      expect(bars.first.downbeat, 1);
      expect(bars.firstWhere((bar) => bar.startMs == 1000).number, 1);
      expect(bars.firstWhere((bar) => bar.startMs == 5000).number, 9);
      // The section label stays on the bar of the recording it starts on,
      // whatever that bar is now called.
      expect(
        bars.firstWhere((bar) => bar.startMs == 1000).sectionLabel,
        'Verse',
      );
      // And the same chart, unmoved, is the one it always was.
      final detected = buildChartBars(
        cues: const <ChordCue>[
          ChordCue(id: 1, chord: 'G', startMs: 0, endMs: 1000,
              confidence: 0.9),
          ChordCue(id: 2, chord: 'C', startMs: 1000, endMs: 5000,
              confidence: 0.9),
          ChordCue(id: 3, chord: 'D', startMs: 5000, endMs: 6000,
              confidence: 0.9),
        ],
        beatsMs: const <int>[],
        downbeatsMs: downbeats,
        sections: sections,
      );
      expect(detected.first.number, 1);
      expect(detected.firstWhere((bar) => bar.startMs == 5000).number, 11);
    });

    test('the sheet gutter numbers the lines the same way', () {
      final lines = transcriptSheetLines(
        transcriptWords: const <TranscriptWord>[
          // Sung over the count-in, which is a real thing on a recording.
          TranscriptWord(word: 'one', startMs: 0, endMs: 300),
          TranscriptWord(word: 'turning', startMs: 1000, endMs: 1800),
          TranscriptWord(word: 'again', startMs: 5000, endMs: 5600),
        ],
        transcriptText: 'one turning again',
        chordCues: const <ChordCue>[],
        durationMs: 6000,
        downbeatsMs: downbeats,
        barOne: barOne,
      );
      expect(lines.map((line) => line.bar), <int?>[null, 1, 9]);
    });

    test('the DAW gets a pickup bar in front of bar 1', () {
      // Four seconds of count-in at 120, then the song. Without the setting
      // the DAW's bar 1 is the count's; with it the count is the pickup and
      // every bar line after it lands on a bar of the song.
      const grid = <int>[0, 2000, 4000, 6000, 8000];
      final counted =
          SongTempoMap.forSong(bpm: 120, downbeatsMs: grid, barOne: 3);
      expect(counted.pickupBeats, 8);
      expect(counted.firstDownbeatTick, 8 * SongTempoMap.defaultTicksPerBeat);
      expect(counted.tickAt(4000), counted.firstDownbeatTick);
      expect(counted.statedBpm, closeTo(120, 0.01));

      final detected = SongTempoMap.forSong(bpm: 120, downbeatsMs: grid);
      expect(detected.pickupBeats, 0);
      expect(detected.firstDownbeatTick, 0);
    });

    test('the count-in is counted in bars of the song, not of the count', () {
      // The tracker read the count-in as four bars of two beats, and the song
      // is in four. Across the whole recording those four gaps outvote the
      // song's three and the band gets counted in on two.
      const grid = <int>[0, 1000, 2000, 3000, 4000, 6000, 8000, 10000];
      expect(countInFor(bpm: 120, downbeatsMs: grid)?.beats, 2);
      expect(countInFor(bpm: 120, downbeatsMs: grid, barOne: 5)?.beats, 4);
    });
  });

  group('who may say it', () {
    test('saying it, and putting the detected bars back', () async {
      final repository = InMemoryMusicRepository.seeded();
      final rooms = await repository.loadRooms();
      final song = rooms
          .expand((room) => room.projects)
          .firstWhere((project) => true);
      expect(song.barOneDownbeat, isNull);
      expect(song.barOne, 1, reason: 'nobody has said, so the first downbeat');

      await repository.setBarOne(song.id, 3);
      expect((await _song(repository, song.id)).barOne, 3);

      await repository.setBarOne(song.id, null);
      final back = await _song(repository, song.id);
      expect(back.barOneDownbeat, isNull);
      expect(back.barOne, 1);
    });
  });

  group('on the screen', () {
    final project = SongProject(
      id: 'song-bar-one',
      roomId: 'room',
      accountId: 'account',
      title: 'Four Before One',
      createdAt: day,
      updatedAt: day,
      contributions: <Contribution>[
        Contribution(
          id: 'line-1',
          projectId: 'song-bar-one',
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
        projectId: 'song-bar-one',
        fileId: 'file',
        storagePath: 'room/song-bar-one/reference.m4a',
        displayName: 'Four Before One.m4a',
        state: SongAnalysisState.ready,
        durationMs: 6000,
        downbeatsMs: downbeats,
        transcriptText: 'turning in the wind',
        transcriptWords: <TranscriptWord>[
          TranscriptWord(word: 'turning', startMs: 1000, endMs: 1800),
          TranscriptWord(word: 'in', startMs: 1800, endMs: 2100),
          TranscriptWord(word: 'the', startMs: 2100, endMs: 2400),
          TranscriptWord(word: 'wind', startMs: 2400, endMs: 3200),
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

    testWidgets('the picker says which bar is bar 1, and the numbers move',
        (tester) async {
      await sized(tester);
      final said = <int?>[];
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project,
          analysis: bundle,
          onSayBarOne: (downbeat) async => said.add(downbeat),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      // A passage picked in the numbering the recording came with.
      await tester.tap(find.byKey(const Key('live_loop_bars')));
      await tester.pumpAndSettle();
      tester
          .widget<RangeSlider>(find.byKey(const Key('live_bar_range')))
          .onChanged!(const RangeValues(11, 12));
      await tester.pump();
      await tester.tap(find.byKey(const Key('live_bar_loop_apply')));
      await tester.pumpAndSettle();
      expect(find.text('Bars 11–12'), findsOneWidget);

      // The printed part in somebody's hands calls that bar 1. Nothing is
      // announced: the numbers behind the picker simply move.
      await tester.tap(find.byKey(const Key('live_loop_bars')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('live_this_is_bar_one')));
      await tester.pumpAndSettle();
      expect(said, <int?>[11]);
      expect(find.text('Bars 11–12'), findsNothing);
      expect(
        find.text('Bars 1–2'),
        findsOneWidget,
        reason: 'the same passage, counted from the bar the band counts from',
      );

      // And what is played before it is now a pickup, which can be put on
      // repeat on its own -- the one thing it could never be.
      await tester.tap(find.byKey(const Key('live_loop_bars')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('live_bar_loop_pickup')));
      await tester.pumpAndSettle();
      expect(find.text('Pickup'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('somebody who can only look is not offered it', (tester) async {
      await sized(tester);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(project: project, analysis: bundle),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_loop_bars')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('live_this_is_bar_one')), findsNothing);
      // The bars are still the room's, and still loopable.
      expect(find.text('Bars 1–4'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a mark reopened on a passage names it in the band\'s bars',
        (tester) async {
      await sized(tester);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          // The same two seconds a mark remembers, on a song that counts from
          // its third downbeat: the mark carries times, and the name is
          // worked out again here.
          project: project.copyWith(barOneDownbeat: barOne),
          analysis: bundle,
          me: 'u2',
          practise: const PracticePart(
            label: 'Bars 11–12',
            rate: 0.7,
            seconds: 240,
            startMs: 5000,
            endMs: 6000,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Bars 9–10'), findsOneWidget);
      expect(find.text('Bars 11–12'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('holding a bar of the chart says it is bar 1', (tester) async {
      await sized(tester);
      final said = <int?>[];
      final rows = buildChartRows(buildChartBars(
        cues: const <ChordCue>[
          ChordCue(id: 1, chord: 'G', startMs: 0, endMs: 1000,
              confidence: 0.9),
          ChordCue(id: 2, chord: 'C', startMs: 1000, endMs: 2000,
              confidence: 0.9),
          ChordCue(id: 3, chord: 'D', startMs: 2000, endMs: 3000,
              confidence: 0.9),
        ],
        beatsMs: const <int>[],
        downbeatsMs: downbeats,
      ));
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: Scaffold(
          body: ChordChartView(
            rows: rows,
            transpose: 0,
            fontScale: 1,
            onSayBarOne: (downbeat) async => said.add(downbeat),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // The third bar of the chart is the third downbeat of the recording,
      // and that is what gets written down -- a place in the analysis, not a
      // number that moves when bar 1 does.
      await tester.longPress(find.text('C'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chart_this_is_bar_one')));
      await tester.pumpAndSettle();
      expect(said, <int?>[3]);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}

Future<SongProject> _song(
  InMemoryMusicRepository repository,
  String id,
) async {
  final rooms = await repository.loadRooms();
  return rooms
      .expand((room) => room.projects)
      .firstWhere((project) => project.id == id);
}
