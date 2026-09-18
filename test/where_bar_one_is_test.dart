import 'dart:async';

import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/practice_mark.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/rooms/setlist_pack.dart';
import 'package:colabroom/features/workspace/chord_chart_view.dart';
import 'package:colabroom/features/workspace/count_in.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:colabroom/features/workspace/practice_rules.dart';
import 'package:colabroom/features/workspace/song_sheet_panel.dart';
import 'package:colabroom/services/chord_beat_grid.dart';
import 'package:colabroom/services/chord_chart.dart';
import 'package:colabroom/services/follow_me.dart';
import 'package:colabroom/services/midi_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

    test('a loop that reaches back into it keeps playing, and is named',
        () {
      // Somebody had the first four bars on repeat to listen for where the
      // song really starts, and then said bar 1 is the third downbeat. The
      // same two times now begin inside the pickup. They are still a real
      // passage on this recording, so they are still on repeat, and they
      // have a name that reads (review, 18 September 2026).
      final reached = loopFor(0, 2000, sections: sections,
          downbeatsMs: downbeats, barOne: barOne)!;
      expect(reached.label, 'Pickup–bar 2');
      expect(reached.startMs, 0);
      expect(reached.endMs, 2000);
      expect(reached.firstBar, 0);
      expect(reached.lastBar, 2);

      // In the numbering the recording came with, the same two times are
      // simply the first four bars.
      expect(
        loopFor(0, 2000, sections: sections, downbeatsMs: downbeats)?.label,
        'Bars 1–4',
      );
      // And nothing ahead of the grid is a passage at all.
      expect(
        loopFor(-500, -100, downbeatsMs: downbeats, barOne: barOne),
        isNull,
      );
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

    test('the set list card counts the band in the same way', () {
      // The same grid, on the card and in the printed set pack. Perform
      // counts this band in on four; before 0161 reached here the pack still
      // said two (review, 18 September 2026).
      const grid = <int>[0, 1000, 2000, 3000, 4000, 6000, 8000, 10000];
      const reference = ReferenceTrack(
        projectId: 'song-bar-one',
        fileId: 'file',
        storagePath: 'room/song-bar-one/reference.m4a',
        displayName: 'Four Before One.m4a',
        state: SongAnalysisState.ready,
        bpm: 120,
        durationMs: 12000,
        downbeatsMs: grid,
      );
      const sheet = SongAnalysisBundle(
        reference: reference,
        lyricCues: <LyricSyncCue>[],
        chordCues: <ChordCue>[],
      );
      final song = SongProject(
        id: 'song-bar-one',
        roomId: 'room',
        accountId: 'account',
        title: 'Four Before One',
        createdAt: day,
        updatedAt: day,
      );
      expect(setSongFacts(null, song, sheet).countIn, 'One bar of 2');
      expect(
        setSongFacts(null, song.copyWith(barOneDownbeat: 5), sheet).countIn,
        'One bar of 4',
      );
    });

    test('Follow me carries where bar 1 is, so both chips say it', () {
      // The likeliest moment to say it is in the middle of the lesson it
      // fixes: the teacher hears the count-in, moves bar 1, and asks for bars
      // nine to twelve. The student's phone was handed its copy of the song
      // when Perform opened and never hears about the change any other way,
      // so it rides on the heartbeat beside the times (review, 18 September
      // 2026). It is a fact about the song, not a reading, so this does not
      // break the rule that a person's numbers and capo stay on their phone.
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
        barOne: barOne,
      );
      final heard = FollowState.fromJson(sent.toJson())!;
      expect(heard.barOne, barOne);
      expect(
        loopFor(heard.loopStartMs, heard.loopEndMs, sections: sections,
            downbeatsMs: downbeats, barOne: heard.barOne!)?.label,
        'Bars 9–10',
      );

      // Clearing it reaches them too: 0 is "use the detected bars", and it
      // has to be on the wire, because a key left out reads as a build that
      // does not say and leaves the follower on the bar 1 just cleared.
      final cleared =
          FollowState.fromJson(FollowState(
        sheet: true,
        synced: true,
        playing: true,
        positionMs: 0,
        rate: 1,
        sentAt: day.millisecondsSinceEpoch,
        barOne: 0,
      ).toJson())!;
      expect(cleared.barOne, 0);
      // A message from a build that predates this says nothing, and the
      // follower keeps what its own copy of the song says.
      expect(FollowState.fromJson(<String, dynamic>{
        'at': 0,
        'rate': 1,
        'sent': day.millisecondsSinceEpoch,
      })!.barOne, isNull);
      // Saying it is a decision, sent at once rather than on the next beat.
      expect(sent.sameDecisions(sent), isTrue);
      expect(sent.sameDecisions(FollowState(
        sheet: sent.sheet,
        synced: sent.synced,
        playing: sent.playing,
        positionMs: sent.positionMs,
        rate: sent.rate,
        sentAt: sent.sentAt,
        loopStartMs: sent.loopStartMs,
        loopEndMs: sent.loopEndMs,
        barOne: 0,
      )), isFalse);
    });

    test('the chart starts a line on bar 1, so the margin can say so', () {
      // A pickup with a chord in each bar and no section starting at bar 1.
      // Four to a line from the top of the recording would put bar 1 third in
      // its row under a blank margin, and nothing on the page would show
      // where bar 1 is -- the one thing somebody just said (review, 18
      // September 2026).
      final played = <ChordCue>[
        for (var i = 0; i < downbeats.length; i += 1)
          ChordCue(
            id: i + 1,
            chord: i.isEven ? 'G' : 'C',
            startMs: downbeats[i],
            endMs: downbeats[i] + 500,
            confidence: 0.9,
          ),
      ];
      final rows = buildChartRows(buildChartBars(
        cues: played,
        beatsMs: const <int>[],
        downbeatsMs: downbeats,
        barOne: barOne,
      ));
      expect(rows.first.bars.every((bar) => bar.number == 0), isTrue,
          reason: 'the pickup gets a line of its own, with a blank margin');
      expect(
        rows.skip(1).map((row) => row.firstBarNumber),
        <int>[1, 5, 9],
        reason: "the lines start where the printed part's lines start",
      );

      // With nobody having said anything the chart is exactly what it was:
      // four to a line from the top, and no line of its own for a pickup
      // that does not exist.
      final detected = buildChartRows(buildChartBars(
        cues: played,
        beatsMs: const <int>[],
        downbeatsMs: downbeats,
      ));
      expect(detected.map((row) => row.firstBarNumber), <int>[1, 5, 9]);
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

    testWidgets('a mark from before bar 1 moved still opens on its passage',
        (tester) async {
      // A mark kept on the first four bars, on a song that has since been
      // told its bar 1 is the third downbeat. Those two times now begin
      // inside the pickup. Practise has to open on that passage, named: a
      // silent fall back to the whole song from 0:00 is the passage lost
      // (review, 18 September 2026).
      await sized(tester);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project.copyWith(barOneDownbeat: barOne),
          analysis: bundle,
          me: 'u2',
          practise: const PracticePart(
            label: 'Bars 1–4',
            rate: 1,
            seconds: 240,
            startMs: 0,
            endMs: 2000,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Pickup–bar 2'), findsOneWidget);
      expect(find.text('Bars 1–4'), findsNothing);

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

    testWidgets('a chart that is refused says so, rather than nothing',
        (tester) async {
      // Offline, on a build older than the migration, or after being made a
      // viewer on another device. The long press closes its own sheet before
      // the write starts, so the refusal is said on the page underneath it --
      // and it is said, rather than becoming an unhandled error nobody sees
      // (review, 18 September 2026).
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tester.view.physicalSize = const Size(520, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: SongSheetPanel(
              project: project,
              bundle: const SongAnalysisBundle(
                reference: ReferenceTrack(
                  projectId: 'song-bar-one',
                  fileId: 'file',
                  storagePath: 'room/song-bar-one/reference.m4a',
                  displayName: 'Four Before One.m4a',
                  state: SongAnalysisState.ready,
                  durationMs: 6000,
                  musicalKey: 'G',
                  downbeatsMs: downbeats,
                  transcriptText: 'turning in the wind',
                  transcriptWords: <TranscriptWord>[
                    TranscriptWord(word: 'turning', startMs: 1000,
                        endMs: 1800),
                    TranscriptWord(word: 'wind', startMs: 2400, endMs: 3200),
                  ],
                ),
                lyricCues: <LyricSyncCue>[],
                chordCues: <ChordCue>[
                  ChordCue(id: 1, chord: 'G', startMs: 0, endMs: 1000,
                      confidence: 0.9),
                  ChordCue(id: 2, chord: 'C', startMs: 1000, endMs: 2000,
                      confidence: 0.9),
                ],
              ),
              onReviewLyrics: null,
              onOpenLive: null,
              onSetBarOne: (downbeat) async => throw const PostgrestException(
                message:
                    'Only somebody who can edit this song can say where bar '
                    '1 is.',
                code: '42501',
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Chart'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('C').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chart_this_is_bar_one')));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text("You don't have access to do that."), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('a follower hears where bar 1 is, and its chip agrees',
        (tester) async {
      // The lesson is where this gets said: the teacher hears the count-in
      // mid-song and moves bar 1. The student's phone was handed its copy of
      // the song when Perform opened, so without it on the heartbeat their
      // chip would answer in different numbers for the rest of the hour
      // (review, 18 September 2026).
      await sized(tester);
      final bus = _Bus();
      final mine = FollowSession(
        line: _Line(bus, 'me', 'u2', 'Jess'),
        userId: 'u2',
        name: 'Jess',
      );
      final teacher = _Line(bus, 'teacher', 'u1', 'Taylor')..arrive();
      final since = DateTime.now().millisecondsSinceEpoch;
      final bars = barLoop(firstBar: 9, lastBar: 10, downbeatsMs: downbeats,
          songEndMs: 6000, barOne: barOne)!;
      void beat({required int? barOneSaid}) =>
          unawaited(teacher.sendFollow(<String, dynamic>{
            'kind': 'lead',
            'device': 'teacher',
            'user': 'u1',
            'name': 'Taylor',
            'since': since,
            'state': FollowState(
              sheet: true,
              synced: true,
              playing: false,
              positionMs: 5200,
              rate: 1,
              sentAt: DateTime.now().millisecondsSinceEpoch,
              loopStartMs: bars.startMs,
              loopEndMs: bars.endMs,
              barOne: barOneSaid,
            ).toJson(),
          }));

      beat(barOneSaid: 0);
      mine.follow();
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          // This phone's copy of the song has heard nothing about bar 1.
          project: project,
          analysis: bundle,
          together: mine,
          me: 'u2',
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Bars 11–12'), findsOneWidget,
          reason: 'the detected bars, which is all either phone has said');

      // The teacher says it, mid-lesson, and the next heartbeat carries it.
      beat(barOneSaid: barOne);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Bars 9–10'), findsOneWidget);
      expect(find.text('Bars 11–12'), findsNothing);

      // And putting the detected bars back reaches them too.
      beat(barOneSaid: 0);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Bars 11–12'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      mine.dispose();
      expect(tester.takeException(), isNull);
    });
  });
}

/// The live connection two phones share, as far as Follow me is concerned.
/// Copied from follow_me_test.dart, which is where it is explained.
class _Bus {
  // Lives as long as one test; nothing outlives it to leak into.
  // ignore: close_sinks
  final StreamController<Map<String, dynamic>> messages =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);
  // ignore: close_sinks
  final StreamController<List<SongDevice>> devices =
      StreamController<List<SongDevice>>.broadcast(sync: true);
  final Map<String, SongDevice> here = <String, SongDevice>{};
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  void announce() => devices.add(here.values.toList(growable: false));
}

class _Line implements FollowLine {
  _Line(this.bus, this.device, this.userId, this.name) {
    bus.here[device] =
        SongDevice(device: device, userId: userId, displayName: name);
  }

  final _Bus bus;
  @override
  final String device;
  final String userId;
  final String name;

  void arrive() => bus.announce();

  @override
  Stream<Map<String, dynamic>> get followMessages => bus.messages.stream;

  @override
  Stream<List<SongDevice>> get devices => bus.devices.stream;

  @override
  Future<void> sendFollow(Map<String, dynamic> message) async {
    bus.sent.add(message);
    bus.messages.add(message);
  }

  @override
  Future<void> markFollowing(String? following) async {
    bus.here[device] = SongDevice(
        device: device,
        userId: userId,
        displayName: name,
        following: following);
    bus.announce();
  }
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
