import 'dart:async';

import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/count_in.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/services/click_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Count in on the song's own beat.
///
/// Perform's count-in was three to ten seconds of a number getting smaller,
/// which says when the song starts and nothing about how fast it goes. A band
/// is counted in *at the tempo it is about to play*, and by the fourth beat
/// everybody is already inside the time (Every Musician, Same Song,
/// 17 September 2026). Songs the analysis never found a beat in keep the
/// seconds, because a bar counted at a guessed tempo would be confidently
/// wrong in a way nobody in the room could see.
class _SilentClick implements ClickPlayer {
  final List<String> log = <String>[];

  @override
  Future<void> play({
    required double bpm,
    required int beatsPerBar,
    int bars = 8,
    bool loop = true,
  }) async =>
      log.add('play ${bpm.round()}/$beatsPerBar x$bars${loop ? ' looped' : ''}');

  @override
  Future<void> stop() async => log.add('stop');

  @override
  Future<void> dispose() async => log.add('dispose');
}

/// A click still being written, which on a cold first play is a few hundred
/// milliseconds of a phone doing nothing visible.
class _SlowClick implements ClickPlayer {
  final Completer<void> written = Completer<void>();
  final List<String> log = <String>[];

  @override
  Future<void> play({
    required double bpm,
    required int beatsPerBar,
    int bars = 8,
    bool loop = true,
  }) {
    log.add('play ${bpm.round()}/$beatsPerBar x$bars');
    return written.future;
  }

  @override
  Future<void> stop() async => log.add('stop');

  @override
  Future<void> dispose() async => log.add('dispose');
}

void main() {
  final day = DateTime(2026, 9, 17);

  /// Eight bars of two seconds each: 120bpm in four.
  const downbeats = <int>[0, 2000, 4000, 6000, 8000, 10000, 12000, 14000];

  group('one bar of the song\'s own time', () {
    test('a bar is its beats, at its tempo', () {
      expect(beatLength(120), const Duration(milliseconds: 500));
      expect(barLength(bpm: 120, beatsPerBar: 4), const Duration(seconds: 2));
      // A waltz is three beats, not four, so its bar is shorter at the same
      // tempo — the count-in has to be the song's metre or it is a lie about
      // where the one is.
      expect(barLength(bpm: 120, beatsPerBar: 3), const Duration(milliseconds: 1500));
      expect(barLength(bpm: 90, beatsPerBar: 3).inMilliseconds, 2000);
    });

    test('a bar the analysis could not count is four', () {
      expect(beatsInBar(null), 4);
      expect(beatsInBar(3), 3);
      expect(beatsInBar(6), 6);
      // Not a bar anybody plays: one beat is not a count-in and thirteen is
      // the tracker having lost the plot.
      expect(beatsInBar(1), 4);
      expect(beatsInBar(13), 4);
    });

    test('a waltz the analysis did not count is still counted three', () {
      // Downbeats two seconds apart at 90 is three beats to a bar, and the
      // downbeats are already there — counting that song four would be
      // counting a metre it does not have, which is the one thing counting on
      // the song's own beat is for.
      const waltz = <int>[0, 2000, 4000, 6000];
      expect(beatsInBar(null, bpm: 90, downbeatsMs: waltz), 3);
      expect(beatsInBar(null, bpm: 120, downbeatsMs: downbeats), 4);
      // One downbeat the tracker dropped is a single gap of twice the length,
      // and the median steps over it rather than calling the song six.
      expect(
        beatsInBar(null, bpm: 90, downbeatsMs: <int>[0, 2000, 4000, 8000, 10000]),
        3,
      );
      // Nothing to derive it from, and nothing said: four, as before.
      expect(beatsInBar(null, bpm: 90), 4);
      expect(beatsInBar(null, downbeatsMs: waltz), 4);
      // What the analysis did say is never second-guessed.
      expect(beatsInBar(3, bpm: 120, downbeatsMs: downbeats), 3);
    });

    test('a slower speed is counted in slower', () {
      // Counting at a hundred and coming in at seventy-five is worse than not
      // counting at all.
      final full = countInFor(bpm: 120, beatsPerBar: 4, downbeatsMs: downbeats)!;
      final slowed =
          countInFor(bpm: 120, beatsPerBar: 4, downbeatsMs: downbeats, rate: 0.75)!;
      expect(full.bpm, 120);
      expect(slowed.bpm, 90);
      expect(full.length, const Duration(seconds: 2));
      expect(slowed.length.inMilliseconds, closeTo(2667, 1));
    });
  });

  group('the first downbeat lands on time', () {
    final countIn = countInFor(bpm: 120, beatsPerBar: 4, downbeatsMs: downbeats)!;

    test('the count starts now and runs a beat short of the bar', () {
      expect(countInBeatAt(countIn, 1), Duration.zero);
      expect(countInBeatAt(countIn, 2), const Duration(milliseconds: 500));
      expect(countInBeatAt(countIn, 4), const Duration(milliseconds: 1500));
    });

    test('the song comes in on the beat after the last one counted', () {
      // Not on the fourth beat, which would put the band a beat ahead of the
      // first note, and not a beat late either.
      expect(countIn.length, const Duration(seconds: 2));
      expect(
        countIn.length - countInBeatAt(countIn, countIn.beats),
        countIn.beat,
      );
    });

    test('a waltz is counted three and comes in on the fourth', () {
      final waltz = countInFor(bpm: 180, beatsPerBar: 3, downbeatsMs: downbeats)!;
      expect(waltz.beats, 3);
      expect(waltz.length.inMilliseconds, closeTo(1000, 1));
      expect(countInBeatAt(waltz, 3).inMilliseconds, closeTo(667, 1));
    });
  });

  group('songs without a beat keep the seconds', () {
    test('a tempo with no downbeats under it is not a beat', () {
      // A bpm on its own can be a guess. The downbeats are the evidence the
      // tracker actually heard the song's time.
      expect(countInFor(bpm: 120, beatsPerBar: 4), isNull);
      expect(countInFor(bpm: null, downbeatsMs: downbeats), isNull);
      expect(countInFor(bpm: 0, downbeatsMs: downbeats), isNull);
    });

    test('a tempo outside what a beat can be is refused, not pulled in', () {
      // A tracker reading a fast punk song at 260 and having it pulled to 240
      // would count the bar at a tempo the song is not at, and the song would
      // arrive after the count said it would. Every time, invisibly. The
      // seconds promise nothing, so the seconds are the honest answer.
      expect(countInFor(bpm: 260, beatsPerBar: 4, downbeatsMs: downbeats), isNull);
      expect(countInFor(bpm: 30, beatsPerBar: 4, downbeatsMs: downbeats), isNull);
      expect(countInFor(bpm: 240, beatsPerBar: 4, downbeatsMs: downbeats), isNotNull);
      expect(countInFor(bpm: 40, beatsPerBar: 4, downbeatsMs: downbeats), isNotNull);
      // A speed the player chose is not a tempo the tracker guessed, so it is
      // applied after the range check: half speed really is half the tempo.
      expect(
        countInFor(bpm: 60, beatsPerBar: 4, downbeatsMs: downbeats, rate: 0.5)!.bpm,
        30,
      );
    });

    test('a song with no analysis at all has nothing to count', () {
      expect(countInForSong(null), isNull);
      expect(
        countInForSong(const ReferenceTrack(
          projectId: 'song',
          fileId: 'file',
          storagePath: 'room/song/reference.m4a',
          displayName: 'Weathervane.m4a',
          state: SongAnalysisState.ready,
          downbeatsMs: downbeats,
        )),
        isNull,
        reason: 'downbeats without a tempo cannot say how long a bar lasts',
      );
    });
  });

  group('the count hands over on a downbeat', () {
    test('the bar a moment is sitting inside', () {
      expect(downbeatAtOrBefore(0, downbeats), 0);
      expect(downbeatAtOrBefore(4300, downbeats), 4000);
      expect(downbeatAtOrBefore(3999, downbeats), 2000);
      expect(downbeatAtOrBefore(99000, downbeats), 14000);
      // A pickup, or a song that starts a moment before its own one, has no
      // earlier bar to be taken from.
      expect(downbeatAtOrBefore(200, <int>[500, 2500]), isNull);
      expect(downbeatAtOrBefore(200, const <int>[]), isNull);
    });
  });

  group('on the screen', () {
    final project = SongProject(
      id: 'song-count',
      roomId: 'room',
      accountId: 'account',
      title: 'Weathervane',
      createdAt: day,
      updatedAt: day,
      contributions: <Contribution>[
        Contribution(
          id: 'line-1',
          projectId: 'song-count',
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

    const onTheBeat = SongAnalysisBundle(
      reference: ReferenceTrack(
        projectId: 'song-count',
        fileId: 'file',
        storagePath: 'room/song-count/reference.m4a',
        displayName: 'Weathervane.m4a',
        state: SongAnalysisState.ready,
        durationMs: 16000,
        bpm: 120,
        beatsPerBar: 4,
        downbeatsMs: downbeats,
        transcriptText: 'turning in the wind',
        transcriptWords: words,
      ),
      lyricCues: <LyricSyncCue>[],
      chordCues: <ChordCue>[],
    );

    const noBeat = SongAnalysisBundle(
      reference: ReferenceTrack(
        projectId: 'song-count',
        fileId: 'file',
        storagePath: 'room/song-count/reference.m4a',
        displayName: 'Weathervane.m4a',
        state: SongAnalysisState.ready,
        durationMs: 16000,
        transcriptText: 'turning in the wind',
        transcriptWords: words,
      ),
      lyricCues: <LyricSyncCue>[],
      chordCues: <ChordCue>[],
    );

    Future<void> sized(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'live_countdown_enabled': true,
        'live_countdown_seconds': 5,
      });
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    Finder inCount(Finder matching) => find.descendant(
          of: find.byKey(const Key('live_count_in')),
          matching: matching,
        );

    /// Where the song is sitting, as the seek bar has it: the only place on
    /// this screen that says so, and the song is sixteen seconds long.
    double where(WidgetTester tester) =>
        tester.widget<Slider>(find.byKey(const Key('live_seek'))).value;

    /// Every tick the phone was asked to make, so the count can be felt with
    /// the phone on a stand and both eyes on the instrument.
    List<Object?> ticksFelt(WidgetTester tester) {
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

    testWidgets('four beats of the song, then the song', (tester) async {
      await sized(tester);
      final felt = ticksFelt(tester);
      final click = _SilentClick();
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project,
          analysis: onTheBeat,
          click: click,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_play_pause')));
      await tester.pump();

      // One bar of the song's own click, played once rather than looped.
      expect(click.log, <String>['play 120/4 x1']);
      // Four dots, the first of them lit, and the song not moving yet.
      expect(inCount(find.text('1')), findsOneWidget);
      expect(find.byKey(const Key('live_count_in_dot_4')), findsOneWidget);
      expect(find.byKey(const Key('live_count_in_dot_5')), findsNothing);
      expect(find.text('Counting you in — tap to skip'), findsOneWidget);
      expect(find.text('Start'), findsOneWidget);

      // A beat is half a second at 120.
      await tester.pump(const Duration(milliseconds: 500));
      expect(inCount(find.text('2')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1000));
      expect(inCount(find.text('4')), findsOneWidget);
      expect(find.text('Start'), findsOneWidget);

      // The beat after the fourth is the song's own first beat: one whole bar
      // after the count started, not a beat early on top of the four.
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('live_count_in')), findsNothing);
      expect(find.text('Pause'), findsOneWidget);

      // Felt as well as seen and heard: one light tick per beat counted, and
      // none once the song is playing.
      expect(felt, <Object?>[
        'HapticFeedbackType.selectionClick',
        'HapticFeedbackType.selectionClick',
        'HapticFeedbackType.selectionClick',
        'HapticFeedbackType.selectionClick',
      ]);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(click.log.last, 'dispose');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a song with no beat still counts in seconds', (tester) async {
      await sized(tester);
      final click = _SilentClick();
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project,
          analysis: noBeat,
          click: click,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_play_pause')));
      await tester.pump();

      expect(inCount(find.text('5')), findsOneWidget);
      expect(find.text('Get ready — tap to skip'), findsOneWidget);
      // No beats to click, so nothing was asked of the click at all.
      expect(click.log, isEmpty);
      expect(find.byKey(const Key('live_count_in_dot_1')), findsNothing);

      await tester.pump(const Duration(seconds: 1));
      expect(inCount(find.text('4')), findsOneWidget);

      // Tapping the scrim skips the rest of it, as it always has.
      await tester.tap(find.byKey(const Key('live_count_in')));
      await tester.pump();
      expect(find.byKey(const Key('live_count_in')), findsNothing);
      expect(find.text('Start'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping the count stops it, and the song stays put', (tester) async {
      await sized(tester);
      final click = _SilentClick();
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project,
          analysis: onTheBeat,
          click: click,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_play_pause')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(inCount(find.text('2')), findsOneWidget);

      await tester.tap(find.byKey(const Key('live_count_in')));
      await tester.pump();
      expect(find.byKey(const Key('live_count_in')), findsNothing);
      expect(click.log.last, 'stop');
      expect(find.text('Start'), findsOneWidget);

      // And the beats that were left do not arrive after it.
      await tester.pump(const Duration(seconds: 2));
      expect(find.byKey(const Key('live_count_in')), findsNothing);
      expect(find.text('Start'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('the bar is on screen from the press, not from the first beat',
        (tester) async {
      await sized(tester);
      final click = _SlowClick();
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project,
          analysis: onTheBeat,
          click: click,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_play_pause')));
      await tester.pump();

      // The click file is still being written. The bar is already there with
      // none of it counted yet — a screen that looks untouched while it is
      // busy is a screen you press a second time, and the second press would
      // throw away the count nobody could see had started.
      expect(find.byKey(const Key('live_count_in')), findsOneWidget);
      expect(find.byKey(const Key('live_count_in_dot_4')), findsOneWidget);
      expect(find.byKey(const Key('live_count_in_dot_5')), findsNothing);
      expect(find.text('Counting you in — tap to skip'), findsOneWidget);
      // And no beat number yet, least of all a nought.
      expect(inCount(find.text('0')), findsNothing);
      expect(inCount(find.text('1')), findsNothing);

      click.written.complete();
      await tester.pump();
      expect(inCount(find.text('1')), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 2000));
      expect(find.byKey(const Key('live_count_in')), findsNothing);
      expect(find.text('Pause'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('coming back mid-song, the song comes in on its own bar',
        (tester) async {
      await sized(tester);
      final click = _SilentClick();
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(
          project: project,
          analysis: onTheBeat,
          click: click,
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      // Stopped five seconds in, which is a second into the third bar.
      tester.widget<Slider>(find.byKey(const Key('live_seek'))).onChanged!(
            5000 / 16000,
          );
      await tester.pump();
      expect(where(tester), closeTo(5000 / 16000, 0.001));

      await tester.tap(find.byKey(const Key('live_play_pause')));
      await tester.pump();

      // The song is taken from the top of that bar before a beat is counted.
      // Four beats at the song's tempo handing over a second into a bar are
      // in the right time and the wrong place: the player is counted to four
      // and the song arrives between two of its own beats.
      expect(where(tester), closeTo(4000 / 16000, 0.001));
      expect(inCount(find.text('1')), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 2000));
      expect(find.byKey(const Key('live_count_in')), findsNothing);
      expect(find.text('Pause'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('the settings sheet offers seconds only where they mean something',
        (tester) async {
      await sized(tester);
      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(project: project, analysis: onTheBeat),
      ));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byKey(const Key('live_countdown_settings')));
      await tester.pumpAndSettle();
      expect(find.textContaining('counted in one bar of it'), findsOneWidget);
      expect(find.text('5 sec'), findsNothing);

      await tester.tapAt(const Offset(200, 20));
      await tester.pumpAndSettle();

      await tester.pumpWidget(MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: LivePerformanceScreen(project: project, analysis: noBeat),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const Key('live_countdown_settings')));
      await tester.pumpAndSettle();
      expect(find.text('5 sec'), findsOneWidget);
      expect(find.textContaining('counted in one bar of it'), findsNothing);

      await tester.tapAt(const Offset(200, 20));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
