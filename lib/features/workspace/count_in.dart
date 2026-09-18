import '../../domain/song_analysis_models.dart';
import 'practice_rules.dart' show clampBpm;

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
/// where it had no confident answer. Four then — less a guess about this
/// song than the count anybody gives when nobody has said otherwise, and the
/// same default the metronome and the mixdown click already use. A number
/// outside what a bar can hold is treated the same way.
int beatsInBar(int? beatsPerBar) {
  final beats = beatsPerBar ?? 4;
  return beats < 2 || beats > 12 ? 4 : beats;
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
/// [rate] is the speed the song is about to play at, so a passage being
/// drilled at three-quarter speed is counted in at three-quarter speed too.
/// Counting at a hundred and coming in at seventy-five is worse than not
/// counting.
CountIn? countInFor({
  double? bpm,
  int? beatsPerBar,
  List<int> downbeatsMs = const <int>[],
  double rate = 1,
}) {
  if (bpm == null || bpm <= 0 || rate <= 0) return null;
  if (downbeatsMs.isEmpty) return null;
  return CountIn(beats: beatsInBar(beatsPerBar), bpm: clampBpm(bpm) * rate);
}

/// The count-in for an analysed song, or null when the analysis never found
/// its beat.
CountIn? countInForSong(ReferenceTrack? reference, {double rate = 1}) =>
    reference == null
        ? null
        : countInFor(
            bpm: reference.bpm,
            beatsPerBar: reference.beatsPerBar,
            downbeatsMs: reference.downbeatsMs,
            rate: rate,
          );
