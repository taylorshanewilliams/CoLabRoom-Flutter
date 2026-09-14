import '../../domain/song_analysis_models.dart';

/// The rules of practising a song, kept out of the screen so they can be
/// tested without a ticker or a player.
///
/// Practising is the daily reason. Every other thing this app does happens
/// when something happens — a take lands, a sheet finishes, somebody asks.
/// Playing your own song back with the chart moving, one part on repeat,
/// slowed down until the fingers catch up, is the thing a musician does on a
/// Tuesday with nobody waiting on them. The stems were separated and the
/// sections found weeks ago; none of it could be *used* for this until now.

/// Where playback is once [elapsed] has run past the end of [loop]: back at
/// its start. Anywhere else, unchanged.
Duration keepInside(Duration elapsed, StructureSection? loop) {
  if (loop == null) return elapsed;
  if (elapsed.inMilliseconds < loop.endMs) return elapsed;
  return Duration(milliseconds: loop.startMs);
}

/// [delta] of wall-clock time, as song time at [rate].
///
/// Only matters when there is no recording to be the clock: with audio the
/// player reports positions in song time already, slowed or not.
Duration atRate(Duration delta, double rate) =>
    Duration(microseconds: (delta.inMicroseconds * rate).round());

/// One label per section, numbered where a part comes round again.
///
/// "Verse · Chorus · Verse · Chorus" reads as Verse 1, Chorus 1, Verse 2,
/// Chorus 2, so a tap means one place in the song rather than any of them.
/// A part that happens once keeps its plain name; "Intro 1" is a number
/// nobody asked for.
List<String> sectionChipLabels(List<StructureSection> sections) {
  final total = <String, int>{};
  for (final section in sections) {
    final label = section.displayLabel;
    total[label] = (total[label] ?? 0) + 1;
  }
  final seen = <String, int>{};
  final labels = <String>[];
  for (final section in sections) {
    final label = section.displayLabel;
    final nth = (seen[label] ?? 0) + 1;
    seen[label] = nth;
    labels.add((total[label] ?? 1) > 1 ? '$label $nth' : label);
  }
  return labels;
}

/// The speeds worth offering. Slower than half is a different song.
const List<double> practiceRates = <double>[0.5, 0.75, 1.0];

String rateLabel(double rate) {
  if (rate == 0.5) return '½';
  if (rate == 0.75) return '¾';
  return '1×';
}
