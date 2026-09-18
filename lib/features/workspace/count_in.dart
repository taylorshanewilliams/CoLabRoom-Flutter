import '../../domain/song_analysis_models.dart';
import '../../services/chord_beat_grid.dart'
    show barNumberAt, barOneIndex, medianBeatIntervalMs;
import 'practice_rules.dart' show maxBpm, minBpm;

/// Counting a band in on the song's own beat, rather than in seconds.
///
/// Perform has had a countdown since long before any of this: three to ten
/// seconds of a number getting smaller, which says when the song starts and
/// nothing at all about how fast it goes. That is not how anybody has ever
/// been counted in. A musician is counted in *at the tempo they are about to
/// play*, and by the fourth beat their hands are already inside the time
/// (Every Musician, Same Song, 17 September 2026).
///
/// Kept out of the screen so the arithmetic can be tested without a ticker,
/// a player, or a phone to feel the haptics on.

/// How long one beat lasts at [bpm].
Duration beatLength(double bpm) =>
    Duration(microseconds: (60000000 / bpm).round());

/// How long one bar lasts at [bpm], with [beatsPerBar] beats in it.
Duration barLength({required double bpm, required int beatsPerBar}) =>
    beatLength(bpm) * beatsInBar(beatsPerBar);

/// How many beats are in a bar of this song.
///
/// The analysis counts it from the gaps between downbeats and leaves it null
/// where it had no confident answer. When it does, the downbeats can often
/// still say: the gap from one of them to the next *is* a bar, and the tempo
/// says how many beats fit inside it. So a waltz the analysis recorded
/// downbeats for but no metre is counted three, which is the whole point of
/// counting a band in on the song's own time rather than on four.
///
/// Four only when neither the analysis nor the downbeats give an answer a bar
/// could hold — less a guess about this song than the count anybody gives
/// when nobody has said otherwise, and the same default the metronome and the
/// mixdown click already use.
int beatsInBar(
  int? beatsPerBar, {
  double? bpm,
  List<int> downbeatsMs = const <int>[],
}) {
  if (_holdsABar(beatsPerBar)) return beatsPerBar!;
  final heard = _beatsBetweenDownbeats(bpm: bpm, downbeatsMs: downbeatsMs);
  return _holdsABar(heard) ? heard! : 4;
}

/// Whether that many beats is a bar anybody plays.
///
/// One beat is not a count-in and thirteen is the tracker having lost the
/// plot.
bool _holdsABar(int? beats) => beats != null && beats >= 2 && beats <= 12;

/// The metre the downbeats themselves imply: how many beats fit in the gap
/// from one bar to the next.
///
/// Median gap rather than the first one, so a single downbeat the tracker
/// dropped — which shows up as one gap of twice the length — cannot decide
/// the metre for the whole song.
int? _beatsBetweenDownbeats({
  required double? bpm,
  required List<int> downbeatsMs,
}) {
  if (bpm == null || bpm <= 0) return null;
  final barMs = medianBeatIntervalMs(downbeatsMs);
  if (barMs <= 0) return null;
  return (barMs * 1000 / beatLength(bpm).inMicroseconds).round();
}

/// The start of the bar [ms] is inside, or null when it sits ahead of the
/// first downbeat.
///
/// Null is a real answer, not a failure: a pickup phrase, or the top of a
/// song that does not begin exactly on its own downbeat, has no earlier bar
/// to be moved back to.
int? downbeatAtOrBefore(int ms, List<int> downbeatsMs) {
  final bar = barNumberAt(ms, downbeatsMs);
  return bar == null ? null : downbeatsMs[bar - 1];
}

/// One bar of the song's own time: how many beats are in it, and how fast.
class CountIn {
  const CountIn({required this.beats, required this.bpm});

  /// Beats in the bar — four in common time, three in a waltz.
  final int beats;

  /// The tempo the bar is counted at: the song's own, at the speed it is
  /// about to be played at.
  final double bpm;

  Duration get beat => beatLength(bpm);

  /// The whole bar. Playback starts exactly this long after the first beat of
  /// the count, so the song's own first downbeat lands on the beat *after*
  /// the last one counted rather than on top of it.
  Duration get length => barLength(bpm: bpm, beatsPerBar: beats);
}

/// When the [beat]th beat of the count falls, measured from the first one.
///
/// Beat one is now, so the count runs from zero to one beat short of
/// [CountIn.length] — and the song comes in on the beat that would have been
/// next. A count that let the song start on its own last beat would put the
/// band one beat ahead of the first note, every time.
Duration countInBeatAt(CountIn countIn, int beat) => countIn.beat * (beat - 1);

/// The count-in for a song, or null when it has no beat of its own to be
/// counted in on.
///
/// Both a tempo and downbeats are wanted, and the downbeats are the
/// important half: a bpm on its own can be a guess, and a bar counted at a
/// guessed tempo is confidently wrong in a way nobody in the room can see —
/// the same refusal the chord chart makes when it will not draw bar lines
/// without them. A song that fails this keeps the seconds countdown, which
/// claims nothing about the song at all.
///
/// A tempo outside what a beat can be is refused rather than pulled into
/// range. Clamping a tracker's 260 to 240 would count the bar at a tempo the
/// song is not at, and hand over 77 milliseconds after it said it would —
/// which is the same confident wrongness this function exists to avoid, just
/// quieter. The seconds claim nothing, so the seconds are the safe answer.
///
/// [rate] is the speed the song is about to play at, so a passage being
/// drilled at three-quarter speed is counted in at three-quarter speed too.
/// Counting at a hundred and coming in at seventy-five is worse than not
/// counting. The rate is applied after the range check, because a song
/// slowed to half speed really is going to arrive at half the tempo.
/// [barOne] is which downbeat the band says is bar 1 (0161). The metre is
/// counted from there rather than across the whole grid, because what sits in
/// front of bar 1 is the one stretch that is not a bar of this song: a
/// count-in somebody left on the recording, or a pickup phrase. The median
/// above is a defence against one downbeat the tracker dropped; it was never
/// a defence against a count-in the tracker read as bars of its own, and four
/// bars of a two-beat count on the front of a short recording will outvote
/// the song and count the band in on two.
CountIn? countInFor({
  double? bpm,
  int? beatsPerBar,
  List<int> downbeatsMs = const <int>[],
  double rate = 1,
  int barOne = 1,
}) {
  if (bpm == null || rate <= 0) return null;
  if (bpm < minBpm || bpm > maxBpm) return null;
  if (downbeatsMs.isEmpty) return null;
  final first = barOneIndex(barOne, downbeatsMs.length);
  final song = first == 0 ? downbeatsMs : downbeatsMs.sublist(first);
  return CountIn(
    beats: beatsInBar(beatsPerBar, bpm: bpm, downbeatsMs: song),
    bpm: bpm * rate,
  );
}

/// The count-in for an analysed song, or null when the analysis never found
/// its beat.
CountIn? countInForSong(
  ReferenceTrack? reference, {
  double rate = 1,
  int barOne = 1,
}) =>
    reference == null
        ? null
        : countInFor(
            bpm: reference.bpm,
            beatsPerBar: reference.beatsPerBar,
            downbeatsMs: reference.downbeatsMs,
            rate: rate,
            barOne: barOne,
          );
