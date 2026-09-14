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

/// Which word of a line is being sung at [elapsedMs]: the last one that has
/// started. Null when the line has no word timing, when nothing in it has
/// started yet, or when the timing does not fit the words -- the same
/// refusal chordPlacementsForLine makes, for the same reason: a highlight
/// on the wrong word is worse than none.
int? wordAt(List<int>? starts, int? elapsedMs, int wordCount) {
  if (starts == null || elapsedMs == null) return null;
  if (starts.isEmpty || starts.length != wordCount) return null;
  int? found;
  for (var i = 0; i < starts.length; i++) {
    if (starts[i] <= elapsedMs) {
      found = i;
    } else {
      break;
    }
  }
  return found;
}

/// A tempo range a musician would recognise. Slower than 40 is not a beat
/// and faster than 240 is a buzz.
const double minBpm = 40;
const double maxBpm = 240;

double clampBpm(double bpm) => bpm.clamp(minBpm, maxBpm).toDouble();

/// The tempo a hand is tapping, from the last few taps.
///
/// The median interval rather than the mean, so one late tap does not drag
/// the number; the last four taps, so a tempo that changes is followed.
/// Null with fewer than two taps, or after a pause long enough to mean the
/// count has started again.
double? tapTempo(List<DateTime> taps) {
  if (taps.length < 2) return null;
  final recent = taps.length > 4 ? taps.sublist(taps.length - 4) : taps;
  final intervals = <int>[];
  for (var i = 1; i < recent.length; i++) {
    final gap = recent[i].difference(recent[i - 1]).inMilliseconds;
    if (gap <= 0) continue;
    if (gap > 2000) return null;
    intervals.add(gap);
  }
  if (intervals.isEmpty) return null;
  intervals.sort();
  final middle = intervals[intervals.length ~/ 2];
  return clampBpm(60000 / middle);
}

/// The note under each word of a line: what each word is sung on, as a
/// singer says it, or null for a word the tracker heard nothing in.
///
/// A word runs from its own start to the next word's start (the last one
/// runs to the end of the line), and its note is the one that fills most
/// of that stretch -- see Melody.noteWithin for why not the note at the
/// word's first instant. Empty when there is no melody or no word timing:
/// a line that cannot be lit word by word cannot carry notes word by word
/// either, and a note under the wrong word would be worse than none.
List<String?> notesForWords(
  Melody? melody,
  List<int>? wordStartsMs,
  int lineEndMs,
  int wordCount,
) {
  if (melody == null || melody.isEmpty || wordStartsMs == null) {
    return const <String?>[];
  }
  if (wordCount <= 0 || wordStartsMs.length != wordCount) {
    return const <String?>[];
  }
  final notes = List<String?>.filled(wordCount, null);
  var anyNote = false;
  for (var index = 0; index < wordCount; index += 1) {
    final start = wordStartsMs[index];
    final end = index + 1 < wordCount ? wordStartsMs[index + 1] : lineEndMs;
    if (end <= start) continue;
    final note = melody.noteWithin(start, end);
    if (note != null) {
      notes[index] = note.label;
      anyNote = true;
    }
  }
  return anyNote ? notes : const <String?>[];
}

/// How the singer stands against the note the song is on.
///
/// [nothing] when nothing is being heard; [noTarget] when the song has no
/// note at this moment (a breath, an instrumental bar); otherwise whether
/// the sung note is the song's, below it, or above it. An octave away
/// counts as on it: a singer whose voice sits an octave from the
/// recording's is singing the same note where their voice lives, and
/// telling them to go up an octave would be wrong twice.
enum Singing { nothing, noTarget, onIt, low, high }

Singing singingVerdict(int? heardMidi, int? targetMidi) {
  if (heardMidi == null) return Singing.nothing;
  if (targetMidi == null) return Singing.noTarget;
  final diff = heardMidi - targetMidi;
  if (diff % 12 == 0) return Singing.onIt;
  return diff < 0 ? Singing.low : Singing.high;
}

/// What to say under the two notes: the direction to move, or nothing to
/// move, in the words a singer would use.
String singingHint(Singing verdict) => switch (verdict) {
      Singing.nothing => 'Sing along. Headphones help — without them the microphone hears the song too.',
      Singing.noTarget => 'Nothing sung here.',
      Singing.onIt => 'On it.',
      Singing.low => 'Higher.',
      Singing.high => 'Lower.',
    };
