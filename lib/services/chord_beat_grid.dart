import 'dart:math' as math;

import '../domain/song_analysis_models.dart';
import '../domain/song_cycle.dart';

/// Putting the chord map back on the song's grid.
///
/// ChordMini reports boundaries to the analysis frame — 1.847s, 3.712s —
/// which is close to right and never exactly right. A musician reading the
/// chart sees a change land a fraction before the downbeat; the app
/// highlighting chords against the playing recording flickers the previous
/// chord for a moment after the bar has already turned. Both are the same
/// problem: the chord map is measured in seconds and the song is measured in
/// beats.
///
/// Beat tracking (migration 0023) supplies the grid. This is what puts the
/// chords on it.

/// How far from a beat a chord change can fall and still be understood as
/// meant for it, as a fraction of one beat.
///
/// Not a half. Every possible moment is within half a beat of some beat, so a
/// window of 0.5 would snap everything and this parameter would mean nothing.
/// At roughly a third, the detector's own error — which is frame-sized, well
/// under a tenth of a second — is comfortably inside the window, while a
/// change sitting near the midpoint between two beats is left alone. That
/// midpoint is where an eighth-note push lives, and a push is something a
/// musician played on purpose.
const double defaultSnapWindow = 0.35;

/// The typical gap between beats, in milliseconds, or 0 without enough beats
/// to tell.
///
/// Median rather than mean so one beat the tracker dropped — which shows up
/// as a single gap of twice the length — doesn't stretch the tolerance for
/// the whole song.
int medianBeatIntervalMs(List<int> beatsMs) {
  if (beatsMs.length < 2) return 0;
  final gaps = <int>[
    for (var i = 1; i < beatsMs.length; i += 1) beatsMs[i] - beatsMs[i - 1],
  ]..sort();
  return gaps[gaps.length ~/ 2];
}

/// Index of the value in [sorted] closest to [ms], or -1 when empty.
/// Ties go to the earlier one: a chord change exactly between two beats
/// belongs to the beat it was already sounding on.
int _nearestIndex(int ms, List<int> sorted) {
  if (sorted.isEmpty) return -1;
  if (ms <= sorted.first) return 0;
  if (ms >= sorted.last) return sorted.length - 1;
  var low = 0;
  var high = sorted.length - 1;
  while (low <= high) {
    final mid = (low + high) >> 1;
    if (sorted[mid] == ms) return mid;
    if (sorted[mid] < ms) {
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  // The loop ends with `high` just below ms and `low` just above it.
  return (ms - sorted[high]) <= (sorted[low] - ms) ? high : low;
}

int _snapped(int ms, List<int> beats, int toleranceMs) {
  final index = _nearestIndex(ms, beats);
  if (index < 0) return ms;
  final beat = beats[index];
  return (beat - ms).abs() <= toleranceMs ? beat : ms;
}

/// The beat a moment sits closest to, for `chord_cues.beat_index`. Null
/// without a grid to count against.
///
/// Expects [beatsMs] ascending, which is how the tracker emits it.
int? beatIndexAt(int ms, List<int> beatsMs) {
  final index = _nearestIndex(ms, beatsMs);
  return index < 0 ? null : index;
}

/// Where bar 1 sits in [downbeatsMs]: the 0-indexed place of the downbeat the
/// band counts as bar 1, clamped into the grid there actually is.
///
/// [barOne] counts from one, and one is the default — bar 1 is the first
/// downbeat, which is what this app did before anybody could say otherwise.
/// It is clamped rather than trusted because it is stored on the song and the
/// downbeats come from the recording: a re-analysis that finds a shorter grid
/// would otherwise leave a song with a bar 1 past the end of itself (Every
/// Musician, Same Song, 17 September 2026 — see migration 0161).
int barOneIndex(int barOne, int downbeatCount) =>
    downbeatCount <= 0 ? 0 : (barOne - 1).clamp(0, downbeatCount - 1).toInt();

/// How many numbered bars a grid holds once the pickup is taken off the
/// front. The bars ahead of bar 1 are the pickup and are not numbered.
int numberedBarCount(int barOne, int downbeatCount) =>
    downbeatCount <= 0 ? 0 : downbeatCount - barOneIndex(barOne, downbeatCount);

/// The 0-indexed downbeat printed bar [bar] starts on, clamped into the grid.
int downbeatIndexOfBar(int bar, int barOne, int downbeatCount) {
  if (downbeatCount <= 0) return 0;
  final first = barOneIndex(barOne, downbeatCount);
  final at = first + (bar < 1 ? 0 : bar - 1);
  return at.clamp(first, downbeatCount - 1).toInt();
}

/// The 1-indexed bar containing [ms], counting bar 1 from the [barOne]th
/// downbeat.
///
/// Null before bar 1. A pickup phrase sits ahead of it — either ahead of the
/// whole grid, or on the downbeats the band has said are a count-in — and
/// both "bar 0" and rounding it up into bar 1 would be claiming something
/// untrue about where it starts. The pickup is asked for by name instead
/// (see pickupLoop in practice_rules.dart), which is also why no bar number
/// this app prints is ever less than 1.
int? barNumberAt(int ms, List<int> downbeatsMs, {int barOne = 1}) {
  if (downbeatsMs.isEmpty) return null;
  final first = barOneIndex(barOne, downbeatsMs.length);
  if (ms < downbeatsMs[first]) return null;
  var low = first;
  var high = downbeatsMs.length - 1;
  while (low < high) {
    final mid = (low + high + 1) >> 1;
    if (downbeatsMs[mid] <= ms) {
      low = mid;
    } else {
      high = mid - 1;
    }
  }
  return low - first + 1;
}

/// The grid a song is counted on once the band has counted a cycle of its
/// own, and where cycle 1 sits in it.
///
/// A cycle replaces the analysed bars outright rather than sitting beside
/// them: a player counting in sevens has no use for a number that means four
/// beats of something else (Every Musician, Same Song, 17 September 2026,
/// decision 20). It is the same shape as the analysed grid -- a list of the
/// moments a count begins, and which of them is number 1 -- so everything
/// that names, loops or counts bars works on it unchanged.
class CycleGrid {
  const CycleGrid({required this.downbeatsMs, required this.barOne});

  /// Where each cycle begins, ascending, with whatever is played ahead of
  /// cycle 1 as one entry in front of it.
  final List<int> downbeatsMs;

  /// Which of those entries is cycle 1: two when something is played ahead
  /// of it, one when the cycle starts where the grid does.
  final int barOne;
}

/// How many beats there are from bar 1 to the end of the recording.
///
/// What a cycle has to fit inside twice over: one cycle on its own cannot be
/// counted from, because there is no second one for a count to come round
/// to, and the picker has nothing to choose a run between.
int beatsFromBarOne(
  List<int> beatsMs, {
  List<int> downbeatsMs = const <int>[],
  int barOne = 1,
}) {
  if (beatsMs.isEmpty) return 0;
  final from = downbeatsMs.isEmpty
      ? beatsMs.first
      : downbeatsMs[barOneIndex(barOne, downbeatsMs.length)];
  return beatsMs.length - _nearestIndex(from, beatsMs);
}

/// The longest cycle this song has the beats to count, or a number below
/// [SongCycle.minBeats] when it has none.
///
/// A song the beat tracker found nothing in offers no cycle at all, which is
/// the honest answer: a cycle is a count of beats, and there are none to
/// count.
int longestCycle(
  List<int> beatsMs, {
  List<int> downbeatsMs = const <int>[],
  int barOne = 1,
}) =>
    math.min(
      SongCycle.maxBeats,
      beatsFromBarOne(beatsMs, downbeatsMs: downbeatsMs, barOne: barOne) ~/ 2,
    );

/// The cycle laid over this song's beats, or null when there is no cycle or
/// no beat grid to lay it on.
///
/// Cycle 1 begins where bar 1 does -- the downbeat the band said to count
/// from (0161), or the first one the analysis found -- and every cycle after
/// it is [SongCycle.beats] beats further along the beat grid. The downbeats
/// themselves are used for nothing else: a seven laid over a recording the
/// tracker heard in fours will not land on them, and it is not supposed to.
///
/// Whatever is played ahead of cycle 1 goes in front as a single entry, the
/// way the analysed grid carries a pickup, so it can be asked for by name
/// rather than vanishing off the top of the count.
CycleGrid? cycleGridFor(
  SongCycle? cycle, {
  required List<int> beatsMs,
  List<int> downbeatsMs = const <int>[],
  int barOne = 1,
}) {
  if (cycle == null || beatsMs.isEmpty) return null;
  final from = downbeatsMs.isEmpty
      ? beatsMs.first
      : downbeatsMs[barOneIndex(barOne, downbeatsMs.length)];
  final first = _nearestIndex(from, beatsMs);
  final starts = <int>[
    for (var at = first; at < beatsMs.length; at += cycle.beats) beatsMs[at],
  ];
  // One cycle is not a count. Rather than draw a grid of one the picker
  // cannot choose a run from, the song keeps its analysed bars.
  if (starts.length < 2) return null;
  final ahead = beatsMs.first;
  if (ahead < starts.first) {
    return CycleGrid(
      downbeatsMs: List<int>.unmodifiable(<int>[ahead, ...starts]),
      barOne: 2,
    );
  }
  return CycleGrid(downbeatsMs: List<int>.unmodifiable(starts), barOne: 1);
}

/// Moves every chord change onto the nearest beat it could plausibly have
/// meant, then merges what that reveals to be one chord.
///
/// A boundary only moves if a beat is within [snapWindow] of it. Past that it
/// stays put: a chord that genuinely changes off the grid — a push, a stab
/// ahead of the bar, a rubato passage the tracker gave up on — is real music,
/// and quantizing it would be inventing a performance nobody played. This is
/// why the window is not a half beat; see [defaultSnapWindow].
///
/// Merging matters as much as snapping. Two cues 120ms apart that the model
/// labelled the same chord are one chord it briefly doubted, and once both
/// boundaries land on the same beat that becomes visible. The chart loses
/// changes that were never changes.
///
/// Returns [cues] untouched when there's no usable grid — a short or missing
/// beat list means the recording didn't give a confident answer, and guessing
/// at one is worse than leaving the chords where the model heard them.
///
/// Cues a person placed or reviewed are never moved. They're a statement
/// about where the chord goes, not a measurement to be corrected.
List<ChordCue> snapChordsToBeatGrid(
  List<ChordCue> cues,
  List<int> beatsMs, {
  double snapWindow = defaultSnapWindow,
}) {
  if (cues.isEmpty) return cues;
  final beats = List<int>.of(beatsMs)..sort();
  // Four beats is a bar. Fewer than that isn't a grid, it's a couple of
  // timestamps.
  if (beats.length < 4) return cues;
  final beatMs = medianBeatIntervalMs(beats);
  if (beatMs <= 0) return cues;
  final toleranceMs = (beatMs * snapWindow).round();

  final ordered = List<ChordCue>.of(cues)
    ..sort((a, b) => a.startMs.compareTo(b.startMs));
  final snapped = <ChordCue>[
    for (final cue in ordered)
      if (cue.isManual)
        cue
      else
        cue.copyWith(
          startMs: _snapped(cue.startMs, beats, toleranceMs),
          endMs: _snapped(cue.endMs, beats, toleranceMs),
        ),
  ];
  return _mergeAdjacent(snapped);
}

List<ChordCue> _mergeAdjacent(List<ChordCue> cues) {
  final merged = <ChordCue>[];
  for (final cue in cues) {
    // Both boundaries landed on the same beat, so the model heard a chord
    // that lasted less than a single beat. Dropping it opens no gap: the cue
    // before it already ends exactly where the one after it starts, because
    // they shared the boundary that collapsed.
    if (cue.endMs <= cue.startMs) continue;
    final previous = merged.isEmpty ? null : merged.last;
    if (previous != null &&
        !previous.isManual &&
        !cue.isManual &&
        previous.chord == cue.chord &&
        cue.startMs <= previous.endMs) {
      merged[merged.length - 1] = previous.copyWith(
        endMs: math.max(previous.endMs, cue.endMs),
        confidence: math.max(previous.confidence, cue.confidence),
      );
      continue;
    }
    merged.add(cue);
  }
  return List<ChordCue>.unmodifiable(merged);
}

/// One bar of the song and the chords that start inside it.
class ChordBar {
  const ChordBar({
    required this.number,
    required this.startMs,
    required this.endMs,
    required this.chords,
  });

  /// 1-indexed, counting from wherever the band says bar 1 is, or 0 for the
  /// pickup — everything ahead of bar 1, gathered as one, because it is one
  /// thing a player asks for rather than a run of numbered bars.
  final int number;
  final int startMs;
  final int endMs;
  final List<ChordCue> chords;
}

/// Chords grouped into the bar each one starts in — the shape a chord chart
/// is actually read in, rather than a flat run of changes.
///
/// Chords ahead of bar 1 are kept rather than dropped. A chord ringing over a
/// pickup is still a chord you play, and losing it off the top of the chart
/// would be worse than showing it early. With nothing said about where bar 1
/// is they go in bar 1, which is what this always did; once the band has said
/// the song starts a few downbeats in, they gather into the pickup instead
/// (number 0), because at that point they are a real stretch of music and
/// folding several bars of it into bar 1 would be a different kind of wrong.
///
/// Bars with no chord in them are absent, not empty: this is a list of where
/// the chords are, and inventing a row for every silent bar of a four-minute
/// song would bury them.
List<ChordBar> groupChordsIntoBars(
  List<ChordCue> cues,
  List<int> downbeatsMs, {
  int barOne = 1,
}) {
  if (cues.isEmpty || downbeatsMs.isEmpty) return const <ChordBar>[];
  final downbeats = List<int>.of(downbeatsMs)..sort();
  final first = barOneIndex(barOne, downbeats.length);
  final byBar = <int, List<ChordCue>>{};
  for (final cue in cues) {
    final counted = barNumberAt(cue.startMs, downbeats, barOne: barOne);
    final bar = counted ?? (first > 0 ? 0 : 1);
    byBar.putIfAbsent(bar, () => <ChordCue>[]).add(cue);
  }
  final numbers = byBar.keys.toList(growable: false)..sort();
  return <ChordBar>[
    for (final number in numbers)
      if (number < 1)
        // The whole pickup as one, ending where bar 1 begins.
        ChordBar(
          number: 0,
          startMs: downbeats.first,
          endMs: downbeats[first],
          chords: List<ChordCue>.unmodifiable(byBar[number]!),
        )
      else
        ChordBar(
          number: number,
          startMs: downbeats[first + number - 1],
          endMs: first + number < downbeats.length
              ? downbeats[first + number]
              : byBar[number]!.last.endMs,
          chords: List<ChordCue>.unmodifiable(byBar[number]!),
        ),
  ];
}
