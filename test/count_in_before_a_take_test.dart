import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/layers/take_count_in.dart';
import 'package:colabroom/features/workspace/count_in.dart';
import 'package:colabroom/services/click_player.dart';
import 'package:colabroom/services/multitrack.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Count in before you record a take.
///
/// Perform has counted a band in on the song's own bar since #363, and a
/// punched-in take still started cold: the song simply arrived, at full
/// speed, with a part expected on top of it (Every Musician, Same Song,
/// 17 September 2026). Now one bar is counted first and the song comes back
/// in on its own downbeat.
///
/// The takes screen's recorder is a plugin, so none of this can be reached by
/// pressing the button in a test. What is here instead is every number the
/// button now depends on: which takes are counted, where they land, when the
/// song comes in, and how much comes off the front of the recording
/// afterwards. Whether a phone really does it is the device checks in the
/// pull request, and nothing below should be read as having proved those.

/// A click that says what it was asked for, and takes [startsAfter] to start.
class _Click implements ClickPlayer {
  _Click({this.startsAfter = Duration.zero, this.broken = false});

  final Duration startsAfter;
  final bool broken;
  final List<String> log = <String>[];

  @override
  Future<void> play({
    required double bpm,
    required int beatsPerBar,
    int bars = 8,
    bool loop = true,
  }) async {
    log.add('play ${bpm.round()}/$beatsPerBar x$bars${loop ? ' looped' : ''}');
    if (startsAfter > Duration.zero) {
      await Future<void>.delayed(startsAfter);
    }
    if (broken) throw StateError('no audio on this phone');
  }

  @override
  Future<void> stop() async => log.add('stop');

  @override
  Future<void> dispose() async => log.add('dispose');
}

ReferenceTrack _song({
  double? bpm = 120,
  int? beatsPerBar = 4,
  List<int> downbeatsMs = const <int>[],
}) {
  return ReferenceTrack(
    projectId: 'project-1',
    fileId: 'file-1',
    storagePath: 'room-1/project-1/analysis/reference.m4a',
    displayName: 'The recording',
    state: SongAnalysisState.ready,
    bpm: bpm,
    beatsPerBar: beatsPerBar,
    downbeatsMs: downbeatsMs,
  );
}

/// Bars of two seconds from half a second in: 120bpm in four, with the half
/// second of room a real recording has before its first downbeat.
List<int> _bars(int count) =>
    <int>[for (var bar = 0; bar < count; bar += 1) 500 + bar * 2000];

const int _rate = Multitrack.rate;

int _at(int ms) => (ms * _rate / 1000).round();

/// A pick or a stick: a sharp attack decaying away.
void _strike(Float64List into, int atMs, {double level = 1}) {
  final at = _at(atMs);
  for (var i = 0; i < 900 && at + i < into.length; i += 1) {
    into[at + i] += level * math.exp(-i / 220.0) * math.sin(i * 0.22);
  }
}

/// What the microphone hears of a take that was counted in.
///
/// [headStartMs] of room, then a bar of the metronome's own click out of the
/// speaker, then a part struck on every beat from the downbeat on -- all of it
/// [lateMs] behind, because a phone records a moment after it plays.
Float64List _countedTake({
  required int headStartMs,
  required int countedMs,
  required int lateMs,
}) {
  final samples = Float64List(_at(headStartMs + countedMs + 6000));
  final click = Multitrack.click(bpm: 120, lengthSamples: _at(2000));
  final clickFrom = _at(headStartMs + (countedMs - 2000) + lateMs);
  for (var i = 0; i < click.length; i += 1) {
    samples[clickFrom + i] += click[i];
  }
  for (var beat = 0; beat < 11; beat += 1) {
    _strike(samples, headStartMs + countedMs + lateMs + beat * 500);
  }
  return samples;
}

/// The song's beats around a punch-in at 1:40.5, measured from the top.
List<int> _beatsAround(int punchInMs) => <int>[
      for (var beat = -8; beat < 16; beat += 1) punchInMs + beat * 500,
    ];

void main() {
  group('which takes are counted in', () {
    test('a punch-in lands on the top of the bar it was pressed in', () {
      // Pressed at 0:07.3, which is most of the way through the bar that
      // starts at 0:06.5. The take lands there, and the bar counted is the
      // song's own: four beats at 120.
      final countIn = takeCountInFor(
        _song(downbeatsMs: _bars(8)),
        punchInMs: 7300,
      );

      expect(countIn, isNotNull);
      expect(countIn!.downbeatMs, 6500);
      expect(countIn.bar.beats, 4);
      expect(countIn.bar.length, const Duration(seconds: 2));
    });

    test('a punch-in pressed exactly on a downbeat stays on it', () {
      final countIn = takeCountInFor(
        _song(downbeatsMs: _bars(8)),
        punchInMs: 4500,
      );

      expect(countIn!.downbeatMs, 4500);
    });

    test('a waltz is counted in three', () {
      final countIn = takeCountInFor(
        _song(
          bpm: 90,
          beatsPerBar: 3,
          downbeatsMs: <int>[0, 2000, 4000, 6000],
        ),
        punchInMs: 4100,
      );

      expect(countIn!.bar.beats, 3);
      // Three beats of two thirds of a second, to the millisecond.
      expect(countIn.bar.length.inMilliseconds, 2000);
    });

    test('a song without beats starts as before', () {
      // No analysis at all, a tempo with no downbeats, downbeats with no
      // tempo, and a tempo no beat can be: none of them is counted, which
      // leaves the screen on the start it has always had.
      expect(takeCountInFor(null, punchInMs: 7300), isNull);
      expect(takeCountInFor(_song(), punchInMs: 7300), isNull);
      expect(
        takeCountInFor(
          _song(bpm: null, downbeatsMs: _bars(8)),
          punchInMs: 7300,
        ),
        isNull,
      );
      expect(
        takeCountInFor(
          _song(bpm: 260, downbeatsMs: _bars(8)),
          punchInMs: 7300,
        ),
        isNull,
      );
    });

    test('a take from the top starts as it always has', () {
      expect(
        takeCountInFor(_song(downbeatsMs: _bars(8)), punchInMs: 0),
        isNull,
      );
    });

    test('a playhead ahead of the first downbeat has no bar to come in from',
        () {
      expect(
        takeCountInFor(_song(downbeatsMs: _bars(8)), punchInMs: 300),
        isNull,
      );
    });

    test('one dropped downbeat is stepped over, an outro is not', () {
      // The tracker lost the downbeat at 0:04.5, so the playhead at 0:05.9
      // sits 3.4 seconds after the last one it found. Still counted: the bar
      // is in tempo, there is simply a line missing.
      final dropped = <int>[500, 2500, 6500, 8500];
      expect(
        takeCountInFor(_song(downbeatsMs: dropped), punchInMs: 5900)!
            .downbeatMs,
        2500,
      );
      // Twenty seconds after the last bar the analysis found. Nothing there
      // to be counted into, and nobody asked to be moved back that far.
      expect(
        takeCountInFor(_song(downbeatsMs: _bars(4)), punchInMs: 26500),
        isNull,
      );
    });
  });

  group('the bar before the take', () {
    // testWidgets for its clock, not for a widget: time here only moves when
    // the test says so, and the count is handed that clock to measure with.
    Duration Function() clockOf(WidgetTester tester) {
      final began = tester.binding.clock.now();
      return () => tester.binding.clock.now().difference(began);
    }

    const bar = CountIn(beats: 4, bpm: 120);

    testWidgets('the recording starts on the downbeat after one bar',
        (tester) async {
      final now = clockOf(tester);
      final click = _Click();
      final beats = <String>[];
      Duration? cameInAt;
      Duration? counted;

      unawaited(countInATake(
        bar: bar,
        click: click,
        clock: now,
        onBeat: (beat) => beats.add('$beat at ${now().inMilliseconds}'),
      ).then((value) {
        counted = value;
        cameInAt = now();
      }));

      await tester.pump();
      // One bar of the metronome's click, played once.
      expect(click.log, <String>['play 120/4 x1']);
      expect(beats, <String>['1 at 0']);

      await tester.pump(const Duration(milliseconds: 1999));
      expect(beats, <String>['1 at 0', '2 at 500', '3 at 1000', '4 at 1500']);
      // Not on the last beat counted. The song's downbeat is the beat after.
      expect(cameInAt, isNull);

      await tester.pump(const Duration(milliseconds: 1));
      expect(cameInAt, const Duration(seconds: 2));
      expect(counted, const Duration(seconds: 2));
    });

    testWidgets('the time the click took to start is part of what was counted',
        (tester) async {
      // A cold click is a file being written and a player being opened. The
      // recorder is running through all of it, so all of it is on the front
      // of the take -- and the bar is still a whole bar from the first click.
      final now = clockOf(tester);
      final click = _Click(startsAfter: const Duration(milliseconds: 180));
      final beats = <String>[];
      Duration? counted;

      unawaited(countInATake(
        bar: bar,
        click: click,
        clock: now,
        onBeat: (beat) => beats.add('$beat at ${now().inMilliseconds}'),
      ).then((value) => counted = value));

      await tester.pump(const Duration(milliseconds: 2179));
      expect(
        beats,
        <String>['1 at 180', '2 at 680', '3 at 1180', '4 at 1680'],
      );
      expect(counted, isNull);

      await tester.pump(const Duration(milliseconds: 1));
      expect(counted, const Duration(milliseconds: 2180));
    });

    testWidgets('a click that will not play is a silent count, not a failed take',
        (tester) async {
      final now = clockOf(tester);
      final beats = <int>[];
      Duration? counted;

      unawaited(countInATake(
        bar: bar,
        click: _Click(broken: true),
        clock: now,
        onBeat: beats.add,
      ).then((value) => counted = value));

      await tester.pump(const Duration(seconds: 2));
      expect(beats, <int>[1, 2, 3, 4]);
      expect(counted, const Duration(seconds: 2));
    });

    testWidgets('a screen that went away mid-count brings no song in',
        (tester) async {
      final now = clockOf(tester);
      final beats = <int>[];
      var here = true;
      var finished = false;
      Duration? counted;

      unawaited(countInATake(
        bar: bar,
        click: _Click(),
        clock: now,
        stillWanted: () => here,
        onBeat: beats.add,
      ).then((value) {
        counted = value;
        finished = true;
      }));

      await tester.pump(const Duration(milliseconds: 600));
      expect(beats, <int>[1, 2]);
      here = false;
      await tester.pump(const Duration(seconds: 2));

      expect(beats, <int>[1, 2]);
      expect(finished, isTrue);
      expect(counted, isNull);
    });
  });

  group("the take's offset accounts for the count", () {
    const recorderMs = 300;

    test('the front of a take is the head start and then the bar', () {
      // Recorded dry: nothing was playing, so nothing to be early against.
      expect(
        takeHeadStartMs(
          backingWasPlaying: false,
          recorderMs: recorderMs,
          counted: const Duration(seconds: 2),
        ),
        0,
      );
      // Played along, not counted in: exactly what it has always been.
      expect(
        takeHeadStartMs(backingWasPlaying: true, recorderMs: recorderMs),
        300,
      );
      // Counted in, by what the count measured rather than by what a bar is
      // on paper.
      expect(
        takeHeadStartMs(
          backingWasPlaying: true,
          recorderMs: recorderMs,
          counted: const Duration(milliseconds: 2180),
        ),
        2480,
      );
    });

    test('a counted take is trimmed back to the downbeat it was counted into',
        () {
      const punchInMs = 100500;
      final trim = trimForTake(
        _countedTake(headStartMs: recorderMs, countedMs: 2180, lateMs: 120),
        headStartMs: recorderMs + 2180,
        manualMs: 0,
        beatsMs: _beatsAround(punchInMs),
        punchedInAtMs: punchInMs,
      );

      expect(trim.measured, isTrue);
      // The head start, the bar, and the phone's own lateness -- to the
      // nearest hop of the aligner, not to the sample.
      expect((trim.ms - (300 + 2180 + 120)).abs(), lessThan(30));
    });

    test('a head start that forgot the count would leave the take a bar late',
        () {
      // Why the count is threaded through all three places. The clicks come
      // through the microphone exactly on the grid, so an aligner allowed to
      // hear them is perfectly happy: it reports a trustworthy answer that is
      // a whole bar short, and the take plays back late with four clicks on
      // the front of it. Nothing about that result looks wrong from inside.
      const punchInMs = 100500;
      final trim = trimForTake(
        _countedTake(headStartMs: recorderMs, countedMs: 2000, lateMs: 120),
        headStartMs: recorderMs,
        manualMs: 0,
        beatsMs: _beatsAround(punchInMs),
        punchedInAtMs: punchInMs,
      );

      expect(trim.measured, isTrue);
      expect((trim.ms - (300 + 120)).abs(), lessThan(30));
    });

    test('a part the aligner cannot time still loses the count', () {
      // A held note gives the arithmetic nothing to bite on, so the hand-set
      // value stands -- on top of the head start and the bar, which are known
      // whether or not anything could be measured.
      final held = Float64List(_at(300 + 2000 + 6000));
      for (var i = _at(2300); i < held.length; i += 1) {
        held[i] = 0.3 * math.sin(i * 0.05);
      }
      final trim = trimForTake(
        held,
        headStartMs: 2300,
        manualMs: 40,
        beatsMs: _beatsAround(100500),
        punchedInAtMs: 100500,
      );

      expect(trim.measured, isFalse);
      expect(trim.ms, 2340);
    });

    test('a take that was not counted in is trimmed exactly as before', () {
      final samples = Float64List(_at(300 + 6000));
      for (var beat = 0; beat < 11; beat += 1) {
        _strike(samples, 300 + 120 + beat * 500);
      }
      final trim = trimForTake(
        samples,
        headStartMs: 300,
        manualMs: 0,
        beatsMs: <int>[for (var beat = 0; beat < 12; beat += 1) beat * 500],
        punchedInAtMs: 0,
      );

      expect(trim.measured, isTrue);
      expect((trim.ms - 420).abs(), lessThan(30));
    });

    test('the timing buttons move a counted take by what they say', () {
      // They used to stop at a second, which is less than any counted take's
      // trim: the first press would have pulled 2,420 down to 1,000.
      expect(nudgedTrimMs(2420, 10), 2430);
      expect(nudgedTrimMs(2420, -10), 2410);
      expect(nudgedTrimMs(4, -10), 0);
    });

    test("a take's shape starts where the take does, not at the count", () {
      // Two seconds of loud count, then a quiet part. The mix throws the
      // count away, so the lane must not draw it as the first thing played.
      final samples = Float64List(_at(4000));
      for (var i = 0; i < _at(2000); i += 1) {
        samples[i] = 0.9;
      }
      for (var i = _at(2000); i < samples.length; i += 1) {
        samples[i] = 0.1;
      }

      final heard = Multitrack.afterTrim(samples, 2000);
      expect(heard.length, _at(2000));
      expect(Multitrack.envelope(heard, buckets: 8).first, closeTo(0.1, 1e-9));
      // No trim, no change; and a trim past the end is nothing, which is
      // what the mix hears of such a take too.
      expect(identical(Multitrack.afterTrim(samples, 0), samples), isTrue);
      expect(Multitrack.afterTrim(samples, 5000), isEmpty);
    });
  });

  group('the bar on screen', () {
    Widget over(Widget scrim, {VoidCallback? onUnder}) {
      return MaterialApp(
        home: Scaffold(
          body: Stack(
            children: <Widget>[
              Center(
                child: TextButton(
                  onPressed: onUnder,
                  child: const Text('A lane underneath'),
                ),
              ),
              Positioned.fill(child: scrim),
            ],
          ),
        ),
      );
    }

    testWidgets('the bar is up before its first beat', (tester) async {
      await tester.pumpWidget(
        over(const TakeCountInScrim(beats: 4, beat: 0)),
      );

      expect(find.text('Counting you in'), findsOneWidget);
      expect(find.byKey(const Key('take_count_in_beat')), findsNothing);
      for (var dot = 1; dot <= 4; dot += 1) {
        expect(find.byKey(Key('take_count_in_dot_$dot')), findsOneWidget);
      }
    });

    testWidgets('it shows the beat being counted, in the bar the song is in',
        (tester) async {
      await tester.pumpWidget(
        over(const TakeCountInScrim(beats: 3, beat: 2)),
      );

      expect(find.text('2'), findsOneWidget);
      expect(find.byKey(const Key('take_count_in_dot_3')), findsOneWidget);
      expect(find.byKey(const Key('take_count_in_dot_4')), findsNothing);
      // The beat being counted is the big dot.
      expect(
        tester.getSize(find.byKey(const Key('take_count_in_dot_2'))).width,
        greaterThan(
          tester.getSize(find.byKey(const Key('take_count_in_dot_1'))).width,
        ),
      );
    });

    testWidgets('nothing under it can be touched while the bar is counted',
        (tester) async {
      // The song is sitting on the downbeat by now. A scrub under the count
      // would move it somewhere the count is not counting into.
      var touched = false;
      await tester.pumpWidget(over(
        const TakeCountInScrim(beats: 4, beat: 1),
        onUnder: () => touched = true,
      ));

      await tester.tap(find.text('A lane underneath'), warnIfMissed: false);
      await tester.pump();

      expect(touched, isFalse);
    });
  });
}
