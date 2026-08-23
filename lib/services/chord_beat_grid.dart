import 'dart:math' as math;

import '../domain/song_analysis_models.dart';

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

/// The 1-indexed bar containing [ms].
///
/// Null before the first downbeat. A pickup phrase sits ahead of bar 1, and
/// both "bar 0" and rounding it up into bar 1 would be claiming something
/// untrue about where it starts.
int? barNumberAt(int ms, List<int> downbeatsMs) {
  if (downbeatsMs.isEmpty || ms < downbeatsMs.first) return null;
  var low = 0;
  var high = downbeatsMs.length - 1;
  while (low < high) {
    final mid = (low + high + 1) >> 1;
    if (downbeatsMs[mid] <= ms) {
      low = mid;
    } else {
      high = mid - 1;
    }
  }
  return low + 1;
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

  /// 1-indexed, counting from the first downbeat.
  final int number;
  final int startMs;
  final int endMs;
  final List<ChordCue> chords;
}

/// Chords grouped into the bar each one starts in — the shape a chord chart
/// is actually read in, rather than a flat run of changes.
///
/// Chords starting before the first downbeat are put in bar 1 rather than
/// dropped. A chord ringing over a pickup is still a chord you play, and
/// losing it off the top of the chart would be worse than showing it a
/// fraction early.
///
/// Bars with no chord in them are absent, not empty: this is a list of where
/// the chords are, and inventing a row for every silent bar of a four-minute
/// song would bury them.
List<ChordBar> groupChordsIntoBars(List<ChordCue> cues, List<int> downbeatsMs) {
  if (cues.isEmpty || downbeatsMs.isEmpty) return const <ChordBar>[];
  final downbeats = List<int>.of(downbeatsMs)..sort();
  final byBar = <int, List<ChordCue>>{};
  for (final cue in cues) {
    final bar = barNumberAt(cue.startMs, downbeats) ?? 1;
    byBar.putIfAbsent(bar, () => <ChordCue>[]).add(cue);
  }
  final numbers = byBar.keys.toList(growable: false)..sort();
  return <ChordBar>[
    for (final number in numbers)
      ChordBar(
        number: number,
        startMs: downbeats[number - 1],
        endMs: number < downbeats.length
            ? downbeats[number]
            : byBar[number]!.last.endMs,
        chords: List<ChordCue>.unmodifiable(byBar[number]!),
      ),
  ];
}
