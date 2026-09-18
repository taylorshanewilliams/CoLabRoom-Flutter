import '../../domain/song_analysis_models.dart';
import '../../services/chord_beat_grid.dart'
    show barNumberAt, barOneIndex, downbeatIndexOfBar, numberedBarCount;
import 'musician_sheet_logic.dart' show noteAsPlayed;

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
Duration keepInside(Duration elapsed, PracticeLoop? loop) {
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
///
/// Three of them was too few. Slowing a passage down and creeping it back up
/// is what every one of the eight lenses in the research asked for first, and
/// half to three-quarters to full is a jump a hand cannot follow: the step a
/// player needs next is a tenth, not a quarter (Every Musician, Same Song,
/// 17 September 2026).
const List<double> practiceRates = <double>[0.5, 0.6, 0.7, 0.75, 0.8, 0.9, 1.0];

/// Half, three-quarter and full speed keep the names a musician says out
/// loud. The ones in between have no such name, so they say the number
/// rather than a fraction nobody would read aloud.
String rateLabel(double rate) {
  if (rate == 0.5) return '½';
  if (rate == 0.75) return '¾';
  if (rate == 1) return '1×';
  return '${(rate * 100).round()}%';
}

/// The speed one step either side of [rate], or null at the ends.
///
/// Null is how the stepper knows to go grey: seven speeds on seven chips is
/// a row the thumb has to scroll past before it can reach the parts, so
/// Perform shows one speed and two arrows instead.
///
/// A rate that is not one of these — a mark kept by a build with a different
/// list, or a number that came back from Postgres a hair off an exact double
/// — steps to the nearest listed speed in the direction asked for, so the
/// arrow always moves the song the way it points.
double? rateStep(double rate, {required bool faster}) {
  final at = practiceRates.indexOf(rate);
  if (at < 0) {
    if (faster) {
      for (final other in practiceRates) {
        if (other > rate) return other;
      }
      return null;
    }
    for (final other in practiceRates.reversed) {
      if (other < rate) return other;
    }
    return null;
  }
  final next = faster ? at + 1 : at - 1;
  if (next < 0 || next >= practiceRates.length) return null;
  return practiceRates[next];
}

/// What is on repeat: a part of the song by name, or a run of bars.
///
/// Sections were all there was, and "again" meant a part a musician would
/// name. But the sentence a teacher says most often is "bars nine to twelve",
/// and the research asked for it in every lens (Every Musician, Same Song,
/// 17 September 2026). Downstream both are the same thing — a start, an end
/// and a name — which is why Follow me and the practice marks needed nothing
/// new to carry one.
class PracticeLoop {
  const PracticeLoop({
    required this.startMs,
    required this.endMs,
    required this.label,
    this.firstBar,
    this.lastBar,
  });

  final int startMs;
  final int endMs;

  /// What the chip and the practice mark call it: "Chorus 2", "Bars 9–12".
  final String label;

  /// The bars this covers, when it was chosen as bars rather than as a part.
  final int? firstBar;
  final int? lastBar;

  bool get isBars => firstBar != null && lastBar != null;

  /// By where it runs and what it is called, so a loop rebuilt from two
  /// times — a heartbeat from the leader, a practice mark reopened — is the
  /// same loop as the one the chip is showing.
  @override
  bool operator ==(Object other) =>
      other is PracticeLoop &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.label == label;

  @override
  int get hashCode => Object.hash(startMs, endMs, label);
}

/// One loop per section, named the way its chip is.
List<PracticeLoop> sectionLoops(List<StructureSection> sections) {
  final labels = sectionChipLabels(sections);
  return <PracticeLoop>[
    for (var i = 0; i < sections.length; i += 1)
      PracticeLoop(
        startMs: sections[i].startMs,
        endMs: sections[i].endMs,
        label: labels[i],
      ),
  ];
}

/// What the beats ahead of bar 1 are called, everywhere they are named.
///
/// One word for the whole of it rather than a run of numbers. A pickup is one
/// thing a player asks for — "from the pickup" — and counting backwards into
/// bar 0 and bar -1 is arithmetic nobody does on a stand (Every Musician,
/// Same Song, 17 September 2026).
const String pickupLabel = 'Pickup';

/// "Bars 9–12", or "Bar 9" when it is one.
///
/// A number below 1 is the pickup, which happens when the band has said the
/// song starts a few downbeats into the recording.
String barsLabel(int firstBar, int lastBar) {
  if (lastBar < 1) return pickupLabel;
  if (firstBar < 1) return '$pickupLabel–bar $lastBar';
  return firstBar == lastBar ? 'Bar $firstBar' : 'Bars $firstBar–$lastBar';
}

/// Where bar [bar] starts: the downbeat it begins on.
///
/// Bar 1 is the [barOne]th downbeat — the first one unless the band has said
/// the recording opens with a pickup or a count-in (migration 0161). What is
/// ahead of bar 1 is the pickup and has no number, so a loop over bars simply
/// cannot start before the song's own count does. [downbeatsMs] is ascending,
/// which is how the beat tracker emits it.
int barStartMs(int bar, List<int> downbeatsMs, {int barOne = 1}) {
  if (downbeatsMs.isEmpty) return 0;
  return downbeatsMs[downbeatIndexOfBar(bar, barOne, downbeatsMs.length)];
}

/// Where bar [bar] ends: the next downbeat, or the end of the recording for
/// the last bar.
///
/// [songEndMs] is the recording's own length when it is known. Without it the
/// last bar is given the length of the one before it, which is the only
/// honest guess available and is never used to decide anything a musician
/// can see except where a loop over the final bar turns round.
int barEndMs(int bar, List<int> downbeatsMs, {int? songEndMs, int barOne = 1}) {
  final count = downbeatsMs.length;
  if (count == 0) return 0;
  final at = downbeatIndexOfBar(bar, barOne, count);
  if (at + 1 < count) return downbeatsMs[at + 1];
  final last = downbeatsMs[count - 1];
  if (songEndMs != null && songEndMs > last) return songEndMs;
  final one = count >= 2 ? last - downbeatsMs[count - 2] : 0;
  return last + (one > 0 ? one : 1);
}

/// A loop over [firstBar] to [lastBar] inclusive, snapped to the downbeats
/// either side of them.
///
/// Null without a grid to count bars on. A bar loop laid over a guessed grid
/// would be confidently wrong in a way nobody could see, which is the same
/// reason the chord chart refuses to draw bars without downbeats.
PracticeLoop? barLoop({
  required int firstBar,
  required int lastBar,
  required List<int> downbeatsMs,
  int? songEndMs,
  int barOne = 1,
}) {
  final count = downbeatsMs.length;
  if (count == 0) return null;
  final bars = numberedBarCount(barOne, count);
  var first = firstBar.clamp(1, bars).toInt();
  var last = lastBar.clamp(1, bars).toInt();
  if (last < first) {
    final held = first;
    first = last;
    last = held;
  }
  final start = barStartMs(first, downbeatsMs, barOne: barOne);
  final end =
      barEndMs(last, downbeatsMs, songEndMs: songEndMs, barOne: barOne);
  if (end <= start) return null;
  return PracticeLoop(
    startMs: start,
    endMs: end,
    label: barsLabel(first, last),
    firstBar: first,
    lastBar: last,
  );
}

/// The pickup on its own: everything from the first downbeat up to bar 1.
///
/// Null when the band has said nothing, because then bar 1 *is* the first
/// downbeat and there is nothing ahead of it to play. Until 0161 this stretch
/// could not be put on repeat at all — it had no bar number, so there was no
/// way to ask for it — which is exactly the phrase a teacher drills on a song
/// that starts with one.
///
/// Its ends are numbered 0 so that a loop reopened from a practice mark or a
/// heartbeat is recognised as the pickup rather than as bars; no bar number
/// this app prints is ever 0, because [barsLabel] turns it back into a word.
PracticeLoop? pickupLoop(List<int> downbeatsMs, {int barOne = 1}) {
  if (downbeatsMs.isEmpty) return null;
  final first = barOneIndex(barOne, downbeatsMs.length);
  if (first < 1) return null;
  final start = downbeatsMs.first;
  final end = downbeatsMs[first];
  if (end <= start) return null;
  return PracticeLoop(
    startMs: start,
    endMs: end,
    label: pickupLabel,
    firstBar: 0,
    lastBar: 0,
  );
}

/// The loop a start and an end time mean on this song: the part with exactly
/// those edges, or else the run of bars they cover.
///
/// Follow me and the practice marks carry a loop as two times and nothing
/// else, on purpose — two phones cannot misread a number the way they can
/// misread a name (see follow_me.dart). This is how a time range becomes
/// something to put on a chip again, and it is why a follower's chip reads
/// "Bars 9–12" without the leader ever sending those words. The times
/// themselves are kept exactly as given: the follower loops where the leader
/// loops, and only the name is worked out here.
PracticeLoop? loopFor(
  int? startMs,
  int? endMs, {
  List<StructureSection> sections = const <StructureSection>[],
  List<int> downbeatsMs = const <int>[],
  int barOne = 1,
}) {
  if (startMs == null || endMs == null || endMs <= startMs) return null;
  final labels = sectionChipLabels(sections);
  for (var i = 0; i < sections.length; i += 1) {
    if (sections[i].startMs == startMs && sections[i].endMs == endMs) {
      return PracticeLoop(startMs: startMs, endMs: endMs, label: labels[i]);
    }
  }
  // The pickup has no bar numbers to be worked out from, so it is recognised
  // by its own two edges — the same way a section is, and exact for the same
  // reason: both ends came from this grid in the first place.
  final pickup = pickupLoop(downbeatsMs, barOne: barOne);
  if (pickup != null &&
      pickup.startMs == startMs &&
      pickup.endMs == endMs) {
    return pickup;
  }
  final first = barNumberAt(startMs, downbeatsMs, barOne: barOne);
  // The end is where the loop turns round rather than a moment it plays, so
  // the last bar is the one the instant just before it sits in.
  final last = barNumberAt(endMs - 1, downbeatsMs, barOne: barOne);
  if (first == null || last == null || last < first) return null;
  return PracticeLoop(
    startMs: startMs,
    endMs: endMs,
    label: barsLabel(first, last),
    firstBar: first,
    lastBar: last,
  );
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

/// The note under each word of a line: what each word is sung on in the key
/// this person reads the song in, as a singer says it, or null for a word the
/// tracker heard nothing in.
///
/// A word runs from its own start to the next word's start (the last one
/// runs to the end of the line), and its note is the one that fills most
/// of that stretch -- see Melody.noteWithin for why not the note at the
/// word's first instant. Empty when there is no melody or no word timing:
/// a line that cannot be lit word by word cannot carry notes word by word
/// either, and a note under the wrong word would be worse than none.
///
/// [transpose] is how far this person has moved the song and [key] is the
/// song's key before that move, both passed on to noteAsPlayed: the names
/// follow the chords over the words rather than staying in the recording's
/// key. Asked for rather than defaulted, because a silent zero here is the
/// bug itself.
List<String?> notesForWords(
  Melody? melody,
  List<int>? wordStartsMs,
  int lineEndMs,
  int wordCount, {
  required int transpose,
  String? key,
}) {
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
      notes[index] = noteAsPlayed(note.midi, transpose: transpose, key: key);
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
/// counts as on it: a singer whose voice sits an octave from the note asked
/// for is singing the same note where their voice lives, and telling them to
/// go up an octave would be wrong twice. [targetMidi] is the note as this
/// person reads it -- the caller has already moved it by their transpose --
/// so a moved song is compared against its own chart, not the recording.
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
