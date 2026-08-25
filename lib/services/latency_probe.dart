import 'dart:math' as math;
import 'dart:typed_data';

/// Measures how far a recording lags the audio it was recorded against.
///
/// This is the one unknown standing between CoLabRoom and overdubbing. When
/// you record while a backing track plays, your take lands late by the round
/// trip — the output buffer, the hardware, the microphone buffer — and on
/// Android that is tens to hundreds of milliseconds. Uncompensated, every
/// layer sits behind the beat, and it sounds like bad playing rather than
/// like a bug.
///
/// The method is the obvious one: play a signal, record it coming back, and
/// find where it landed. What matters is not the number itself but whether
/// the number is *stable* across attempts on the same device. A latency of
/// 180ms that is 180ms every time can simply be subtracted. A latency that
/// wanders by 40ms between takes cannot be calibrated away at all, and would
/// mean this approach is dead and an overdub feature needs a native audio
/// engine instead.
///
/// Everything here is pure Dart on plain lists so it can be tested without a
/// device — the device only supplies the recording.
class LatencyProbe {
  const LatencyProbe._();

  static const int sampleRate = 44100;

  /// How long each marker lasts. Long enough to survive a noisy room, short
  /// enough that its position is a moment rather than a smear.
  static const Duration markerLength = Duration(milliseconds: 12);

  /// The gap between the two markers in the calibration signal.
  ///
  /// Two markers rather than one, because they answer different questions.
  /// The first says how far the recording lags the playback, which is the
  /// number an overdub has to be shifted by. The distance between them says
  /// whether the recorder and the player agree about how long a second is —
  /// if they come back 1.02s apart, the clocks differ, and no fixed offset
  /// will keep a four-minute take in time no matter how well the start is
  /// aligned. Those are different failures with different fixes, and one
  /// marker cannot tell them apart.
  static const Duration markerGap = Duration(milliseconds: 1000);

  /// A short frequency sweep, tapered at both ends.
  ///
  /// A sweep rather than a click or a steady tone. A click has the sharpest
  /// possible position but almost no energy, so a noisy room swallows it; a
  /// steady tone has plenty of energy but correlates well against itself at
  /// every period, so it says "here, and also 1ms later, and also 2ms later".
  /// A sweep is never in the same phase twice, which gives it one unambiguous
  /// peak while still carrying real energy.
  ///
  /// The taper matters more than it looks: a sweep that starts at full
  /// amplitude begins with a click of its own, and that click is what a
  /// correlator would lock onto — at slightly the wrong place, and only on
  /// devices whose speakers reproduce it.
  static Float64List marker({
    int rate = sampleRate,
    double startHz = 900,
    double endHz = 6000,
    Duration length = markerLength,
  }) {
    final count = (rate * length.inMicroseconds / 1e6).round();
    final out = Float64List(count);
    final seconds = count / rate;
    // Linear sweep: the instantaneous frequency rises evenly, so the phase is
    // its integral and therefore quadratic in t.
    final rise = (endHz - startHz) / seconds;
    for (var i = 0; i < count; i += 1) {
      final t = i / rate;
      final phase = 2 * math.pi * (startHz * t + 0.5 * rise * t * t);
      // Hann taper across the whole sweep.
      final envelope = 0.5 - 0.5 * math.cos(2 * math.pi * i / (count - 1));
      out[i] = math.sin(phase) * envelope;
    }
    return out;
  }

  /// The signal to play: silence, a marker, silence, the same marker again.
  ///
  /// The leading silence gives the player time to actually start before the
  /// first marker, so a slow start does not clip the very thing being
  /// measured.
  static Float64List calibrationSignal({
    int rate = sampleRate,
    Duration lead = const Duration(milliseconds: 250),
    Duration tail = const Duration(milliseconds: 400),
  }) {
    final pulse = marker(rate: rate);
    final leadCount = (rate * lead.inMicroseconds / 1e6).round();
    final gapCount = (rate * markerGap.inMicroseconds / 1e6).round();
    final tailCount = (rate * tail.inMicroseconds / 1e6).round();
    final out = Float64List(leadCount + gapCount + pulse.length + tailCount);
    for (var i = 0; i < pulse.length; i += 1) {
      out[leadCount + i] = pulse[i];
      out[leadCount + gapCount + i] = pulse[i];
    }
    return out;
  }

  /// Where [needle] sits inside [haystack], or null if it is not convincingly
  /// there.
  ///
  /// Normalised cross-correlation: the raw sum of products would rank a loud
  /// unrelated bang above a quiet exact match, and a room with a door closing
  /// in it produces exactly that. Dividing by the energy of the window being
  /// compared asks "how much does this look like the marker" rather than "how
  /// loud is it here".
  ///
  /// [searchFrom] and [searchTo] bound the hunt in samples, which is what
  /// makes finding the second marker cheap: it can only be a known distance
  /// after the first.
  static ProbeMatch? locate(
    Float64List haystack,
    Float64List needle, {
    int searchFrom = 0,
    int? searchTo,
    double minimumConfidence = 3.0,
  }) {
    if (needle.isEmpty || haystack.length < needle.length) return null;
    final lastLag = math.min(
      searchTo ?? haystack.length - needle.length,
      haystack.length - needle.length,
    );
    final firstLag = math.max(0, searchFrom);
    if (lastLag < firstLag) return null;

    var needleEnergy = 0.0;
    for (final value in needle) {
      needleEnergy += value * value;
    }
    if (needleEnergy <= 0) return null;
    final needleNorm = math.sqrt(needleEnergy);

    // Running energy of the haystack window, carried forward one sample at a
    // time instead of recomputed. Without this the whole search is quadratic
    // in the window length for no reason.
    var windowEnergy = 0.0;
    for (var i = firstLag; i < firstLag + needle.length; i += 1) {
      windowEnergy += haystack[i] * haystack[i];
    }

    var bestLag = -1;
    var bestScore = 0.0;
    var scoreSum = 0.0;
    var scoreCount = 0;

    for (var lag = firstLag; lag <= lastLag; lag += 1) {
      var dot = 0.0;
      for (var i = 0; i < needle.length; i += 1) {
        dot += haystack[lag + i] * needle[i];
      }
      final norm = math.sqrt(windowEnergy) * needleNorm;
      final score = norm > 0 ? dot.abs() / norm : 0.0;
      scoreSum += score;
      scoreCount += 1;
      if (score > bestScore) {
        bestScore = score;
        bestLag = lag;
      }
      if (lag < lastLag) {
        windowEnergy -= haystack[lag] * haystack[lag];
        final entering = haystack[lag + needle.length];
        windowEnergy += entering * entering;
      }
    }

    if (bestLag < 0 || scoreCount == 0) return null;
    final mean = scoreSum / scoreCount;
    // How far the winner stands above the average of everything else. A real
    // marker towers over the room; a room with no marker in it produces a
    // winner barely above its own noise floor, and that is the case this has
    // to refuse rather than report as a very confident zero.
    final confidence = mean > 0 ? bestScore / mean : 0.0;
    if (confidence < minimumConfidence) return null;
    return ProbeMatch(offsetSamples: bestLag, confidence: confidence, peak: bestScore);
  }

  /// Both markers, read out of one recording.
  ///
  /// The second is searched for only near where it must be, which keeps the
  /// cost of the whole measurement to roughly one search rather than two.
  static ProbeReading? read(
    Float64List recording, {
    int rate = sampleRate,
    Duration lead = const Duration(milliseconds: 250),
  }) {
    final pulse = marker(rate: rate);
    final first = locate(recording, pulse);
    if (first == null) return null;

    final gapSamples = (rate * markerGap.inMicroseconds / 1e6).round();
    // Half the gap either side: wide enough for any plausible clock error,
    // narrow enough that it cannot accidentally rediscover the first marker.
    final slack = gapSamples ~/ 2;
    final second = locate(
      recording,
      pulse,
      searchFrom: first.offsetSamples + gapSamples - slack,
      searchTo: first.offsetSamples + gapSamples + slack,
    );

    final leadSamples = (rate * lead.inMicroseconds / 1e6).round();
    return ProbeReading(
      rate: rate,
      // The lead silence was played, so the recording contains it too, and it
      // is not latency. Subtracting it leaves the part that is.
      offsetSamples: first.offsetSamples - leadSamples,
      measuredGapSamples:
          second == null ? null : second.offsetSamples - first.offsetSamples,
      expectedGapSamples: gapSamples,
      confidence: first.confidence,
    );
  }

  /// 16-bit mono PCM in a RIFF wrapper — what `audioplayers` will play from a
  /// file, written without a dependency.
  static Uint8List toWav(Float64List samples, {int rate = sampleRate}) {
    final data = ByteData(44 + samples.length * 2);
    void ascii(int offset, String tag) {
      for (var i = 0; i < tag.length; i += 1) {
        data.setUint8(offset + i, tag.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    data.setUint32(4, 36 + samples.length * 2, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little); // PCM
    data.setUint16(22, 1, Endian.little); // mono
    data.setUint32(24, rate, Endian.little);
    data.setUint32(28, rate * 2, Endian.little); // byte rate
    data.setUint16(32, 2, Endian.little); // block align
    data.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    data.setUint32(40, samples.length * 2, Endian.little);
    for (var i = 0; i < samples.length; i += 1) {
      final clamped = samples[i].clamp(-1.0, 1.0);
      data.setInt16(44 + i * 2, (clamped * 32767).round(), Endian.little);
    }
    return data.buffer.asUint8List();
  }

  /// Mono doubles out of a 16-bit RIFF file.
  ///
  /// Walks the chunk list rather than assuming the header is 44 bytes. It
  /// often is, and the times it is not are precisely the times an assumption
  /// here would produce a recording that reads as noise with no explanation —
  /// `record` is free to emit a LIST or fact chunk, and some Android encoders
  /// do.
  static Float64List fromWav(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    if (bytes.length < 12) return Float64List(0);
    var channels = 1;
    var bits = 16;
    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final size = data.getUint32(offset + 4, Endian.little);
      final body = offset + 8;
      if (id == 'fmt ' && body + 16 <= bytes.length) {
        channels = data.getUint16(body + 2, Endian.little);
        bits = data.getUint16(body + 14, Endian.little);
      } else if (id == 'data') {
        final end = math.min(body + size, bytes.length);
        if (bits != 16 || channels < 1) return Float64List(0);
        final frames = (end - body) ~/ (2 * channels);
        final out = Float64List(frames);
        for (var i = 0; i < frames; i += 1) {
          // Channel 0 only. Mixing would halve the amplitude of anything
          // panned, and the marker's position is the same in every channel.
          out[i] = data.getInt16(body + i * 2 * channels, Endian.little) / 32768.0;
        }
        return out;
      }
      // Chunks are word-aligned; an odd size is followed by a pad byte.
      offset = body + size + (size.isOdd ? 1 : 0);
    }
    return Float64List(0);
  }
}

class ProbeMatch {
  const ProbeMatch({
    required this.offsetSamples,
    required this.confidence,
    required this.peak,
  });

  final int offsetSamples;

  /// The winning score over the average score. Above about 3 means the marker
  /// is really there; near 1 means nothing was found and the position is
  /// whatever the loudest noise happened to be.
  final double confidence;

  /// The winning normalised correlation itself, 0 to 1.
  final double peak;
}

class ProbeReading {
  const ProbeReading({
    required this.rate,
    required this.offsetSamples,
    required this.measuredGapSamples,
    required this.expectedGapSamples,
    required this.confidence,
  });

  final int rate;

  /// How far the recording lags what was played — the number an overdub
  /// would be shifted by. Negative would mean the recording somehow leads the
  /// playback, which is not physical and means the measurement is wrong.
  final int offsetSamples;

  final int? measuredGapSamples;
  final int expectedGapSamples;
  final double confidence;

  double get offsetMs => offsetSamples * 1000 / rate;

  /// How far apart the two markers came back, against how far apart they were
  /// sent. Zero is a recorder and a player that agree about time.
  double? get clockErrorMs => measuredGapSamples == null
      ? null
      : (measuredGapSamples! - expectedGapSamples) * 1000 / rate;

  bool get plausible => offsetSamples >= 0 && confidence >= 3.0;
}
