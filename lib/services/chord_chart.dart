import 'dart:math' as math;

import '../domain/song_analysis_models.dart';
import 'chord_beat_grid.dart';

/// Laying the chords out as bars, the way a chart is written.
///
/// The lyric sheet answers "what do I play while I sing this line". A chart
/// answers a different question — "what's the shape of this song" — and it's
/// the one you want when you're comping, when there are no words yet, or when
/// you're handing the song to somebody else.
///
/// Everything this needs already exists: chords sit on beats, sections start
/// on downbeats, and the grid says where the bars are. This is the arithmetic
/// between that and something you could put on a music stand.

/// A chord change, and where in its bar it happens.
class ChartChord {
  const ChartChord({
    required this.chord,
    required this.beat,
    required this.startMs,
  });

  /// The stored label, not yet spelled for display — see chordDisplay.
  final String chord;

  /// 1-indexed beat within the bar.
  final int beat;
  final int startMs;
}

class ChartBar {
  const ChartBar({
    required this.number,
    required this.startMs,
    required this.endMs,
    required this.beatsInBar,
    required this.chords,
    this.sectionLabel,
  });

  /// 1-indexed, counted from the first downbeat.
  final int number;
  final int startMs;
  final int endMs;

  /// How many beats this bar actually got, counted rather than assumed — a
  /// song that drops a beat going into a chorus has a bar that is genuinely
  /// short, and drawing it as four would be drawing a different song.
  final int beatsInBar;

  /// Only chords that *start* in this bar. A bar with none is a chord still
  /// ringing from an earlier one, which is exactly how a chart is read: you
  /// write a chord when it changes, and empty bars mean keep going.
  final List<ChartChord> chords;

  /// Set on the bar a section begins on.
  final String? sectionLabel;
}

/// One printed line of the chart.
class ChartRow {
  const ChartRow({required this.bars, this.sectionLabel});

  final List<ChartBar> bars;

  /// The section starting on this row, when one does.
  final String? sectionLabel;

  int get firstBarNumber => bars.first.number;
}

/// Four to a line, which is what a chart looks like almost everywhere.
const int defaultBarsPerRow = 4;

/// Bars, with the chords that start in each.
///
/// Empty without downbeats: bars are the one thing here that cannot be
/// estimated. A chart drawn on a guessed grid would be confidently wrong in a
/// way a musician couldn't see, which is worse than no chart.
List<ChartBar> buildChartBars({
  required List<ChordCue> cues,
  required List<int> beatsMs,
  required List<int> downbeatsMs,
  List<StructureSection> sections = const <StructureSection>[],
}) {
  if (downbeatsMs.isEmpty) return const <ChartBar>[];
  final downbeats = List<int>.of(downbeatsMs)..sort();
  final beats = List<int>.of(beatsMs)..sort();
  final ordered = List<ChordCue>.of(cues)
    ..sort((a, b) => a.startMs.compareTo(b.startMs));

  final songEnd = <int>[
    downbeats.last,
    if (beats.isNotEmpty) beats.last,
    if (ordered.isNotEmpty) ordered.last.endMs,
  ].reduce(math.max);

  // A section is announced on the bar it starts on. putIfAbsent because two
  // sections landing on one bar is a disagreement the chart can't draw —
  // first one wins rather than the label flickering between them.
  final sectionByBar = <int, String>{};
  for (final section in sections) {
    final bar = barNumberAt(section.startMs, downbeats);
    if (bar != null) sectionByBar.putIfAbsent(bar, () => section.displayLabel);
  }

  final bars = <ChartBar>[];
  for (var index = 0; index < downbeats.length; index += 1) {
    final start = downbeats[index];
    final end = index + 1 < downbeats.length ? downbeats[index + 1] : songEnd;
    if (end <= start) continue;

    final barBeats = beats
        .where((beat) => beat >= start && beat < end)
        .toList(growable: false);
    final chords = <ChartChord>[];
    for (final cue in ordered) {
      if (cue.startMs < start) continue;
      if (cue.startMs >= end) break; // ordered by start, so nothing later fits
      if (cue.chord.isEmpty || cue.chord == 'N') continue;
      var beat = 1;
      for (var position = 0; position < barBeats.length; position += 1) {
        if (barBeats[position] <= cue.startMs) beat = position + 1;
      }
      chords.add(
        ChartChord(chord: cue.chord, beat: beat, startMs: cue.startMs),
      );
    }

    bars.add(
      ChartBar(
        number: index + 1,
        startMs: start,
        endMs: end,
        beatsInBar: barBeats.isEmpty ? 1 : barBeats.length,
        chords: List<ChartChord>.unmodifiable(chords),
        sectionLabel: sectionByBar[index + 1],
      ),
    );
  }

  return _trimSilentEnds(bars);
}

/// Drops empty bars from the top and bottom of the chart.
///
/// The count often starts before anything is played and runs past the last
/// chord, so an untrimmed chart opens and closes with blank lines that say
/// nothing. Bars that announce a section are kept regardless — an eight-bar
/// intro with no detected chord is still part of the song's shape.
List<ChartBar> _trimSilentEnds(List<ChartBar> bars) {
  var first = 0;
  while (first < bars.length &&
      bars[first].chords.isEmpty &&
      bars[first].sectionLabel == null) {
    first += 1;
  }
  var last = bars.length - 1;
  while (last >= first &&
      bars[last].chords.isEmpty &&
      bars[last].sectionLabel == null) {
    last -= 1;
  }
  if (first > last) return const <ChartBar>[];
  return List<ChartBar>.unmodifiable(bars.sublist(first, last + 1));
}

/// Breaks the bars into printed lines.
///
/// A section always starts a new line, even mid-row, because that's what
/// makes the shape of a song visible on paper. Otherwise it's a fixed number
/// of bars to a line.
List<ChartRow> buildChartRows(
  List<ChartBar> bars, {
  int barsPerRow = defaultBarsPerRow,
}) {
  if (bars.isEmpty) return const <ChartRow>[];
  final safePerRow = math.max(1, barsPerRow);
  final rows = <ChartRow>[];
  var current = <ChartBar>[];
  String? currentLabel;

  void flush() {
    if (current.isEmpty) return;
    rows.add(ChartRow(bars: List<ChartBar>.unmodifiable(current), sectionLabel: currentLabel));
    current = <ChartBar>[];
    currentLabel = null;
  }

  for (final bar in bars) {
    if (bar.sectionLabel != null && current.isNotEmpty) flush();
    if (current.isEmpty) currentLabel = bar.sectionLabel;
    current.add(bar);
    if (current.length == safePerRow) flush();
  }
  flush();
  return List<ChartRow>.unmodifiable(rows);
}
