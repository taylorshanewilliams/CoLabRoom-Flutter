import 'dart:math' as math;
import 'dart:typed_data';

/// Hearing one note.
///
/// A tuner is the one thing every musician opens every day, and the app
/// that hears whole songs could not hear a single string. This is the
/// hearing: raw microphone samples in, a frequency out, and the name a
/// musician would give it.
///
/// The detector is YIN (de Cheveigné & Kawahara, 2002) -- the standard for
/// a monophonic instrument, and what most tuner apps run underneath. It is
/// chosen over a plain FFT because a guitar string's loudest partial is
/// often not its fundamental, and an FFT peak would name the octave above.
/// YIN measures the period directly, so a low E reads as a low E.

/// The lowest and highest notes worth hearing: below a bass's low B, above
/// a soprano's top. Anything outside is noise, or a harmonic.
const double lowestHz = 30;
const double highestHz = 1500;

/// 16-bit little-endian PCM, as the record plugin streams it, to floats in
/// -1..1.
Float64List pcm16ToFloats(Uint8List bytes) {
  final count = bytes.lengthInBytes ~/ 2;
  final view = ByteData.sublistView(bytes, 0, count * 2);
  final out = Float64List(count);
  for (var i = 0; i < count; i++) {
    out[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}

/// The loudness of a frame, as a plain number. Below [silenceRms] the
/// tuner shows nothing rather than naming the hum of the room.
double rms(Float64List samples) {
  if (samples.isEmpty) return 0;
  var sum = 0.0;
  for (final s in samples) {
    sum += s * s;
  }
  return math.sqrt(sum / samples.length);
}

const double silenceRms = 0.01;

/// The fundamental frequency of [samples], or null when there is not one
/// clear enough to name.
///
/// [samples] should be about 4096 long at 44.1 kHz: two periods of the
/// lowest note fit, and a frame is short enough that a note played twice
/// a second reads as two notes.
double? detectPitch(Float64List samples, int sampleRate, {double threshold = 0.15}) {
  final n = samples.length;
  if (n < 512 || rms(samples) < silenceRms) return null;
  final window = n ~/ 2;
  final maxTau = math.min(window - 1, (sampleRate / lowestHz).floor());
  final minTau = math.max(2, (sampleRate / highestHz).floor());
  if (maxTau <= minTau) return null;

  // Difference function, then its cumulative mean normalised form. The
  // normalisation is the whole trick: it stops the search settling on the
  // trivial minimum at lag zero and makes the threshold meaningful.
  final difference = Float64List(maxTau + 1);
  for (var tau = 1; tau <= maxTau; tau++) {
    var sum = 0.0;
    for (var i = 0; i < window; i++) {
      final delta = samples[i] - samples[i + tau];
      sum += delta * delta;
    }
    difference[tau] = sum;
  }
  final normalised = Float64List(maxTau + 1);
  normalised[0] = 1;
  var running = 0.0;
  for (var tau = 1; tau <= maxTau; tau++) {
    running += difference[tau];
    normalised[tau] = running == 0 ? 1 : difference[tau] * tau / running;
  }

  // The first dip under the threshold, walked down to its floor. Taking the
  // first rather than the deepest is what keeps an octave error out: the
  // octave below always dips too, later.
  var tau = -1;
  for (var t = minTau; t <= maxTau; t++) {
    if (normalised[t] < threshold) {
      while (t + 1 <= maxTau && normalised[t + 1] < normalised[t]) {
        t++;
      }
      tau = t;
      break;
    }
  }
  if (tau < 0) return null;

  // Parabolic interpolation between the neighbours, for the fraction of a
  // sample a period never lands on. A cent at 440 Hz is a tenth of a sample.
  var refined = tau.toDouble();
  if (tau > 0 && tau < maxTau) {
    final a = normalised[tau - 1];
    final b = normalised[tau];
    final c = normalised[tau + 1];
    final denominator = a - 2 * b + c;
    if (denominator != 0) refined = tau + (a - c) / (2 * denominator);
  }
  final hz = sampleRate / refined;
  if (hz < lowestHz || hz > highestHz) return null;
  return hz;
}

const List<String> noteNames = <String>[
  'C', 'C♯', 'D', 'D♯', 'E', 'F', 'F♯', 'G', 'G♯', 'A', 'A♯', 'B',
];

/// A frequency, as a musician would say it.
class PitchReading {
  const PitchReading({
    required this.hz,
    required this.name,
    required this.octave,
    required this.cents,
  });

  final double hz;

  /// "A", "F♯" -- the nearest note.
  final String name;

  /// Scientific: A4 is 440, E2 is a guitar's low string.
  final int octave;

  /// How far from that note, -50..50. Negative is flat.
  final double cents;

  /// Close enough that a listener would not hear the difference.
  bool get inTune => cents.abs() <= 5;

  String get label => '$name$octave';

  /// The nearest note as a MIDI number (A4 is 69), the same scale the
  /// melody's notes are on, so the two can be compared.
  int get midi => noteNames.indexOf(name) + (octave + 1) * 12;
}

/// Names [hz] against equal temperament with A4 at [a4].
PitchReading? readPitch(double? hz, {double a4 = 440}) {
  if (hz == null || hz <= 0) return null;
  final midi = 69 + 12 * math.log(hz / a4) / math.ln2;
  final nearest = midi.round();
  if (nearest < 0 || nearest > 127) return null;
  return PitchReading(
    hz: hz,
    name: noteNames[nearest % 12],
    octave: nearest ~/ 12 - 1,
    cents: (midi - nearest) * 100,
  );
}
