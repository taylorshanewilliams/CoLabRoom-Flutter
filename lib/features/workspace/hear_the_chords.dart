/// Hearing the chords coming.
///
/// The other half of "feel the beat, hear the chords coming". A blind player
/// cannot read the chart at all; a player whose eyes are on their hands can
/// read it only by looking up at the moment they can least afford to. Both
/// want the same thing a bandleader gives a room by calling the next chord
/// over the top of the bar before it: the name, one beat early (Every
/// Musician, Same Song, 17 September 2026).
///
/// Kept out of the screen, like the beat taps next door, so the schedule can
/// be tested without a ticker, a player, or a phone with a voice on it.
///
/// Personal, the way a reading is: it lives on this device, it is never
/// written to the room, and Follow me does not carry it. A leader cannot put
/// a voice in anybody else's ear, and two players following the same leader
/// can hear the song differently — one in numbers, one in letters, one in
/// silence.
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/song_analysis_models.dart';
import '../../services/chord_beat_grid.dart'
    show beatIndexAt, medianBeatIntervalMs;
import '../../services/chord_names.dart' show chordDisplay;

/// Whether this phone calls the chords.
///
/// An on and an off and nothing between, stored the way FeelTheBeat is so
/// that off is the absence of a choice rather than a row kept forever.
enum HearTheChords {
  off(''),
  on('on');

  const HearTheChords(this.stored);

  /// What is written to preferences, spelled out rather than stored as the
  /// enum's own name so renaming a constant cannot silently forget somebody's
  /// choice.
  final String stored;

  /// What the choice is called on screen.
  String get label => switch (this) {
        HearTheChords.off => 'Off',
        HearTheChords.on => 'On',
      };

  static HearTheChords fromStored(String? stored) {
    for (final hear in values) {
      if (hear != off && hear.stored == stored) return hear;
    }
    return off;
  }
}

/// One chord called: when it is said, when the chord it names arrives, and
/// the chord itself as the song stores it.
///
/// The stored label and never a spelling of it. Which words come out is the
/// listener's own business — their key, their instrument's written pitch,
/// their capo, their numbers — and a queue that had already decided would be
/// a queue that has to be thrown away when somebody moves their capo.
class ChordCall {
  const ChordCall({
    required this.atMs,
    required this.changeMs,
    required this.chord,
  });

  /// When the name is said, in song time — so a passage slowed to 70% moves
  /// it in the room without moving it in the song.
  final int atMs;

  /// When the chord itself lands. One beat after [atMs], on the song's own
  /// grid.
  final int changeMs;

  /// The chord as the analysis stored it, in Harte. Read into words at the
  /// moment it is said.
  final String chord;

  @override
  bool operator ==(Object other) =>
      other is ChordCall &&
      other.atMs == atMs &&
      other.changeMs == changeMs &&
      other.chord == chord;

  @override
  int get hashCode => Object.hash(atMs, changeMs, chord);

  @override
  String toString() => 'ChordCall($atMs → $changeMs, $chord)';
}

/// Every chord this song can be called through, in order.
///
/// Built once off the analysis rather than searched for on each beat: the
/// cues and the beat grid cannot change while a song is open, and the rule
/// that stops two calls landing on top of each other needs to know what was
/// said last, which a search starting from wherever the song is does not.
///
/// A call goes one beat ahead on the song's own grid — the beat before the
/// one the change belongs to — so it follows a recording that drifts or
/// pushes instead of counting a tempo of its own. A change the tracker put
/// between two beats is called from the beat before the nearer of them, which
/// is a little early rather than a little late; early is the one a player can
/// use.
///
/// The beats are wanted and the downbeats are no substitute: a name called on
/// the downbeat before a change is a whole bar early, which is not a call at
/// all. A song the tracker heard no beat in is offered nothing, the same
/// refusal the chord chart makes when it will not draw bar lines without
/// downbeats.
///
/// A change with no beat anywhere near it is passed over for the same reason.
/// The grid can stop before the chord map does — a ritardando ending the
/// tracker gave up on, a breakdown it lost — and the nearest beat to a chord
/// in that hole can be many seconds away. Called from it, the name would go
/// out eight seconds early and sound exactly like a call for the very next
/// beat. Where there is no beat to be a beat ahead of, saying nothing is the
/// honest answer (review, 19 September 2026).
List<ChordCall> chordCalls({
  required List<ChordCue> cues,
  required List<int> beatsMs,
}) {
  if (cues.isEmpty || beatsMs.length < 2) return const <ChordCall>[];
  final ordered = List<ChordCue>.of(cues)
    ..sort((a, b) => a.startMs.compareTo(b.startMs));
  // How far from a beat a change can fall and still be understood as meant
  // for it. One beat: anything inside that is either on the grid or the push
  // ahead of a beat the grid does have, and anything past it is in a hole.
  final window = medianBeatIntervalMs(beatsMs);
  final calls = <ChordCall>[];
  // Which beat the last call was made on, so nothing is said twice in one
  // beat. -1 is "nothing said yet", and the first beat of the song is 0.
  var lastBeat = -1;
  for (final cue in ordered) {
    // A stretch the model heard no chord in. There is nothing to call, and
    // "N" is a letter, not a chord — but it does not block the chord after
    // it either.
    if (chordDisplay(cue.chord).isEmpty) continue;
    final beat = beatIndexAt(cue.startMs, beatsMs);
    // A chord that starts on the song's first beat has nothing in front of it
    // to be called from. Saying it late would be naming a chord already
    // sounding, which is what the chart on screen is for.
    if (beat == null || beat < 1) continue;
    // The nearest beat, however far away it is: past a beat away it is not
    // this chord's beat at all. See the note above.
    if (window > 0 && (beatsMs[beat] - cue.startMs).abs() > window) continue;
    final at = beat - 1;
    // Two changes less than a beat apart want the same beat to be called on.
    // The first one keeps it: the second is skipped rather than stacked on
    // top of it, because two names at once is neither of them.
    if (at <= lastBeat) continue;
    lastBeat = at;
    calls.add(ChordCall(
      atMs: beatsMs[at],
      changeMs: cue.startMs,
      chord: cue.chord,
    ));
  }
  return List<ChordCall>.unmodifiable(calls);
}

/// The next chord to be called after [afterMs], or null when there is no more
/// of this song to call.
///
/// Strictly after by default, the same rule the beat taps follow: a finger
/// moved the song, so a call on the beat it landed on is a call for a change
/// that is already here.
///
/// [onTheBeat] is for the song arriving on a beat by itself — a passage on
/// repeat turning round onto its own first downbeat, a count-in handing over.
/// There the beat it lands on has not gone by, so a call sitting on it counts.
///
/// [untilMs] is where a loop turns round, when one is on. Nothing is
/// scheduled past it, and nothing is called for a change on the far side of
/// it either: while a passage is on repeat the chord after its last bar is
/// one nobody is going to play.
ChordCall? nextChordCall(
  int afterMs, {
  required List<ChordCall> calls,
  int? untilMs,
  bool onTheBeat = false,
}) {
  for (var i = _firstFrom(afterMs, calls, onTheBeat: onTheBeat);
      i < calls.length;
      i += 1) {
    final call = calls[i];
    if (untilMs != null && call.atMs >= untilMs) return null;
    if (untilMs != null && call.changeMs >= untilMs) continue;
    return call;
  }
  return null;
}

/// The one call a passage on repeat would otherwise never make: the chord it
/// turns round onto.
///
/// [nextChordCall] will not name a chord on the far side of the turn, and it
/// is right not to — nobody is going to play it. But something *is* coming at
/// the turn: the chord the passage starts on. Its own call sits one beat
/// before the passage begins, outside it, where no lap ever reaches it. So a
/// player drilling two bars of C into D7 hears "D seven" every lap and never
/// hears the C they have to get back to, which is half of the change they are
/// drilling (review, 19 September 2026).
///
/// Said on the last beat inside the passage, a beat ahead of the turn exactly
/// the way every other call is a beat ahead of its change. [changeMs] is the
/// turn itself, because that is when the chord lands in this lap.
///
/// Null when there is nothing to say: a passage that turns round onto the
/// chord it was already playing has no change at its turn, a beat already
/// carrying a call of its own keeps it, and a turn with no beat within a beat
/// of it is a turn there is no grid for.
ChordCall? loopTurnCall({
  required List<ChordCue> cues,
  required List<int> beatsMs,
  required List<ChordCall> calls,
  required int startMs,
  required int endMs,
}) {
  if (cues.isEmpty || beatsMs.length < 2 || endMs <= startMs) return null;
  final coming = _chordAt(startMs, cues);
  if (coming == null || chordDisplay(coming).isEmpty) return null;
  // What is sounding as the passage ends. The same chord means the turn is
  // not a change at all, and a call for a chord already under the fingers is
  // a call for nothing.
  if (_chordAt(endMs - 1, cues) == coming) return null;
  final at = _lastBeatBefore(endMs, beatsMs);
  if (at == null || beatsMs[at] < startMs) return null;
  final atMs = beatsMs[at];
  final window = medianBeatIntervalMs(beatsMs);
  if (window > 0 && endMs - atMs > window) return null;
  for (final call in calls) {
    // A change of its own landing inside the passage on the beat after this
    // one. That call is the next thing coming, so it keeps the beat.
    if (call.atMs == atMs && call.changeMs < endMs) return null;
  }
  return ChordCall(atMs: atMs, changeMs: endMs, chord: coming);
}

/// The chord sounding at [ms], or null where the analysis heard none.
String? _chordAt(int ms, List<ChordCue> cues) {
  String? found;
  var latest = -1;
  for (final cue in cues) {
    if (cue.startMs <= ms && ms < cue.endMs && cue.startMs > latest) {
      latest = cue.startMs;
      found = cue.chord;
    }
  }
  return found;
}

/// The last beat strictly before [ms], or null when the grid has none.
int? _lastBeatBefore(int ms, List<int> beatsMs) {
  var low = 0;
  var high = beatsMs.length;
  while (low < high) {
    final mid = (low + high) >> 1;
    if (beatsMs[mid] < ms) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  return low == 0 ? null : low - 1;
}

/// How long from now, in real time, until [call] is made: the song is at
/// [fromMs] and playing at [rate].
///
/// The sibling of untilFelt in feel_the_beat.dart, and the reason a passage
/// drilled at 70% is called at 70%. Zero for a call already gone, so one
/// scheduled a hair late is made now rather than never.
Duration untilCalled(ChordCall call, {required int fromMs, double rate = 1}) {
  final ahead = call.atMs - fromMs;
  if (ahead <= 0 || rate <= 0) return Duration.zero;
  return Duration(microseconds: (ahead * 1000 / rate).round());
}

/// Where in [calls] to start looking: the first strictly after [ms], or the
/// first at or after it when the song landed on a beat of its own.
int _firstFrom(int ms, List<ChordCall> calls, {required bool onTheBeat}) {
  var low = 0;
  var high = calls.length;
  while (low < high) {
    final mid = (low + high) >> 1;
    final gone = onTheBeat ? calls[mid].atMs < ms : calls[mid].atMs <= ms;
    if (gone) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  return low;
}

/// Whether this phone calls the chords, remembered on this device.
///
/// One answer for every song rather than one per song, the way the beat taps
/// and the count-in are kept: whether you need to be told what is coming is
/// about your eyes and where they are, not about the song in front of you.
///
/// Fail-safe, like the readings: preferences that will not open mean the
/// phone stays quiet, which is what it did before any of this.
abstract final class HearTheChordsStore {
  static const String _key = 'live_hear_the_chords';

  static Future<HearTheChords> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return HearTheChords.fromStored(prefs.getString(_key));
    } catch (_) {
      return HearTheChords.off;
    }
  }

  static Future<void> save(HearTheChords hear) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Off is the absence of a choice, so it is stored as nothing rather
      // than as a row kept forever.
      if (hear == HearTheChords.off) {
        await prefs.remove(_key);
      } else {
        await prefs.setString(_key, hear.stored);
      }
    } catch (_) {
      // Not remembered this time; the phone still calls for this session.
    }
  }
}
