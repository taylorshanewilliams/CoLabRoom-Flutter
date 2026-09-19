import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/feel_the_beat.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A downbeat you can feel.
///
/// A player who cannot hear the click — deaf, hard of hearing, or standing in
/// front of a drummer — has no way of knowing where the 1 is except by
/// watching somebody's foot. The song already knows: the analysis wrote down
/// every beat and which of them start a bar (Every Musician, Same Song,
/// 17 September 2026, "feel the beat, hear the chords coming").
///
/// Off until it is asked for, kept on this device, and never carried to
/// anybody else's phone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final day = DateTime(2026, 9, 17);

  /// Sixteen seconds at 120 in four: a beat every half second, a bar every
  /// two, the way the tracker writes them down.
  final beats = <int>[for (var ms = 0; ms <= 15500; ms += 500) ms];
  const downbeats = <int>[0, 2000, 4000, 6000, 8000, 10000, 12000, 14000];

  group('the beats a phone taps on', () {
    FeltBeat? at(
      int afterMs, {
      FeelTheBeat feel = FeelTheBeat.everyBeat,
      int barOne = 1,
      int? untilMs,
    }) =>
        nextFeltBeat(
          afterMs,
          beatsMs: beats,
          downbeatsMs: downbeats,
          barOne: barOne,
          feel: feel,
          untilMs: untilMs,
        );

    test('every beat, and the 1 heavier than the rest', () {
      expect(at(0), const FeltBeat(atMs: 500, weight: BeatWeight.light));
      expect(at(500), const FeltBeat(atMs: 1000, weight: BeatWeight.light));
      expect(at(1499), const FeltBeat(atMs: 1500, weight: BeatWeight.light));
      // The bar turning over, which is the one a hand is looking for.
      expect(at(1500), const FeltBeat(atMs: 2000, weight: BeatWeight.heavy));
      expect(at(3999), const FeltBeat(atMs: 4000, weight: BeatWeight.heavy));
      // Strictly after: the beat the song is already sitting on has gone by,
      // and a tap the instant somebody presses play is felt as the press.
      expect(at(2000), const FeltBeat(atMs: 2500, weight: BeatWeight.light));
      // The end of the recording: nothing left to feel.
      expect(at(15500), isNull);
    });

    test('the 1 only fires on the 1', () {
      expect(
        at(0, feel: FeelTheBeat.theOne),
        const FeltBeat(atMs: 2000, weight: BeatWeight.heavy),
      );
      expect(
        at(2000, feel: FeelTheBeat.theOne),
        const FeltBeat(atMs: 4000, weight: BeatWeight.heavy),
      );
      // Nothing in between: three of the four beats of every bar are skipped
      // rather than felt lightly.
      expect(
        at(2499, feel: FeelTheBeat.theOne),
        const FeltBeat(atMs: 4000, weight: BeatWeight.heavy),
      );
      expect(at(14000, feel: FeelTheBeat.theOne), isNull);
    });

    test('off schedules nothing at all', () {
      expect(at(0, feel: FeelTheBeat.off), isNull);
      expect(at(1999, feel: FeelTheBeat.off), isNull);
      // And off is what a phone that has never been asked does.
      expect(FeelTheBeat.fromStored(null), FeelTheBeat.off);
      expect(FeelTheBeat.fromStored(''), FeelTheBeat.off);
      expect(FeelTheBeat.fromStored('every'), FeelTheBeat.everyBeat);
      expect(FeelTheBeat.fromStored('one'), FeelTheBeat.theOne);
    });

    test('a song with no beat in it offers nothing', () {
      expect(canFeelTheBeat(beatsMs: const <int>[]), isFalse);
      expect(nextFeltBeat(0, beatsMs: const <int>[]), isNull);
      expect(
        nextFeltBeat(0, beatsMs: const <int>[], feel: FeelTheBeat.theOne),
        isNull,
      );
      expect(canFeelTheBeat(beatsMs: beats), isTrue);
      // A recording analysed before the tracker wrote every beat down may
      // still have its bar starts, and the 1 is the half of this that matters
      // most, so they stand in as the grid.
      expect(
        canFeelTheBeat(beatsMs: const <int>[], downbeatsMs: downbeats),
        isTrue,
      );
      expect(
        nextFeltBeat(0, beatsMs: const <int>[], downbeatsMs: downbeats),
        const FeltBeat(atMs: 2000, weight: BeatWeight.heavy),
      );
    });

    test('the heavy tap lands on bar 1, and the pickup taps light', () {
      // The band has said the song does not start until the third downbeat:
      // what is in front of it is a count-in somebody left on the recording,
      // or a pickup phrase (0161).
      expect(at(0, barOne: 3), const FeltBeat(atMs: 500, weight: BeatWeight.light));
      expect(
        at(1500, barOne: 3),
        const FeltBeat(atMs: 2000, weight: BeatWeight.light),
        reason: 'a downbeat ahead of bar 1 is not a 1',
      );
      expect(at(3500, barOne: 3), const FeltBeat(atMs: 4000, weight: BeatWeight.heavy));
      // Asking for the 1 only in a song with a pickup waits for bar 1 rather
      // than tapping in a bar the song does not have.
      expect(
        at(0, barOne: 3, feel: FeelTheBeat.theOne),
        const FeltBeat(atMs: 4000, weight: BeatWeight.heavy),
      );
    });

    test('nothing is scheduled past where a passage turns round', () {
      // The loop turns at 2000 and seeks, and the seek arms the next tap:
      // a tap held for a beat the song will not reach would land in the wrong
      // bar of the next time round.
      expect(at(1000, untilMs: 2000), const FeltBeat(atMs: 1500, weight: BeatWeight.light));
      expect(at(1500, untilMs: 2000), isNull);
    });
  });

  group('the taps follow the speed', () {
    test('a beat two seconds away is three and a third at 60%', () {
      const bar = FeltBeat(atMs: 2000, weight: BeatWeight.heavy);
      expect(untilFelt(bar, fromMs: 0), const Duration(seconds: 2));
      expect(untilFelt(bar, fromMs: 1500), const Duration(milliseconds: 500));
      expect(
        untilFelt(bar, fromMs: 0, rate: 0.6).inMicroseconds,
        closeTo(3333333, 1),
      );
      expect(
        untilFelt(bar, fromMs: 1500, rate: 0.6).inMicroseconds,
        closeTo(833333, 1),
      );
      expect(untilFelt(bar, fromMs: 0, rate: 0.5), const Duration(seconds: 4));
      // Slowing a song does not re-space it: the beats are where they were,
      // and only the waiting is longer.
      expect(
        nextFeltBeat(1500, beatsMs: beats, downbeatsMs: downbeats),
        bar,
      );
      // A beat already gone is felt now rather than never.
      expect(untilFelt(bar, fromMs: 2500), Duration.zero);
    });
  });

  group('kept on this phone', () {
    test('the choice is remembered, and off is kept as nothing', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      expect(await FeelTheBeatStore.load(), FeelTheBeat.off);

      await FeelTheBeatStore.save(FeelTheBeat.theOne);
      expect(await FeelTheBeatStore.load(), FeelTheBeat.theOne);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('live_feel_the_beat'), 'one');

      await FeelTheBeatStore.save(FeelTheBeat.off);
      expect(prefs.getKeys(), isNot(contains('live_feel_the_beat')));
      expect(await FeelTheBeatStore.load(), FeelTheBeat.off);
    });
  });

  group('on the screen', () {
    final project = SongProject(
      id: 'song-feel',
      roomId: 'room',
      accountId: 'account',
      title: 'Weathervane',
      createdAt: day,
      updatedAt: day,
      contributions: <Contribution>[
        Contribution(
          id: 'line-1',
          projectId: 'song-feel',
          authorId: 'u2',
          authorName: 'Jess',
          body: 'Turning in the wind',
          colorValue: 0xFFFF8A4C,
          createdAt: day,
          position: 1,
        ),
      ],
    );

    const words = <TranscriptWord>[
      TranscriptWord(word: 'turning', startMs: 0, endMs: 800),
      TranscriptWord(word: 'in', startMs: 800, endMs: 1100),
      TranscriptWord(word: 'the', startMs: 1100, endMs: 1400),
      TranscriptWord(word: 'wind', startMs: 1400, endMs: 2200),
    ];

    final onTheBeat = SongAnalysisBundle(
      reference: ReferenceTrack(
        projectId: 'song-feel',
        fileId: 'file',
        storagePath: 'room/song-feel/reference.m4a',
        displayName: 'Weathervane.m4a',
        state: SongAnalysisState.ready,
        durationMs: 16000,
        bpm: 120,
        beatsPerBar: 4,
        beatsMs: beats,
        downbeatsMs: downbeats,
        transcriptText: 'turning in the wind',
        transcriptWords: words,
      ),
      lyricCues: const <LyricSyncCue>[],
      chordCues: const <ChordCue>[],
    );

    const noBeat = SongAnalysisBundle(
      reference: ReferenceTrack(
        projectId: 'song-feel',
        fileId: 'file',
        storagePath: 'room/song-feel/reference.m4a',
        displayName: 'Weathervane.m4a',
        state: SongAnalysisState.ready,
        durationMs: 16000,
        transcriptText: 'turning in the wind',
        transcriptWords: words,
      ),
      lyricCues: <LyricSyncCue>[],
      chordCues: <ChordCue>[],
    );

    Future<void> sized(
      WidgetTester tester, {
      FeelTheBeat feel = FeelTheBeat.off,
    }) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        // The count-in is the other thing in this sheet, and a bar of clicks
        // ahead of the song would move every tap below by two seconds.
        'live_countdown_enabled': false,
        if (feel != FeelTheBeat.off) 'live_feel_the_beat': feel.stored,
      });
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    /// Every tap the phone was asked for, so the beat can be felt with the
    /// phone in a pocket and both eyes on the instrument.
    List<Object?> tapsFelt(WidgetTester tester) {
      final felt = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') felt.add(call.arguments);
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      return felt;
    }

    testWidgets('the song taps on its own beats, heavier on the 1',
        (tester) async {
      await sized(tester, feel: FeelTheBeat.everyBeat);
      final felt = tapsFelt(tester);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(project: project, analysis: onTheBeat),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_play_pause')));
      await tester.pump();
      expect(felt, isEmpty, reason: 'the press is not a beat');

      // A beat is half a second at 120, and the bar turns over on the fourth.
      await tester.pump(const Duration(milliseconds: 500));
      expect(felt, <Object?>['HapticFeedbackType.selectionClick']);
      await tester.pump(const Duration(milliseconds: 1500));
      expect(felt, <Object?>[
        'HapticFeedbackType.selectionClick',
        'HapticFeedbackType.selectionClick',
        'HapticFeedbackType.selectionClick',
        'HapticFeedbackType.heavyImpact',
      ]);

      // Paused, the phone goes still.
      await tester.tap(find.byKey(const Key('live_play_pause')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1500));
      expect(felt.length, 4);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a passage drilled at 60% taps at 60%', (tester) async {
      await sized(tester, feel: FeelTheBeat.everyBeat);
      final felt = tapsFelt(tester);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(project: project, analysis: onTheBeat),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      // Down the speeds one step at a time: 90, 80, 75, 70, 60.
      for (var step = 0; step < 5; step += 1) {
        await tester.tap(find.byKey(const Key('live_rate_slower')));
        await tester.pump();
      }
      expect(find.text('60%'), findsOneWidget);

      await tester.tap(find.byKey(const Key('live_play_pause')));
      await tester.pump();
      // The beat has not moved in the song — it is still half a second in —
      // but the song is taking five thirds as long to reach it.
      await tester.pump(const Duration(milliseconds: 833));
      expect(felt, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(felt, <Object?>['HapticFeedbackType.selectionClick']);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('nothing taps until somebody asks for it', (tester) async {
      await sized(tester);
      final felt = tapsFelt(tester);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(project: project, analysis: onTheBeat),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_play_pause')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 2500));
      expect(felt, isEmpty);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('the choice is offered only where there is a beat to feel',
        (tester) async {
      await sized(tester);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(project: project, analysis: onTheBeat),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_countdown_settings')));
      await tester.pumpAndSettle();
      expect(find.text('Feel the beat'), findsOneWidget);
      expect(find.text('Every beat'), findsOneWidget);
      expect(find.text('The 1 only'), findsOneWidget);
      expect(find.text('Off'), findsOneWidget);

      await tester.tapAt(const Offset(200, 20));
      await tester.pumpAndSettle();

      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(project: project, analysis: noBeat),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const Key('live_countdown_settings')));
      await tester.pumpAndSettle();
      expect(find.text('Feel the beat'), findsNothing);

      await tester.tapAt(const Offset(200, 20));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('choosing the 1 only taps once a bar, and is remembered',
        (tester) async {
      await sized(tester);
      final felt = tapsFelt(tester);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(project: project, analysis: onTheBeat),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_countdown_settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('live_feel_theOne')));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(200, 20));
      await tester.pumpAndSettle();

      expect(await FeelTheBeatStore.load(), FeelTheBeat.theOne);

      await tester.tap(find.byKey(const Key('live_play_pause')));
      await tester.pump();
      // Three beats of the bar go by without a word, and the 1 arrives.
      await tester.pump(const Duration(milliseconds: 1999));
      expect(felt, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(felt, <Object?>['HapticFeedbackType.heavyImpact']);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
