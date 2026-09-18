import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/song_analysis_models.dart';
import '../../services/click_player.dart';
import '../../services/multitrack.dart';
import '../../services/onset_align.dart';
import '../workspace/count_in.dart';

/// Counting somebody in before they record over a place in the song.
///
/// Perform has counted a band in on the song's own bar since #363, and a take
/// still started cold: press the button at 1:40 and the song is simply there,
/// at full speed, with a part expected on top of it. Nobody punches in like
/// that in a room. They are counted in, and they come in on the one (Every
/// Musician, Same Song, 17 September 2026).
///
/// Kept out of the screen for the reason count_in.dart is, and one more. The
/// takes screen cannot be driven by a test at all -- its recorder is a plugin
/// -- and every number in here decides where somebody's playing lands in the
/// song. A wrong one is a take that uploads cleanly and sits a bar late, which
/// is the kind of failure this screen has already paid for three times.

/// One bar counted before a take, and the downbeat it hands over on.
class TakeCountIn {
  const TakeCountIn({required this.bar, required this.downbeatMs});

  /// The bar that is counted: the song's own beats at the song's own tempo,
  /// the same arithmetic and the same click Perform counts with.
  final CountIn bar;

  /// Where the take lands, measured from the top of the song.
  ///
  /// The top of the bar the playhead was sitting in, not the playhead. A bar
  /// counted at the song's tempo is only a count-in if the song comes back in
  /// on one of its own downbeats, which is what anybody in a room says out
  /// loud anyway: from the top of the bar.
  final int downbeatMs;
}

/// The count-in for a take punched in at [punchInMs], or null when the take
/// starts the way it always has.
///
/// Null for a take from the top. A recording's first downbeat is almost never
/// at zero -- an intro, half a second of room -- so there is no bar before the
/// top to count, and the song would have to start sounding part way through
/// one. Punching in is where starting cold hurts, and it is what was asked
/// for.
///
/// Null without a tempo and downbeats, for the reason [countInFor] gives: a
/// bar counted at a guessed tempo is confidently wrong in a way nobody in the
/// room can see. Those songs keep today's start.
///
/// Null ahead of the first downbeat, where there is no earlier bar to come in
/// from. And null more than two bars past the last downbeat the analysis
/// found before the playhead: two steps over a single downbeat the tracker
/// dropped, the same allowance [beatsInBar] makes, but an outro the tracker
/// gave up on has no bar to be counted into, and moving somebody's punch-in
/// back by ten seconds to find one is not what they pressed.
TakeCountIn? takeCountInFor(
  ReferenceTrack? reference, {
  required int punchInMs,
}) {
  if (reference == null || punchInMs <= 0) return null;
  final bar = countInForSong(reference);
  if (bar == null) return null;
  final downbeat = downbeatAtOrBefore(punchInMs, reference.downbeatsMs);
  if (downbeat == null) return null;
  if (punchInMs - downbeat > bar.length.inMilliseconds * 2) return null;
  return TakeCountIn(bar: bar, downbeatMs: downbeat);
}

/// Counts [bar] once, and answers how long that really took -- from the
/// moment it was asked to the downbeat the song comes in on.
///
/// Measured rather than assumed, because the answer goes into the take's
/// trim. The recorder is already running while this counts (it has to be: an
/// encoder asked to start while something is playing never starts at all,
/// which is what the head start in the takes screen is for), so everything
/// from here to the downbeat is on the front of the recording and has to come
/// off it again. A bar is two seconds on paper. On a phone it is two seconds
/// plus however long the click took to start, and the aligner that tidies up
/// afterwards only looks half a beat ahead: an assumed length would spend
/// that window on the click's start-up and leave nothing for the latency it
/// exists to find.
///
/// The bar is counted from when the click's play call comes back, which is
/// as near as a phone will say to when the first click sounded. Each beat is
/// then waited for against [clock] rather than a beat after the last one, so
/// a late timer makes one dot late and the downbeat is still on time.
///
/// A click that will not play is a silent count, not a failed take: the bar
/// is still seen and felt, the same answer Perform gives.
///
/// Null when [stillWanted] says nobody is waiting any more -- the screen went
/// away mid-count -- so the caller does not bring a song in for nobody.
Future<Duration?> countInATake({
  required CountIn bar,
  required ClickPlayer click,
  required void Function(int beat) onBeat,
  bool Function()? stillWanted,
  Duration Function()? clock,
}) async {
  final now = clock ?? _stopwatch();
  final wanted = stillWanted ?? () => true;
  final asked = now();
  try {
    await click.play(
      bpm: bar.bpm,
      beatsPerBar: bar.beats,
      bars: 1,
      loop: false,
    );
  } catch (_) {
    // No click on this phone. Counted anyway, seen and felt.
  }
  final first = now();
  for (var beat = 1; beat <= bar.beats; beat += 1) {
    await _waitUntil(first + countInBeatAt(bar, beat), now);
    if (!wanted()) return null;
    onBeat(beat);
  }
  await _waitUntil(first + bar.length, now);
  if (!wanted()) return null;
  return now() - asked;
}

Future<void> _waitUntil(Duration due, Duration Function() now) async {
  final wait = due - now();
  if (wait > Duration.zero) await Future<void>.delayed(wait);
}

Duration Function() _stopwatch() {
  final watch = Stopwatch()..start();
  return () => watch.elapsed;
}

/// How much of the front of a take is the room before the song.
///
/// A take that played along began recording before the music did: the
/// recorder's own head start, and then the bar that was [counted], if one
/// was. Nothing when nothing was playing, because a take recorded dry has no
/// song to be early against.
int takeHeadStartMs({
  required bool backingWasPlaying,
  required int recorderMs,
  Duration counted = Duration.zero,
}) =>
    backingWasPlaying ? recorderMs + counted.inMilliseconds : 0;

/// How much to take off the front of a take, and whether that was measured.
class TakeTrim {
  const TakeTrim({required this.ms, required this.measured});

  /// The trim, in milliseconds. This is [Take.offsetMs].
  final int ms;

  /// False when the aligner could not answer and the hand-set value stands.
  final bool measured;
}

/// The trim for a take just recorded.
///
/// [headStartMs] is known, not measured by listening: see [takeHeadStartMs].
/// It appears three times below and all three have to agree, which is why
/// they are in one place. It is added to the hand-set value, because a take
/// the aligner cannot time is still that much older than the music. It is
/// skipped before the aligner listens. And it is added back to whatever the
/// aligner finds.
///
/// The skip matters more than it sounds. alignToGrid searches at most half a
/// beat, because a beat grid repeats and searching further lets a take snap a
/// whole beat late and call itself aligned. At 120bpm half a beat is 250ms --
/// less than the recorder's head start alone. Handing it the untrimmed take
/// would put the true answer outside the only window it is allowed to look
/// in. With a count-in it matters again: a bar of clicks through the
/// microphone is four loud attacks exactly on the grid, and an aligner that
/// heard them would lock onto the count and leave the take a bar late with
/// the clicks still in it.
///
/// [beatsMs] are measured from the top of the song and are re-based onto
/// [punchedInAtMs] here. A take punched in at 2:40 hears its first downbeat a
/// few hundred milliseconds in, not two minutes and forty seconds in --
/// handing the aligner the song's absolute grid would put every candidate
/// shift far outside the half-beat window, and it would decline to answer on
/// a take it could have timed perfectly.
TakeTrim trimForTake(
  Float64List samples, {
  required int headStartMs,
  required int manualMs,
  required List<int> beatsMs,
  required int punchedInAtMs,
}) {
  final manual = TakeTrim(ms: headStartMs + manualMs, measured: false);

  var beats = beatsMs;
  if (punchedInAtMs > 0 && beats.length > 1) {
    beats = <int>[
      for (final at in beats)
        if (at >= punchedInAtMs) at - punchedInAtMs,
    ];
  }
  if (beats.length < 2) return manual;

  final skip = (headStartMs * Multitrack.rate / 1000).round();
  if (skip >= samples.length) return manual;
  final afterHeadStart =
      skip == 0 ? samples : Float64List.sublistView(samples, skip);

  final result = OnsetAlign.alignToGrid(
    afterHeadStart,
    beats,
    rate: Multitrack.rate,
  );
  if (result == null || !result.trustworthy) return manual;
  return TakeTrim(ms: headStartMs + result.shiftMs, measured: true);
}

/// A take's trim after one press of the timing buttons.
///
/// Never below nothing. It used to stop at a second as well, which was
/// further than any phone is late -- and is less than the trim of any take
/// that was counted in, since the bar is part of it. The first press on one
/// of those would have pulled 2,400 ms down to 1,000: a take a second and a
/// half late, with the count audible at the front of it.
int nudgedTrimMs(int currentMs, int deltaMs) =>
    math.max(0, currentMs + deltaMs);

/// The bar being counted, over the takes while it lasts.
///
/// The same picture Perform draws -- a number that snaps rather than swells,
/// and a dot for each beat -- because it is the same count, and a second
/// look for it would be a second thing to learn. Big enough to read from a
/// phone on a music stand, which is where it is in the bar before a take.
///
/// It covers the lanes and takes every touch. The song has been cued to the
/// downbeat by the time this is up, and a scrub underneath it would move the
/// song somewhere the count is not counting into.
class TakeCountInScrim extends StatelessWidget {
  const TakeCountInScrim({required this.beats, required this.beat, super.key});

  /// Beats in the bar.
  final int beats;

  /// The beat being counted. Zero is the moment before the first one sounds:
  /// the bar is there to be seen and none of it has happened yet.
  final int beat;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: Container(
        color: const Color(0xFF01050C).withValues(alpha: 0.82),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // The empty box keeps the bar's height before the first beat, so
            // the dots do not jump down the screen when the number arrives.
            if (beat < 1)
              const SizedBox(height: 96)
            else
              Text(
                '$beat',
                key: const Key('take_count_in_beat'),
                style: const TextStyle(
                  color: AppColors.gold,
                  fontSize: 96,
                  fontWeight: FontWeight.w900,
                  height: 1,
                ),
              ),
            const SizedBox(height: 16),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (var dot = 1; dot <= beats; dot += 1)
                  Container(
                    key: Key('take_count_in_dot_$dot'),
                    width: dot == beat ? 17 : 11,
                    height: dot == beat ? 17 : 11,
                    margin: const EdgeInsets.symmetric(horizontal: 7),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: dot == beat
                          ? AppColors.gold
                          : dot < beat
                              ? AppColors.gold.withValues(alpha: 0.35)
                              : Colors.white.withValues(alpha: 0.18),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            const Text(
              'Counting you in',
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
