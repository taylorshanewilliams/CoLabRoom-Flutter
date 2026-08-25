import 'dart:math' as math;
import 'dart:typed_data';

/// Aligns a recorded take to a beat grid the app already knows, by finding
/// the shift that best lands the take's attacks on the beats.
///
/// The second answer to recording latency, and the one that does not care
/// what the latency was. Calibration measures the delay and subtracts it,
/// which works only while the delay stays put. This asks a different
/// question: given that this take is late by some unknown amount, how late
/// must it be for its playing to make musical sense against the grid we
/// already computed for the song? An unstable device is no harder than a
/// stable one, because nothing here is remembered between takes.
///
/// What it needs in exchange is attacks. A strummed guitar, a snare, a
/// piano part or a percussive vocal give it plenty; a sustained pad or a
/// held note give it almost nothing, and it says so rather than guessing —
/// see [AlignmentResult.trustworthy].
///
/// Pure Dart on plain lists, so the whole thing is testable without a device
/// or a real recording.
class OnsetAlign {
  const OnsetAlign._();

  /// Analysis hop. 5ms is finer than any player's timing and coarse enough
  /// that a four-minute take is a few tens of thousands of frames.
  static const int hopMs = 5;

  /// How far ahead the search looks, in milliseconds.
  ///
  /// Latency is always positive — a recording cannot precede what it was
  /// recorded against — so the search runs forward only. The ceiling is the
  /// worst plausible Bluetooth round trip; beyond that the answer would be
  /// ambiguous anyway, for the reason in [alignToGrid].
  static const int maxShiftMs = 400;

  /// How hard the recording is being hit, frame by frame.
  ///
  /// Half-wave rectified energy difference: how much louder this frame is
  /// than the last, counting only increases. That is what an attack is, and
  /// ignoring decreases is what stops a note *ending* from reading as a note
  /// starting.
  ///
  /// Deliberately not spectral flux. Flux is better at catching a soft note
  /// beginning under a ringing one, and needs an FFT per frame; for the job
  /// here — finding a strum against a grid — the energy envelope is enough
  /// and costs a hundredth as much.
  static Float64List onsetStrength(
    Float64List samples, {
    int rate = 44100,
    int hop = hopMs,
  }) {
    final hopSamples = math.max(1, (rate * hop / 1000).round());
    final frames = samples.length ~/ hopSamples;
    if (frames < 2) return Float64List(0);

    final energy = Float64List(frames);
    for (var f = 0; f < frames; f += 1) {
      var sum = 0.0;
      final start = f * hopSamples;
      for (var i = start; i < start + hopSamples; i += 1) {
        sum += samples[i] * samples[i];
      }
      // Root-mean-square, then log. A strum played quietly and the same strum
      // played hard are the same event; on a linear scale the loud one would
      // outvote several quiet ones and drag the alignment onto itself.
      energy[f] = math.log(1e-9 + math.sqrt(sum / hopSamples));
    }

    final strength = Float64List(frames);
    for (var f = 1; f < frames; f += 1) {
      final rise = energy[f] - energy[f - 1];
      strength[f] = rise > 0 ? rise : 0.0;
    }
    return strength;
  }

  /// The shift, in milliseconds, that best lands [samples]' attacks on
  /// [beatsMs].
  ///
  /// Scores every candidate shift by how much onset strength lands on a beat,
  /// and returns the best — together with how much better it was than the
  /// average, which is the only thing separating a real alignment from the
  /// arithmetic still producing a number for a recording of a held chord.
  ///
  /// **The ambiguity that bounds this.** A beat grid repeats, so a shift of
  /// exactly one beat scores almost as well as no shift at all. Searching
  /// further than half a beat would therefore let the take snap a whole beat
  /// late and call it aligned. At 120bpm half a beat is 250ms; the search is
  /// clamped to whichever is smaller, that or [maxShiftMs]. A device slower
  /// than the clamp cannot be rescued this way, and [AlignmentResult.clamped]
  /// says when the ceiling was the binding constraint rather than the audio.
  static AlignmentResult? alignToGrid(
    Float64List samples,
    List<int> beatsMs, {
    int rate = 44100,
    int hop = hopMs,
    int? maxShiftOverrideMs,
  }) {
    if (beatsMs.length < 2) return null;
    final hopSamples = math.max(1, (rate * hop / 1000).round());
    final strength = onsetStrength(samples, rate: rate, hop: hop);
    if (strength.length < 4) return null;

    var total = 0.0;
    for (final value in strength) {
      total += value;
    }
    if (total <= 0) return null;

    // Median spacing rather than mean: one missed beat in the grid doubles a
    // gap, and a mean quietly absorbs that while a median ignores it.
    final gaps = <int>[];
    for (var i = 1; i < beatsMs.length; i += 1) {
      gaps.add(beatsMs[i] - beatsMs[i - 1]);
    }
    gaps.sort();
    final beatMs = gaps[gaps.length ~/ 2];
    if (beatMs <= 0) return null;

    final ceiling = maxShiftOverrideMs ?? maxShiftMs;
    final ambiguityLimit = beatMs ~/ 2;
    final searchMs = math.min(ceiling, ambiguityLimit);
    final shiftFrames = searchMs ~/ hop;
    if (shiftFrames < 1) return null;

    var bestShift = 0;
    var bestScore = -1.0;
    var scoreSum = 0.0;
    var scoreCount = 0;

    for (var shift = 0; shift <= shiftFrames; shift += 1) {
      var score = 0.0;
      for (final beat in beatsMs) {
        // Where this beat falls in the recording, if the recording is late by
        // `shift` frames.
        // Converted through samples, not through milliseconds. A hop is
        // 220.5 samples at 44.1kHz and gets rounded to 221, so dividing a
        // millisecond position by the *nominal* 5ms drifts against the frames
        // it is being compared to — about a quarter of a frame per beat, all
        // in the same direction, which read as the take being systematically
        // early.
        final frame = (beat * rate / 1000 / hopSamples).round() + shift;
        if (frame < 0 || frame >= strength.length) continue;
        // One frame of tolerance either side, because a player is not a
        // sequencer and the grid itself was estimated.
        for (var d = -1; d <= 1; d += 1) {
          final at = frame + d;
          if (at < 0 || at >= strength.length) continue;
          score += strength[at] * (d == 0 ? 1.0 : 0.5);
        }
      }
      scoreSum += score;
      scoreCount += 1;
      if (score > bestScore) {
        bestScore = score;
        bestShift = shift;
      }
    }

    if (scoreCount == 0 || bestScore <= 0) return null;
    final mean = scoreSum / scoreCount;
    return AlignmentResult(
      shiftMs: bestShift * hop,
      confidence: mean > 0 ? bestScore / mean : 0.0,
      // What share of everything the player did landed on a beat. This is the
      // measure that tells a strum from a swell, and prominence alone was not
      // it: a sustained note's onset strength is small and smeared, but it is
      // smeared *evenly*, so some shift still wins by a respectable margin
      // over the others and looks confident. Asking how much of the total
      // landed on the grid instead gives a strummed part 0.3 and upwards and
      // a held note under 0.1, because most of its movement is nowhere near
      // a beat.
      concentration: bestScore / total,
      searchedToMs: searchMs,
      clamped: ceiling < ambiguityLimit,
    );
  }
}

class AlignmentResult {
  const AlignmentResult({
    required this.shiftMs,
    required this.confidence,
    required this.concentration,
    required this.searchedToMs,
    required this.clamped,
  });

  /// How late the recording is, to the nearest hop.
  final int shiftMs;

  /// The winning score over the average score across all shifts.
  ///
  /// This is the number that decides whether to believe the answer at all. A
  /// take full of attacks produces one shift that scores far above the rest;
  /// a sustained note produces roughly the same score everywhere, and its
  /// "best" shift is noise wearing the shape of an answer.
  final double confidence;

  /// The share of the take's total attack energy that landed on the grid at
  /// the winning shift. High for anything played with a pick or a stick, low
  /// for anything held.
  final double concentration;

  final int searchedToMs;

  /// True when [OnsetAlign.maxShiftMs] stopped the search before the musical
  /// ambiguity would have. A real shift beyond the ceiling reads as a shift
  /// at the ceiling, so this being true alongside a [shiftMs] at the limit
  /// means the answer is a floor, not a measurement.
  final bool clamped;

  /// Whether the alignment is worth acting on.
  ///
  /// Both tests have to pass, because each admits a different fake. A shift
  /// can stand out from the other shifts while representing almost none of
  /// the playing, and a take can have most of its energy on beats while no
  /// single shift is clearly better than its neighbours.
  ///
  /// Deliberately cautious in both. Getting this wrong produces no visible
  /// error at all — it produces a take sitting confidently in the wrong
  /// place, which the player hears as their own bad timing.
  bool get trustworthy => confidence >= 1.5 && concentration >= 0.15;

  bool get atCeiling => clamped && shiftMs >= searchedToMs;
}
