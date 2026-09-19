/// The beat in your hand.
///
/// A player who cannot hear the click — deaf, hard of hearing, or standing in
/// front of a drummer on a loud stage — has no way of knowing where the 1 is
/// except by watching somebody's foot. The song already knows: the analysis
/// wrote down every beat and which of them start a bar, and the phone is in a
/// pocket or on a stand either way (Every Musician, Same Song, 17 September
/// 2026, the accessibility item "feel the beat, hear the chords coming").
///
/// Kept out of the screen, like the count-in arithmetic next door, so it can
/// be tested without a ticker, a player, or a phone with a motor in it.
///
/// Personal, the way a reading is: it lives on this device, it is never
/// written to the room, and Follow me does not carry it. A leader cannot put
/// a tap in anybody else's hand, and two players following the same leader
/// can feel the song differently — one every beat, one only the 1, one
/// nothing at all.
library;

import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import '../../services/chord_beat_grid.dart'
    show barOneIndex, medianBeatIntervalMs;

/// How hard a beat is felt.
///
/// Two weights and no more. The 1 has to be tellable from the rest of the bar
/// through a pocket, with an instrument in both hands, and a third step in
/// between would be a difference nobody could feel while playing.
enum BeatWeight { heavy, light }

/// Which beats this phone taps on.
enum FeelTheBeat {
  off(''),
  everyBeat('every'),
  theOne('one');

  const FeelTheBeat(this.stored);

  /// What is written to preferences, spelled out rather than stored as the
  /// enum's own name so renaming a constant cannot silently forget
  /// somebody's choice. Off is the absence of a choice and is stored as
  /// nothing at all. The same shape as NumberStyle.stored.
  final String stored;

  /// What the choice is called on screen. Short, plain, and no count: it
  /// says which beats are felt, not how many there are.
  String get label => switch (this) {
        FeelTheBeat.off => 'Off',
        FeelTheBeat.everyBeat => 'Every beat',
        FeelTheBeat.theOne => 'The 1 only',
      };

  static FeelTheBeat fromStored(String? stored) {
    for (final feel in values) {
      if (feel != off && feel.stored == stored) return feel;
    }
    return off;
  }
}

/// A beat to be felt: where it falls in the song, and how hard.
class FeltBeat {
  const FeltBeat({required this.atMs, required this.weight});

  /// Where in the recording it lands — song time, so a slowed passage moves
  /// it in real time without moving it in the song.
  final int atMs;

  final BeatWeight weight;

  @override
  bool operator ==(Object other) =>
      other is FeltBeat && other.atMs == atMs && other.weight == weight;

  @override
  int get hashCode => Object.hash(atMs, weight);

  @override
  String toString() => 'FeltBeat($atMs, ${weight.name})';
}

/// The beats this song can be felt on.
///
/// Every beat the analysis found. A recording analysed before the tracker
/// wrote them down may still have its bar starts, and those are the half of
/// this that matters most — the 1 — so they stand in as the grid rather than
/// leaving the song with nothing to feel at all. On such a song every beat
/// there is *is* a 1, and both choices come to the same thing.
List<int> feltGrid({
  required List<int> beatsMs,
  List<int> downbeatsMs = const <int>[],
}) =>
    beatsMs.isEmpty ? downbeatsMs : beatsMs;

/// Whether this song has a beat to feel at all.
///
/// A song the tracker heard nothing in offers nothing: the control is simply
/// absent, rather than there and silent. The same refusal the chord chart
/// makes when it will not draw bar lines without downbeats.
bool canFeelTheBeat({
  required List<int> beatsMs,
  List<int> downbeatsMs = const <int>[],
}) =>
    feltGrid(beatsMs: beatsMs, downbeatsMs: downbeatsMs).isNotEmpty;

/// How far from a downbeat a beat can sit and still be that downbeat, as a
/// fraction of one beat.
///
/// The two lists come from the same tracker and normally agree exactly, so
/// this is a defence against a rounding hair rather than a snapping window. A
/// quarter of a beat is well short of the midpoint between two beats, which
/// is what stops one downbeat from making both the beat before it and the
/// beat on it heavy.
const double _theOneWindow = 0.25;

/// The next beat to be felt after [afterMs], or null when there is no more of
/// this song to feel.
///
/// Strictly after by default: a finger moved the song, so the beat it is
/// sitting on has already gone by, and a tap the instant somebody presses
/// play or drags the seek bar is felt as the press rather than as the 1.
///
/// [onTheBeat] is for the times the song arrives on a beat by itself and
/// nobody touched anything — a passage on repeat turning round onto its own
/// first downbeat, a count-in handing over onto the 1 it counted to. There
/// the beat it lands on is not a beat that has gone by: it is the beat, the
/// one the whole loop is being felt for, so it counts (review, 19 September
/// 2026).
///
/// [untilMs] is where a loop turns round, when one is on. A tap is never
/// scheduled past it — the song will be back at the top of the passage before
/// that beat arrives, and the turn arms the next tap itself.
///
/// [barOne] is which downbeat the band said bar 1 is (0161). What sits ahead
/// of it is the pickup: it is still played, so it is still felt, but nothing
/// in it is a 1. So the heavy tap lands on bar 1 and the pickup taps light.
FeltBeat? nextFeltBeat(
  int afterMs, {
  required List<int> beatsMs,
  List<int> downbeatsMs = const <int>[],
  int barOne = 1,
  FeelTheBeat feel = FeelTheBeat.everyBeat,
  int? untilMs,
  bool onTheBeat = false,
}) {
  if (feel == FeelTheBeat.off) return null;
  final grid = feltGrid(beatsMs: beatsMs, downbeatsMs: downbeatsMs);
  if (grid.isEmpty) return null;
  final window = math.max(1, (medianBeatIntervalMs(grid) * _theOneWindow).round());
  for (var i = _firstFrom(afterMs, grid, onTheBeat: onTheBeat);
      i < grid.length;
      i += 1) {
    final at = grid[i];
    if (untilMs != null && at >= untilMs) return null;
    final one = _isTheOne(at, downbeatsMs, barOne, window);
    if (feel == FeelTheBeat.theOne && !one) continue;
    return FeltBeat(
      atMs: at,
      weight: one ? BeatWeight.heavy : BeatWeight.light,
    );
  }
  return null;
}

/// How long from now, in real time, until [beat] is felt: the song is at
/// [fromMs] and playing at [rate].
///
/// The inverse of atRate in practice_rules.dart, and the reason a passage
/// drilled at 60% taps at 60%. Zero for a beat already gone, so a tap that
/// was scheduled a hair late is felt now rather than never.
Duration untilFelt(FeltBeat beat, {required int fromMs, double rate = 1}) {
  final ahead = beat.atMs - fromMs;
  if (ahead <= 0 || rate <= 0) return Duration.zero;
  return Duration(microseconds: (ahead * 1000 / rate).round());
}

/// Where in [grid] to start looking: the first entry strictly after [ms], or
/// the first at or after it when the song landed on a beat of its own.
int _firstFrom(int ms, List<int> grid, {required bool onTheBeat}) {
  var low = 0;
  var high = grid.length;
  while (low < high) {
    final mid = (low + high) >> 1;
    final gone = onTheBeat ? grid[mid] < ms : grid[mid] <= ms;
    if (gone) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  return low;
}

/// Whether this beat is a 1: the first beat of a numbered bar.
///
/// Nothing ahead of bar 1 is, however many downbeats the tracker found up
/// there — that stretch is a pickup or a count-in somebody left on the front
/// of the recording, and calling it a 1 would put the heavy tap in a bar this
/// song does not have (0161).
bool _isTheOne(int beatMs, List<int> downbeatsMs, int barOne, int windowMs) {
  if (downbeatsMs.isEmpty) return false;
  final first = barOneIndex(barOne, downbeatsMs.length);
  if (beatMs + windowMs < downbeatsMs[first]) return false;
  var low = first;
  var high = downbeatsMs.length - 1;
  while (low < high) {
    final mid = (low + high + 1) >> 1;
    if (downbeatsMs[mid] <= beatMs) {
      low = mid;
    } else {
      high = mid - 1;
    }
  }
  if ((beatMs - downbeatsMs[low]).abs() <= windowMs) return true;
  final next = low + 1;
  return next < downbeatsMs.length && downbeatsMs[next] - beatMs <= windowMs;
}

/// What this phone taps on, remembered on this device.
///
/// One answer for every song rather than one per song, the way the count-in
/// is kept: what you need to feel is about your ears and the stage you are
/// standing on, not about the song in front of you.
///
/// Fail-safe, like the readings: preferences that will not open mean the
/// phone stays still, which is what it did before any of this.
abstract final class FeelTheBeatStore {
  static const String _key = 'live_feel_the_beat';

  static Future<FeelTheBeat> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return FeelTheBeat.fromStored(prefs.getString(_key));
    } catch (_) {
      return FeelTheBeat.off;
    }
  }

  static Future<void> save(FeelTheBeat feel) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Off is the absence of a choice, so it is stored as nothing rather
      // than as a row kept forever.
      if (feel == FeelTheBeat.off) {
        await prefs.remove(_key);
      } else {
        await prefs.setString(_key, feel.stored);
      }
    } catch (_) {
      // Not remembered this time; the phone still taps for this session.
    }
  }
}
