import 'dart:math' as math;
import 'dart:typed_data';

import 'latency_probe.dart';

/// A sustained tone on one note: a drone to tune and sing against, and the
/// starting pitch that is the same tone let go of after two seconds.
///
/// For anybody who plays against a tonic rather than against a chord — a
/// tanpura under Indian classical, a pitch pipe in front of a barbershop
/// quartet, a choir director sounding the note before a bar is counted (Every
/// Musician, Same Song, 17 September 2026). It is arithmetic and a few sine
/// waves, made here on the phone the way the count-in's click is, so there is
/// no plugin, no sample pack and no network between pressing the button and
/// hearing the note.
///
/// Nothing in this file composes: a drone is the note the song already counts
/// from, held. It is not a bass line, a harmony or a groove.

/// The octave a drone and a starting pitch sound in, written the way a tuner
/// writes one: C3 is 130.8 Hz at A=440, A3 is 220.
///
/// One octave and no control to move it. Low enough to sit under a song
/// without fighting anything sung over it, high enough that a voice can find
/// it without an instrument, and anybody who wants it somewhere else sings it
/// somewhere else — which is what people do with a pitch pipe anyway.
const int droneOctave = 3;

/// The rate a drone is built at.
///
/// Half the rate the rest of the app records at, and plenty: the highest
/// partial in here is the sixth harmonic of B3, about 1.5 kHz, against a
/// ceiling of 11 kHz. Halving it halves what has to be built and held, which
/// is what makes the long loop below affordable on a phone.
const int droneSampleRate = 22050;

/// How long a drone loop is, near enough. The real length is rounded to a
/// whole number of cycles, which is what makes the seam silent.
///
/// Thirty seconds rather than two, and the reason is the *player* rather than
/// the samples. The buffer closes on itself exactly — see [droneTone] — but no
/// platform audioplayers runs on promises a gapless loop. iOS is the clear
/// case: audioplayers_darwin loops in its sound-complete handler, seeking back
/// to zero and resuming, so every time round costs a short dropout. At two
/// seconds that is a pulse every two seconds, which is the one thing a drone
/// cannot be. At thirty it is a blink somebody tuning will not meet, and the
/// file is still only about 1.3 MB.
const double droneLoopSeconds = 30;

/// How long a starting pitch sounds. About two seconds: long enough to find
/// with a voice, short enough that nobody has to stop it.
const double startingPitchSeconds = 2;

/// The frequency of pitch class [pitchClass] — 0 for C up to 11 for B, the
/// same numbering keyRootPitch answers in — with A at [a4].
///
/// [a4] is the tuner's reference and not a constant: an orchestra at 442 and a
/// baroque group at 415 are both in tune, and a drone at 440 under either of
/// them is the thing that is wrong (#364).
double droneHz(int pitchClass, {double a4 = 440, int octave = droneOctave}) {
  final midi = (octave + 1) * 12 + ((pitchClass % 12) + 12) % 12;
  return a4 * math.pow(2, (midi - 69) / 12);
}

/// How many cycles of [hz] a loop of about [seconds] holds.
///
/// Always even, and never fewer than two. Even because the fifth added over
/// the drone is a *just* fifth, exactly three halves of the fundamental: three
/// of its cycles for every two below it. An odd cycle count would leave the
/// fifth half a cycle short at the end of the file and put a click on every
/// seam — the one fault a drone cannot have, because a drone is nothing but
/// seams.
int droneCycles({required double hz, double seconds = droneLoopSeconds}) {
  final pairs = (hz * seconds / 2).round();
  return math.max(1, pairs) * 2;
}

/// How many samples that loop is.
///
/// Rounded to a whole sample, which moves the note by about a fiftieth of a
/// cent at these lengths — see [droneSoundingHz]. The alternative is a file
/// that ends a fraction of a sample into a cycle, and that is audible: a tick,
/// twice a second, forever.
int droneLoopSamples({
  required double hz,
  int rate = droneSampleRate,
  double seconds = droneLoopSeconds,
}) =>
    math.max(
      2,
      (droneCycles(hz: hz, seconds: seconds) * rate / hz).round(),
    );

/// The frequency the loop actually sounds at, once its length has been rounded
/// to whole samples. Within a twentieth of a cent of [hz] at any length worth
/// looping, and exactly periodic, which [hz] itself would not be.
double droneSoundingHz({
  required double hz,
  int rate = droneSampleRate,
  double seconds = droneLoopSeconds,
}) =>
    droneCycles(hz: hz, seconds: seconds) *
    rate /
    droneLoopSamples(hz: hz, rate: rate, seconds: seconds);

/// What a drone is made of: each partial as a multiple of the fundamental,
/// and how loud it is.
///
/// A handful of harmonics rather than a bare sine, because a sine is a test
/// tone and nobody can hear whether they are singing in unison with one. The
/// fifth, when it is asked for, is added as a note of its own with harmonics
/// of its own — a tanpura's Pa, and the second note of a pitch pipe.
///
/// The fifth is just (three halves) and not equal-tempered. An equal-tempered
/// fifth beats against the note under it about twice a second, which is
/// exactly the wobble a drone exists to let somebody hear their own voice
/// against.
///
/// Six harmonics and a gentle roll-off rather than four and a steep one,
/// because of the loudspeaker this will mostly be heard through. A phone
/// reproduces very little below about 300 Hz, and this octave runs from 131 Hz
/// to 247 Hz: for the lower keys the fundamental is simply not there, and a
/// drone whose energy was nearly all in the first two partials came out thin
/// and quiet. Strengthening the upper partials puts the sound back in the band
/// a phone can actually move air in, and it is the right tone anyway — a
/// tanpura is rich, not pure. Every multiple is still a whole number of turns
/// across the loop.
List<(double, double)> dronePartials({bool fifth = false}) => <(double, double)>[
      (1, 1),
      (2, 0.62),
      (3, 0.42),
      (4, 0.28),
      (5, 0.19),
      (6, 0.13),
      if (fifth) ...<(double, double)>[
        (1.5, 0.55),
        (3, 0.34),
        (4.5, 0.23),
        (6, 0.15),
      ],
    ];

/// A drone, as samples that loop seamlessly end to end.
///
/// Every partial is written as a whole number of cycles across the buffer
/// rather than at its own frequency, so the sample after the last one is the
/// first one again, exactly. There is nothing at the seam to hear.
///
/// That is as far as the samples can get it. Handing this to a looping player
/// does not make the loop gapless, because the seam a listener hears belongs
/// to the player and not to the buffer: audioplayers loops on iOS by seeking
/// back to the start and resuming, which costs a short dropout every time
/// round. [droneLoopSeconds] is long for that reason — the seam is made rare
/// rather than made silent, and that is the honest description of it.
///
/// No attack. An envelope on the front of a loop is not an attack, it is a
/// tremolo once every time round — the drone is faded in by the player that
/// holds it instead. See DronePlayer.
Float64List droneTone({
  required double hz,
  bool fifth = false,
  int rate = droneSampleRate,
  double seconds = droneLoopSeconds,
}) {
  final length = droneLoopSamples(hz: hz, rate: rate, seconds: seconds);
  final cycles = droneCycles(hz: hz, seconds: seconds);
  return _partialSum(length: length, cycles: cycles, fifth: fifth);
}

/// A starting pitch: the same tone, sounded once and let go of.
///
/// Enveloped here rather than by the player, because this one is not looped
/// and a note that starts and stops square is a click at both ends. The attack
/// is short and the release is long, which is what a struck or blown note
/// does and what makes it easy to sing against.
Float64List startingPitchTone({
  required double hz,
  bool fifth = false,
  int rate = droneSampleRate,
  double seconds = startingPitchSeconds,
}) {
  final length = droneLoopSamples(hz: hz, rate: rate, seconds: seconds);
  final cycles = droneCycles(hz: hz, seconds: seconds);
  final out = _partialSum(length: length, cycles: cycles, fifth: fifth);
  final attack = math.min(length ~/ 4, (rate * 0.04).round());
  final release = math.min(length - attack, (rate * 0.6).round());
  for (var i = 0; i < length; i += 1) {
    var gain = 1.0;
    if (i < attack) gain = i / attack;
    final left = length - 1 - i;
    if (left < release) gain *= left / release;
    out[i] *= gain;
  }
  return out;
}

/// The partials summed over [length] samples, each one [cycles] times its own
/// multiple, then brought under full scale so nothing clips on the way to a
/// 16-bit file.
///
/// Scaled to a fixed peak rather than by the sum of the amplitudes, so adding
/// the fifth does not make the drone louder as well as different — how loud it
/// is belongs to the person's level, not to whether they asked for a fifth.
Float64List _partialSum({
  required int length,
  required int cycles,
  required bool fifth,
}) {
  final partials = dronePartials(fifth: fifth);
  final out = Float64List(length);
  for (final (multiple, amplitude) in partials) {
    // Whole cycles across the buffer, so the loop closes on itself. The
    // multiples are 1, 2, 3, 4 and — with the fifth — 1.5, 3 and 4.5, and
    // [droneCycles] is even so every one of those lands on a whole number.
    final turns = cycles * multiple;
    for (var i = 0; i < length; i += 1) {
      // The whole turns are taken off before the angle is built. Without that
      // the argument to sin reaches a hundred million by the end of the loop,
      // where a double's last bits are worth more than the fraction of a turn
      // being asked about.
      final phase = (turns * i) % length;
      out[i] += amplitude * math.sin(2 * math.pi * phase / length);
    }
  }
  var peak = 0.0;
  for (final sample in out) {
    peak = math.max(peak, sample.abs());
  }
  if (peak > 0) {
    final scale = 0.86 / peak;
    for (var i = 0; i < length; i += 1) {
      out[i] *= scale;
    }
  }
  return out;
}

/// The bytes a player can be handed: one drone loop as a 16-bit mono WAV.
///
/// Half a minute of tone is a few million sine calls, which is long enough to
/// drop frames if it happens between a finger and a switch. [WavDronePlayer]
/// builds it off the main thread — see [droneWavFor].
Uint8List droneWav({
  required double hz,
  bool fifth = false,
  int rate = droneSampleRate,
}) =>
    LatencyProbe.toWav(droneTone(hz: hz, fifth: fifth, rate: rate), rate: rate);

/// The bytes for one starting pitch.
Uint8List startingPitchWav({
  required double hz,
  bool fifth = false,
  int rate = droneSampleRate,
}) =>
    LatencyProbe.toWav(
      startingPitchTone(hz: hz, fifth: fifth, rate: rate),
      rate: rate,
    );

/// What a drone is asked for, in one argument.
///
/// A record rather than two arguments because this is what crosses into the
/// isolate that builds the tone, and `compute` passes one message.
typedef DroneRequest = ({double hz, bool fifth});

/// [droneWav], in the shape `compute` wants. Top level so it can be sent.
Uint8List droneWavFor(DroneRequest request) =>
    droneWav(hz: request.hz, fifth: request.fifth);

/// [startingPitchWav], in the same shape and for the same reason.
Uint8List startingPitchWavFor(DroneRequest request) =>
    startingPitchWav(hz: request.hz, fifth: request.fifth);
