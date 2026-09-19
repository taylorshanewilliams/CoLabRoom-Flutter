import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/practice_mark.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/feel_the_beat.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/services/click_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A count-in with no sound in it, so a test can count the taps rather than
/// wait for a file to be written.
class _SilentClick implements ClickPlayer {
  @override
  Future<void> play({
    required double bpm,
    required int beatsPerBar,
    int bars = 8,
    bool loop = true,
    List<int> accents = const <int>[],
  }) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

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

    test('a downbeat a hair off a beat is still the 1', () {
      // The two lists come from the same tracker and normally agree to the
      // millisecond. A rounding hair must not cost a song every heavy tap it
      // has, which would be the whole feature gone and nothing to see.
      const off = <int>[0, 2012, 4000, 6000];
      expect(
        nextFeltBeat(1500, beatsMs: beats, downbeatsMs: off),
        const FeltBeat(atMs: 2000, weight: BeatWeight.heavy),
      );
      // And not so wide that the beat before the bar turns heavy as well:
      // two heavy taps half a beat apart is not a 1, it is a stutter.
      expect(
        nextFeltBeat(1000, beatsMs: beats, downbeatsMs: off),
        const FeltBeat(atMs: 1500, weight: BeatWeight.light),
      );
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

    test('a beat the song lands on by itself is the beat', () {
      // A finger moved the song, so the beat under it has gone by.
      expect(at(2000), const FeltBeat(atMs: 2500, weight: BeatWeight.light));
      // Nobody moved it: the passage on repeat came back round onto its own
      // first downbeat. That is the 1 the whole lap is being felt for.
      expect(
        nextFeltBeat(2000,
            beatsMs: beats, downbeatsMs: downbeats, onTheBeat: true),
        const FeltBeat(atMs: 2000, weight: BeatWeight.heavy),
      );
      // One bar on repeat, asking for the 1 only: the downbeat it turns onto
      // is the single tap of the lap, and the one at the far end belongs to
      // the lap after it. Strictly after, this bar is felt as nothing at all
      // (review, 19 September 2026).
      expect(
        nextFeltBeat(2000,
            beatsMs: beats,
            downbeatsMs: downbeats,
            feel: FeelTheBeat.theOne,
            untilMs: 4000,
            onTheBeat: true),
        const FeltBeat(atMs: 2000, weight: BeatWeight.heavy),
      );
      expect(
        at(2000, feel: FeelTheBeat.theOne, untilMs: 4000),
        isNull,
        reason: 'which is what it was worth fixing',
      );
      // Landing between beats is landing between beats, however it happened.
      expect(
        nextFeltBeat(2200,
            beatsMs: beats, downbeatsMs: downbeats, onTheBeat: true),
        const FeltBeat(atMs: 2500, weight: BeatWeight.light),
      );
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
      bool countIn = false,
    }) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        // The count-in is the other thing in this sheet, and a bar of clicks
        // ahead of the song would move every tap below by two seconds. On
        // where it is wanted, it is the point of the test.
        'live_countdown_enabled': countIn,
        if (feel != FeelTheBeat.off) 'live_feel_the_beat': feel.stored,
      });
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    /// The clock the song is kept by, handed to the screen so it is the one
    /// the test moves.
    ///
    /// Without this the timers run on the test's clock and the song runs on
    /// the wall clock, which does not move during a test: the song would sit
    /// at 0:00 however far the test pumped, and a tap worked out from where
    /// the song is could not be told from one chained off a metronome. The
    /// same trick the take's count-in is measured with.
    DateTime Function() clockOf(WidgetTester tester) =>
        () => tester.binding.clock.now();

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
        home: LivePerformanceScreen(
          project: project,
          analysis: onTheBeat,
          now: clockOf(tester),
        ),
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
        home: LivePerformanceScreen(
          project: project,
          analysis: onTheBeat,
          now: clockOf(tester),
        ),
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

      // And still on the song's beats a dozen beats later. Six seconds of
      // room time is three and a half seconds of song, which is seven beats
      // of it and one bar line: a tap worked out from the last tap instead of
      // from where the song is would have run away by now.
      await tester.pump(const Duration(milliseconds: 5166));
      expect(felt, hasLength(7));
      expect(felt[3], 'HapticFeedbackType.heavyImpact');
      expect(felt.where((f) => f == 'HapticFeedbackType.heavyImpact'), hasLength(1));

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a bar on repeat taps the 1 it comes back to, every lap',
        (tester) async {
      await sized(tester, feel: FeelTheBeat.theOne);
      final felt = tapsFelt(tester);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project,
          analysis: onTheBeat,
          now: clockOf(tester),
          // One bar, held down and drilled: the second bar of the song, from
          // its downbeat to the next one.
          practise: const PracticePart(
            label: 'Bar 2',
            rate: 1,
            seconds: 60,
            startMs: 2000,
            endMs: 4000,
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_play_pause')));
      await tester.pump();
      // The press is not a beat, and the bar holds only one 1.
      expect(felt, isEmpty);

      // Three times round the bar, and the hand feels the 1 each time. The
      // bar's own downbeat is the only beat in it that counts, so treating it
      // as one that had gone by left this phone completely still (review,
      // 19 September 2026).
      await tester.pump(const Duration(milliseconds: 6100));
      expect(felt, <Object?>[
        'HapticFeedbackType.heavyImpact',
        'HapticFeedbackType.heavyImpact',
        'HapticFeedbackType.heavyImpact',
      ]);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('the 1 a count-in hands the song over on is felt',
        (tester) async {
      await sized(tester, feel: FeelTheBeat.theOne, countIn: true);
      final felt = tapsFelt(tester);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project,
          analysis: onTheBeat,
          now: clockOf(tester),
          click: _SilentClick(),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_play_pause')));
      await tester.pump();
      // Four beats of the song's own tempo, counted and felt: light ticks,
      // the count-in's own, and the song not moving yet.
      await tester.pump(const Duration(milliseconds: 1500));
      expect(find.byKey(const Key('live_count_in')), findsOneWidget);
      expect(felt, hasLength(4));
      expect(felt.every((f) => f == 'HapticFeedbackType.selectionClick'), isTrue);

      // The beat after the fourth is the song's own 1. Nobody pressed
      // anything: the count put the song on that downbeat and walked it up to
      // it, so it is felt rather than treated as a beat already gone.
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('live_count_in')), findsNothing);
      expect(felt.last, 'HapticFeedbackType.heavyImpact');
      expect(felt, hasLength(5));

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a long pause leaves the song where it was', (tester) async {
      await sized(tester, feel: FeelTheBeat.everyBeat);
      final felt = tapsFelt(tester);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project,
          analysis: onTheBeat,
          now: clockOf(tester),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_play_pause')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 750));
      expect(felt, hasLength(1));

      // Put down for half a minute, the way a rehearsal stops.
      await tester.tap(find.byKey(const Key('live_play_pause')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 30));
      expect(felt, hasLength(1));

      // Picked up again: the song is still three quarters of a second in, so
      // the next tap is the beat after that one and not one half a minute
      // further down the recording. Where the song is is where it was
      // stopped, never that plus however long the break was (review,
      // 19 September 2026).
      await tester.tap(find.byKey(const Key('live_play_pause')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 251));
      expect(felt, hasLength(2));
      await tester.pump(const Duration(milliseconds: 500));
      expect(felt, hasLength(3));
      expect(felt.last, 'HapticFeedbackType.selectionClick');

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('nothing taps until somebody asks for it', (tester) async {
      await sized(tester);
      final felt = tapsFelt(tester);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project,
          analysis: onTheBeat,
          now: clockOf(tester),
        ),
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
        home: LivePerformanceScreen(
          project: project,
          analysis: onTheBeat,
          now: clockOf(tester),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      // And the button that leads to it says so, which is also what a screen
      // reader reads out: a hard-of-hearing player is not going to go looking
      // for the beat underneath a count-in.
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('live_countdown_settings')))
            .tooltip,
        'Count-in, beat and drone',
      );

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
        home: LivePerformanceScreen(
          project: project,
          analysis: noBeat,
          now: clockOf(tester),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('live_countdown_settings')))
            .tooltip,
        'Count-in and drone',
        reason: 'a song with no beat in it is offered none',
      );
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
        home: LivePerformanceScreen(
          project: project,
          analysis: onTheBeat,
          now: clockOf(tester),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_countdown_settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('live_feel_theOne')));
      await tester.pumpAndSettle();
      // The chip they tapped is the one that is lit. The sheet is its own
      // route, so it has to keep the answer itself: nothing is playing while
      // it is open and there is no preview tap, which makes the chip the only
      // answer a player gets (review, 19 September 2026).
      expect(
        tester.widget<ChoiceChip>(find.byKey(const Key('live_feel_theOne'))).selected,
        isTrue,
      );
      expect(
        tester.widget<ChoiceChip>(find.byKey(const Key('live_feel_off'))).selected,
        isFalse,
      );
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
