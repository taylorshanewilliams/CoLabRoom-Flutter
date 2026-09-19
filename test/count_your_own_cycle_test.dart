import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/practice_mark.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/domain/song_cycle.dart';
import 'package:colabroom/features/workspace/count_in.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/features/workspace/practice_rules.dart';
import 'package:colabroom/services/chord_beat_grid.dart';
import 'package:colabroom/services/follow_me.dart';
import 'package:colabroom/services/multitrack.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

/// Count your own cycle.
///
/// Bars in this app are the analysis downbeats, numbered from wherever the
/// band says bar 1 is, and for a great deal of the music people actually play
/// that is the wrong unit: a seven counted 3+2+2 is not a run of four-beat
/// bars, and "bars nine to twelve" in a count nobody uses is arithmetic on a
/// music stand. The alternative that was refused is a library of named
/// cycles nobody here has reviewed; what is built instead is the thing a
/// player already knows -- a count and its stresses (Every Musician, Same
/// Song, 17 September 2026, decision 20).
void main() {
  final day = DateTime(2026, 9, 18);

  /// Thirty-two beats of a song at 120: one every half second, four to a bar.
  const beats = <int>[
    0, 500, 1000, 1500, 2000, 2500, 3000, 3500, //
    4000, 4500, 5000, 5500, 6000, 6500, 7000, 7500,
    8000, 8500, 9000, 9500, 10000, 10500, 11000, 11500,
    12000, 12500, 13000, 13500, 14000, 14500, 15000, 15500,
  ];

  /// The eight bars the tracker heard, which are not what this band counts.
  const downbeats = <int>[
    0, 2000, 4000, 6000, 8000, 10000, 12000, 14000,
  ];

  /// "7: 3+2+2".
  final seven = SongCycle(7, const <int>[4, 6]);

  group('a count and its stresses', () {
    test('it reads the way a player says it out loud', () {
      expect(seven.beats, 7);
      expect(seven.groups, <int>[3, 2, 2]);
      expect(seven.reading, '7: 3+2+2');
      // Sixteen in fours, with the first beat of each group stressed.
      expect(SongCycle(16, const <int>[5, 9, 13]).reading, '16: 4+4+4+4');
      // And a count with nothing said inside it is still a count.
      expect(SongCycle(7).reading, '7');
      expect(SongCycle(7).groups, <int>[7]);
    });

    test('what comes in is tidied, never refused', () {
      // What a row of taps and an older build between them can hand over:
      // out of order, repeated, past the end, and the first beat named
      // although it is the cycle itself rather than a stress inside it.
      expect(SongCycle(7, const <int>[6, 4, 6, 1, 9]).accents, <int>[4, 6]);
      // A count below two does not go round, and a count nobody plays is
      // pulled into the range the taps can show.
      expect(SongCycle(1).beats, 2);
      expect(SongCycle(400).beats, SongCycle.maxBeats);
      expect(SongCycle.of(null), isNull);
      expect(SongCycle.of(1), isNull);
      expect(SongCycle.of(7, const <int>[4, 6]), seven);
    });

    test('shortening the count drops the stresses past its end', () {
      expect(seven.withBeats(5).accents, <int>[4]);
      expect(seven.withBeats(5).reading, '5: 3+2');
    });

    test('the first beat is the cycle, so it cannot be turned off', () {
      expect(seven.isAccented(1), isTrue);
      expect(seven.toggle(1), seven);
      expect(seven.toggle(4).accents, <int>[6]);
      expect(seven.toggle(2).accents, <int>[2, 4, 6]);
    });
  });

  group('the cycle replaces the bars', () {
    test('every cycle is its own beats along the grid', () {
      final grid = cycleGridFor(seven, beatsMs: beats,
          downbeatsMs: downbeats)!;
      // Cycle 1 starts where bar 1 does and each one is seven beats on. The
      // tracker's own downbeats are used for nothing else: a seven over a
      // recording heard in fours does not land on them, and is not meant to.
      expect(grid.downbeatsMs, <int>[0, 3500, 7000, 10500, 14000]);
      expect(grid.barOne, 1);
      expect(barNumberAt(3500, grid.downbeatsMs, barOne: grid.barOne), 2);
      expect(barNumberAt(3499, grid.downbeatsMs, barOne: grid.barOne), 1);
      expect(barNumberAt(14000, grid.downbeatsMs, barOne: grid.barOne), 5);
      // And the same instants, in the bars the tracker heard, are something
      // else entirely.
      expect(barNumberAt(3500, downbeats), 2);
      expect(barNumberAt(14000, downbeats), 8);
    });

    test('a run of cycles is named in cycles', () {
      final grid = cycleGridFor(seven, beatsMs: beats,
          downbeatsMs: downbeats)!;
      final loop = barLoop(
        firstBar: 2,
        lastBar: 3,
        downbeatsMs: grid.downbeatsMs,
        songEndMs: 16000,
        barOne: grid.barOne,
        cycles: true,
      )!;
      expect(loop.label, 'Cycles 2–3');
      expect(loop.startMs, 3500);
      expect(loop.endMs, 10500);
      expect(barsLabel(2, 2, cycles: true), 'Cycle 2');
      // The pickup keeps its one word, whatever is being counted.
      expect(barsLabel(0, 0, cycles: true), 'Pickup');
      expect(barsLabel(0, 3, cycles: true), 'Pickup–cycle 3');
      // And nothing about the bars themselves changed for a song that
      // counts them.
      expect(barsLabel(2, 3), 'Bars 2–3');
    });

    test('a loop found from two times comes back named in cycles', () {
      final grid = cycleGridFor(seven, beatsMs: beats,
          downbeatsMs: downbeats)!;
      expect(
        loopFor(3500, 10500, downbeatsMs: grid.downbeatsMs,
            barOne: grid.barOne, cycles: true)?.label,
        'Cycles 2–3',
      );
    });

    test('cycle 1 starts where the band says bar 1 is', () {
      // Two bars of count-in on the front of the recording: the band's bar 1
      // is the third downbeat, and the cycle starts there (0161).
      final grid = cycleGridFor(seven, beatsMs: beats,
          downbeatsMs: downbeats, barOne: 3)!;
      expect(grid.barOne, 2, reason: 'one entry in front for the pickup');
      expect(grid.downbeatsMs, <int>[0, 4000, 7500, 11000, 14500]);
      expect(barNumberAt(4000, grid.downbeatsMs, barOne: grid.barOne), 1);
      expect(barNumberAt(3999, grid.downbeatsMs, barOne: grid.barOne), isNull);
      final pickup = pickupLoop(grid.downbeatsMs, barOne: grid.barOne)!;
      expect(pickup.label, 'Pickup');
      expect(pickup.startMs, 0);
      expect(pickup.endMs, 4000);
    });

    test('a song with no beats offers nothing', () {
      // A recording analysed before beat tracking, or one the tracker gave no
      // confident answer for. A cycle is a count of beats, and there are none
      // to count.
      expect(cycleGridFor(seven, beatsMs: const <int>[],
          downbeatsMs: downbeats), isNull);
      expect(longestCycle(const <int>[], downbeatsMs: downbeats), lessThan(2));
      // And nothing counted is nothing laid over the song either.
      expect(cycleGridFor(null, beatsMs: beats, downbeatsMs: downbeats),
          isNull);
    });

    test('a cycle the song cannot go round twice is not counted', () {
      // One cycle is not a count: there is no second one to come round to,
      // and the picker has no run to choose between. The song keeps the bars
      // the analysis found.
      expect(longestCycle(beats, downbeatsMs: downbeats), 16);
      expect(cycleGridFor(SongCycle(32), beatsMs: beats,
          downbeatsMs: downbeats), isNull);
      // Right up to the longest it does hold.
      expect(cycleGridFor(SongCycle(16), beatsMs: beats,
              downbeatsMs: downbeats)?.downbeatsMs,
          <int>[0, 8000]);
      // And from a later bar 1 there are fewer beats left to count.
      expect(longestCycle(beats, downbeatsMs: downbeats, barOne: 5), 8);
    });
  });

  group('the count-in counts one whole cycle', () {
    test('it is the cycle, not the metre the tracker heard', () {
      final counted =
          countInFor(bpm: 120, beatsPerBar: 4, downbeatsMs: downbeats,
              cycle: seven)!;
      expect(counted.beats, 7);
      expect(counted.accents, <int>[4, 6]);
      expect(counted.length, const Duration(milliseconds: 3500));
      // Unmoved, the same song is counted in on the four the tracker heard.
      expect(
        countInFor(bpm: 120, beatsPerBar: 4, downbeatsMs: downbeats)!.beats,
        4,
      );
    });

    test('the stresses are felt, the first beat heaviest', () {
      final counted =
          countInFor(bpm: 120, downbeatsMs: downbeats, cycle: seven)!;
      expect(counted.strokeAt(1), CycleStroke.sam);
      expect(counted.strokeAt(4), CycleStroke.accent);
      expect(counted.strokeAt(6), CycleStroke.accent);
      expect(counted.strokeAt(2), CycleStroke.beat);
      expect(counted.strokeAt(7), CycleStroke.beat);
      // Without a cycle the count is the even tick it always was: nothing
      // here reaches a song nobody counted a cycle for.
      final plain = countInFor(bpm: 120, downbeatsMs: downbeats)!;
      expect(plain.strokeAt(1), CycleStroke.beat);
      expect(plain.accents, isEmpty);
    });

    test('a song with no beat of its own keeps the seconds', () {
      expect(countInFor(bpm: null, downbeatsMs: downbeats, cycle: seven),
          isNull);
      expect(countInFor(bpm: 120, downbeatsMs: const <int>[], cycle: seven),
          isNull);
    });
  });

  group('the click strikes the cycle', () {
    test('the schedule is the first beat, the stresses, and the rest', () {
      expect(
        seven.schedule,
        <CycleStroke>[
          CycleStroke.sam,
          CycleStroke.beat,
          CycleStroke.beat,
          CycleStroke.accent,
          CycleStroke.beat,
          CycleStroke.accent,
          CycleStroke.beat,
        ],
      );
      // The same schedule, as the click asks it: beat zero is the first of
      // the cycle and it repeats from there.
      expect(
        <CycleStroke>[
          for (var beat = 0; beat < 9; beat += 1)
            Multitrack.strokeOfBeat(beat,
                beatsPerBar: 7, accents: seven.accents),
        ],
        <CycleStroke>[...seven.schedule, CycleStroke.sam, CycleStroke.beat],
      );
      // And with nothing stressed it is the click exactly as it was: the
      // first beat of the bar marked, the rest even.
      expect(Multitrack.strokeOfBeat(0, beatsPerBar: 4), CycleStroke.sam);
      expect(Multitrack.strokeOfBeat(2, beatsPerBar: 4), CycleStroke.beat);
      expect(Multitrack.strokeOfBeat(2, beatsPerBar: 1), CycleStroke.beat);
    });

    test('a stressed beat is struck harder than an even one, and the first '
        'beat hardest of all', () {
      // One cycle at 120: seven beats half a second apart.
      const samplesPerBeat = Multitrack.rate ~/ 2;
      final struck = Multitrack.click(
        bpm: 120,
        lengthSamples: samplesPerBeat * 7,
        beatsPerBar: 7,
        accents: seven.accents,
      );
      double peakAt(int beat) {
        var loudest = 0.0;
        final from = samplesPerBeat * (beat - 1);
        for (var i = from; i < from + 400 && i < struck.length; i += 1) {
          final level = struck[i].abs();
          if (level > loudest) loudest = level;
        }
        return loudest;
      }

      expect(peakAt(1), greaterThan(peakAt(4)));
      expect(peakAt(4), greaterThan(peakAt(2)));
      expect(peakAt(6), peakAt(4));
      expect(peakAt(7), peakAt(2));
    });
  });

  group('who may count it', () {
    test('counting it, and putting the analysed bars back', () async {
      final repository = InMemoryMusicRepository.seeded();
      final rooms = await repository.loadRooms();
      final song =
          rooms.expand((room) => room.projects).firstWhere((_) => true);
      expect(song.cycle, isNull, reason: 'nobody has counted one');

      await repository.setSongCycle(song.id, seven);
      expect((await _song(repository, song.id)).cycle, seven);

      // Tidied on the way in, the way 0162 tidies it: a stress past the end
      // of the count, or on the first beat, is not kept.
      await repository.setSongCycle(song.id, SongCycle(5, const <int>[1, 3, 9]));
      expect((await _song(repository, song.id)).cycle?.accents, <int>[3]);

      await repository.setSongCycle(song.id, null);
      expect((await _song(repository, song.id)).cycle, isNull);
    });

    test('a song that is not there is refused rather than half-written',
        () async {
      final repository = InMemoryMusicRepository.seeded();
      await expectLater(
        repository.setSongCycle('not-a-song', seven),
        throwsA(isA<PostgrestException>()
            .having((e) => e.code, 'code', '22023')),
      );
      final rooms = await repository.loadRooms();
      expect(
        rooms.expand((room) => room.projects).every((p) => p.cycle == null),
        isTrue,
      );
    });

    // 0162 lets the owner and the editors count, and nobody else. This
    // repository said yes to all four until the review of 18 September 2026:
    // the refusal Perform is written to handle was a branch no test could
    // reach, and a test group called "who may count it" proved nothing of
    // the kind.
    test('an editor may count it and somebody who can only look may not',
        () async {
      final repository = InMemoryMusicRepository.seeded();
      repository.addToRoom(
        'room-1',
        const RoomMember(
          userId: 'vee',
          displayName: 'Vee',
          role: RoomRole.viewer,
          colorValue: 0xFFE3B34D,
        ),
      );
      final rooms = await repository.loadRooms();
      final song = rooms
          .firstWhere((room) => room.id == 'room-1')
          .projects
          .firstWhere((_) => true);

      // The editor: usually the person actually playing the thing, which is
      // the reason the gate is owner-or-editor rather than owner.
      repository.currentUserId = 'preview-jess';
      await repository.setSongCycle(song.id, seven);
      expect((await _song(repository, song.id)).cycle, seven);

      Matcher refused() => throwsA(
            isA<PostgrestException>()
                .having((e) => e.code, 'code', '42501')
                .having((e) => e.message, 'message', contains('can edit')),
          );

      repository.currentUserId = 'vee';
      await expectLater(repository.setSongCycle(song.id, SongCycle(5)), refused());
      // And clearing is a write like any other: somebody who may only look
      // cannot hand the room back to the analysed bars either.
      await expectLater(repository.setSongCycle(song.id, null), refused());

      repository.currentUserId = 'nobody-at-all';
      await expectLater(repository.setSongCycle(song.id, SongCycle(5)), refused());

      // Through all of that the song still counts what the editor said.
      expect((await _song(repository, song.id)).cycle, seven);

      repository.currentUserId = 'preview-user';
      await repository.setSongCycle(song.id, null);
      expect((await _song(repository, song.id)).cycle, isNull);
    });

    test('a song a teacher sends carries the cycle to every student',
        () async {
      // 0162 restates send_song_to_students for this, as 0161 did for bar 1:
      // a teacher who counts a seven and then says "from cycle nine" has to
      // be saying it about the copy on the student's stand.
      final repository = InMemoryMusicRepository.seeded();
      final studio = (await repository.loadRooms())
          .firstWhere((room) => room.name == 'Acoustic Ideas');
      final song = await repository.createSong(room: studio, title: 'A Seven');
      await repository.setSongCycle(song.id, seven);
      final lesson =
          repository.teachALesson(studentId: 'student-1', studentName: 'Jess');

      final sent = await repository.sendSongToStudents(
        projectId: song.id,
        roomIds: <String>[lesson.id],
      );
      expect(sent, isNotEmpty, reason: 'the song reached the lesson');

      final copy = (await repository.loadRooms())
          .firstWhere((room) => room.id == lesson.id)
          .projects
          .firstWhere((_) => true);
      expect(copy.cycle, seven,
          reason: 'the student counts what the teacher counts');
    });
  });

  group('on the screen', () {
    final project = SongProject(
      id: 'song-cycle',
      roomId: 'room',
      accountId: 'account',
      title: 'Three Two Two',
      createdAt: day,
      updatedAt: day,
      contributions: <Contribution>[
        Contribution(
          id: 'line-1',
          projectId: 'song-cycle',
          authorId: 'u2',
          authorName: 'Jess',
          body: 'Turning in the wind',
          colorValue: 0xFFFF8A4C,
          createdAt: day,
          position: 1,
        ),
      ],
    );

    SongAnalysisBundle sheet({List<int> beatsMs = beats}) =>
        SongAnalysisBundle(
          reference: ReferenceTrack(
            projectId: 'song-cycle',
            fileId: 'file',
            storagePath: 'room/song-cycle/reference.m4a',
            displayName: 'Three Two Two.m4a',
            state: SongAnalysisState.ready,
            durationMs: 16000,
            bpm: 120,
            beatsMs: beatsMs,
            downbeatsMs: downbeats,
            transcriptText: 'turning in the wind',
            transcriptWords: const <TranscriptWord>[
              TranscriptWord(word: 'turning', startMs: 1000, endMs: 1800),
              TranscriptWord(word: 'in', startMs: 1800, endMs: 2100),
              TranscriptWord(word: 'the', startMs: 2100, endMs: 2400),
              TranscriptWord(word: 'wind', startMs: 2400, endMs: 3200),
            ],
          ),
          lyricCues: const <LyricSyncCue>[],
          chordCues: const <ChordCue>[],
        );

    Future<void> sized(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    testWidgets('a cycle is counted in the picker, and the numbers follow',
        (tester) async {
      await sized(tester);
      final counted = <SongCycle?>[];
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project,
          analysis: sheet(),
          onCountCycle: (cycle) async => counted.add(cycle),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      // The bars the tracker heard, which is what the picker opens on.
      await tester.tap(find.byKey(const Key('live_loop_bars')));
      await tester.pumpAndSettle();
      expect(find.text('Bars 1–4'), findsOneWidget);

      await tester.tap(find.byKey(const Key('live_count_a_cycle')));
      await tester.pumpAndSettle();
      // It opens on the count the analysis heard, so the taps are a
      // correction rather than a blank form.
      expect(find.text('4'), findsWidgets);
      await tester.tap(find.byKey(const Key('live_cycle_beats_on')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('live_cycle_beats_on')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('live_cycle_beats_on')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('live_cycle_beat_4')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('live_cycle_beat_6')));
      await tester.pump();
      expect(find.text('7: 3+2+2'), findsOneWidget);

      await tester.tap(find.byKey(const Key('live_cycle_count')));
      await tester.pumpAndSettle();
      expect(counted, <SongCycle?>[SongCycle(7, const <int>[4, 6])]);

      // Nothing is announced. The chip behind the picker simply counts
      // something else now.
      expect(find.text('Cycles'), findsOneWidget);
      await tester.tap(find.byKey(const Key('live_loop_bars')));
      await tester.pumpAndSettle();
      expect(find.text('Cycles 1–4'), findsOneWidget);
      expect(find.text('Bars 1–4'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('the analysed bars come back', (tester) async {
      await sized(tester);
      final counted = <SongCycle?>[];
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project.copyWith(cycle: seven),
          analysis: sheet(),
          onCountCycle: (cycle) async => counted.add(cycle),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_loop_bars')));
      await tester.pumpAndSettle();
      expect(find.text('Cycles 1–4'), findsOneWidget);
      // The reading stands in for "Count a cycle" once there is one, so the
      // count can be read without opening anything.
      expect(find.text('7: 3+2+2'), findsOneWidget);

      await tester.tap(find.byKey(const Key('live_count_a_cycle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('live_cycle_clear')));
      await tester.pumpAndSettle();
      expect(counted, <SongCycle?>[null]);
      expect(find.text('Bars'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a mark reopened on a passage names it in the band\'s cycles',
        (tester) async {
      // A mark carries two times and nothing else, and the name is worked out
      // again where it is reopened. On a song counted in sevens those two
      // times are cycles, not bars, and Practise has to say so or the
      // sentence the teacher used is not the one on the screen.
      await sized(tester);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project.copyWith(cycle: seven),
          analysis: sheet(),
          me: 'u2',
          practise: const PracticePart(
            label: 'Bars 2–6',
            rate: 0.7,
            seconds: 240,
            startMs: 3500,
            endMs: 10500,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Cycles 2–3'), findsOneWidget);
      expect(find.text('Bars 2–6'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('somebody who can only look is not offered it', (tester) async {
      await sized(tester);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project.copyWith(cycle: seven),
          analysis: sheet(),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_loop_bars')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('live_count_a_cycle')), findsNothing);
      // The cycle is still the room's, and its cycles are still loopable.
      expect(find.text('Cycles 1–4'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a song the tracker found no beats in offers nothing',
        (tester) async {
      await sized(tester);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project,
          analysis: sheet(beatsMs: const <int>[]),
          onCountCycle: (_) async {},
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_loop_bars')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('live_count_a_cycle')), findsNothing);
      // The bars it did find are still there to loop.
      expect(find.text('Bars 1–4'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a cycle it cannot hold leaves the song on its bars',
        (tester) async {
      // A cycle written when the recording was longer, or read off a song
      // whose re-analysis found half the beats. Nothing announces it: the
      // song counts the bars the analysis has, which is what it would have
      // done if nobody had counted at all.
      await sized(tester);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project.copyWith(cycle: SongCycle(32)),
          analysis: sheet(),
          onCountCycle: (_) async {},
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_loop_bars')));
      await tester.pumpAndSettle();
      expect(find.text('Bars 1–4'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a long cycle is counted in without running off the phone',
        (tester) async {
      // A bar of the song's own metre is at most twelve dots and has always
      // fitted across a phone in one row. A cycle counts a whole cycle, and
      // sixteen dots in a row is 406 logical pixels: wider than the 360dp
      // phone most of the people this is for are holding, so every count-in
      // ended in a RenderFlex overflow with dots clipped off the right edge
      // (review, 18 September 2026).
      SharedPreferences.setMockInitialValues(<String, Object>{
        'live_countdown_enabled': true,
        'live_countdown_seconds': 5,
      });
      // The narrowest phone in real use here, in portrait.
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project.copyWith(cycle: SongCycle(16, const <int>[5, 9, 13])),
          analysis: sheet(),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_play_pause')));
      await tester.pump();

      // The whole cycle is counted, and every dot of it is on the screen.
      expect(find.byKey(const Key('live_count_in_dot_16')), findsOneWidget);
      expect(find.byKey(const Key('live_count_in_dot_17')), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('bar 1 is only offered where the cycle starts on a downbeat',
        (tester) async {
      // bar_one_downbeat can only name a downbeat the analysis found (0161),
      // and a seven laid over a recording heard in fours begins most of its
      // cycles between two of them. The build this replaces wrote the
      // nearest: the player pointed at the sam and the room's numbers moved
      // to a beat nobody chose (review, 18 September 2026).
      //
      // Cycle 1 is at 0ms, which is a downbeat. Cycle 2 is at 3500ms, and
      // the nearest downbeat is 4000 — a whole beat away, so there is
      // nothing honest to write and the button is not there.
      await sized(tester);
      final said = <int?>[];
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project.copyWith(cycle: seven, barOneDownbeat: 1),
          analysis: sheet(),
          onSayBarOne: (downbeat) async => said.add(downbeat),
          onCountCycle: (_) async {},
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_loop_bars')));
      await tester.pumpAndSettle();
      expect(find.text('Cycles 1–4'), findsOneWidget);
      // Said in the count the sheet is printing, not in bars.
      expect(find.text('This is cycle 1'), findsOneWidget);
      expect(find.text('This is bar 1'), findsNothing);
      // And the cycle sheet owns "Use the detected bars" while cycles are
      // counted: two buttons with those words in one sheet, one of which
      // left the song in cycles, is the sheet contradicting itself.
      expect(find.byKey(const Key('live_use_detected_bars')), findsNothing);

      // On to cycle 2, which begins between two downbeats.
      await tester.tap(find.byKey(const Key('live_bar_first_on')));
      await tester.pumpAndSettle();
      expect(find.text('Cycles 2–4'), findsOneWidget);
      expect(find.byKey(const Key('live_this_is_bar_one')), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('the analysed bars still say bar 1 in bars', (tester) async {
      // Nothing about the cycle changes the sheet a song nobody has counted
      // one for.
      await sized(tester);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project.copyWith(barOneDownbeat: 2),
          analysis: sheet(),
          onSayBarOne: (_) async {},
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_loop_bars')));
      await tester.pumpAndSettle();
      expect(find.text('This is bar 1'), findsOneWidget);
      expect(find.byKey(const Key('live_use_detected_bars')), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('"from B" still lands on B, not on the top of its cycle',
        (tester) async {
      // A cycle changes what the numbers are called; it does not move the
      // music. sectionDownbeatMs lands on the entry at or before a part's
      // start, which over analysed bars costs at most a bar of lead-in — the
      // reason it is written that way. Laid over the cycle grid the same
      // rule cost a whole cycle: B at 6000 would have dropped the band at
      // 3500, two and a half seconds early, every time (review, 18 September
      // 2026).
      await sized(tester);
      final withParts = SongAnalysisBundle(
        reference: ReferenceTrack(
          projectId: 'song-cycle',
          fileId: 'file',
          storagePath: 'room/song-cycle/reference.m4a',
          displayName: 'Three Two Two.m4a',
          state: SongAnalysisState.ready,
          durationMs: 16000,
          bpm: 120,
          beatsMs: beats,
          downbeatsMs: downbeats,
          transcriptText: 'turning in the wind',
          structureSections: const <StructureSection>[
            StructureSection(startMs: 0, endMs: 6000, label: 'A'),
            StructureSection(startMs: 6000, endMs: 16000, label: 'B'),
          ],
        ),
        lyricCues: const <LyricSyncCue>[],
        chordCues: const <ChordCue>[],
      );

      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project.copyWith(cycle: seven),
          analysis: withParts,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      // The song is counted in sevens: the chip says so.
      expect(find.text('Cycles'), findsOneWidget);

      await tester.tap(find.byKey(const Key('live_letter_1')));
      await tester.pump();
      // 6000 of 16000. The cycle grid's nearest entry at or before it is
      // 3500, which is 0.219 and is what this used to do.
      expect(
        tester.widget<Slider>(find.byKey(const Key('live_seek'))).value,
        closeTo(0.375, 0.005),
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a refused count puts the bars back on the chip',
        (tester) async {
      // What 0162 does to somebody who may only look, and what this screen
      // does about it: the numbers move first because the room is where this
      // is decided, and a refusal puts them back with the reason on screen.
      await sized(tester);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project,
          analysis: sheet(),
          onCountCycle: (_) async => throw PostgrestException(
            message: 'Only somebody who can edit this song can count its '
                'cycle.',
            code: '42501',
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_loop_bars')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('live_count_a_cycle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('live_cycle_count')));
      await tester.pumpAndSettle();

      // Back on the bars the analysis found, and told so — the sentence a
      // refused write gets everywhere else in this app (describeForUser).
      expect(find.text('Bars'), findsOneWidget);
      expect(find.text('Cycles'), findsNothing);
      expect(find.text("You don't have access to do that."), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('follow me carries the cycle', () {
    // 0161 put bar 1 on the heartbeat for exactly this reason, and the cycle
    // is the same kind of fact. Perform is handed its copy of the song when
    // it is pushed, so a cycle counted mid-lesson reaches a follower no
    // other way: without this the leader's chip reads "Cycles 4–5" and the
    // follower's reads "Bars 22–25" for the rest of the hour, and the
    // practice mark kept for the student is labelled in a count nobody said
    // out loud (review, 18 September 2026).
    FollowState leading({int? beats, List<int>? accents}) => FollowState(
          sheet: false,
          synced: true,
          playing: true,
          positionMs: 3500,
          rate: 1,
          sentAt: 1000,
          barOne: 0,
          cycleBeats: beats,
          cycleAccents: accents,
        );

    test('the count and its stresses survive the wire', () {
      final there = FollowState.fromJson(
        leading(beats: 7, accents: const <int>[4, 6]).toJson(),
      );
      expect(there, isNotNull);
      expect(there!.cycleBeats, 7);
      expect(there.cycleAccents, <int>[4, 6]);
      expect(there.cycle, seven);
    });

    test('a cleared cycle reaches the room as 0, the way bar 1 does', () {
      final there = FollowState.fromJson(
        leading(beats: 0, accents: const <int>[]).toJson(),
      );
      expect(there!.cycleBeats, 0);
      // Below two is not a cycle anybody counts, so it reads as the analysed
      // bars rather than as a broken message.
      expect(there.cycle, isNull);
    });

    test('a build that says nothing leaves the follower alone', () {
      // An older leader sends no cycle at all, and null is how the follower
      // knows to keep what its own copy of the song says.
      final there = FollowState.fromJson(leading().toJson());
      expect(there!.cycleBeats, isNull);
      expect(there.cycleAccents, isNull);
      expect(there.cycle, isNull);
    });

    test('counting one is a decision, and goes at once', () {
      final bars = leading(beats: 0, accents: const <int>[]);
      final sevens = leading(beats: 7, accents: const <int>[4, 6]);
      expect(bars.sameDecisions(sevens), isFalse);
      expect(sevens.sameDecisions(sevens), isTrue);
      // And a stress moved is a decision too: the follower's count-in has to
      // strike where the leader's does.
      expect(
        sevens.sameDecisions(leading(beats: 7, accents: const <int>[3, 6])),
        isFalse,
      );
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
