import 'dart:math' as math;
import 'dart:typed_data';

import 'package:colabroom/services/multitrack.dart';
import 'package:flutter_test/flutter_test.dart';

/// Why the reference track drew a fence.
///
/// The first version took the peak of each bucket. A three-and-a-half-minute
/// song across 56 buckets is 3.6 seconds a bucket, and the loudest instant in
/// any 3.6 seconds of a mixed record is essentially always full scale — so
/// every bar came out the same height. A four-second take, at 70 ms a bucket,
/// kept its detail and looked like a waveform, which is what made the
/// difference visible on a phone rather than here.

/// Music-ish: a loud section, a quiet section, and silence.
Float64List _dynamics({required int seconds, int rate = Multitrack.rate}) {
  final out = Float64List(seconds * rate);
  for (var i = 0; i < out.length; i += 1) {
    final third = i / out.length;
    final level = third < 0.33 ? 0.7 : (third < 0.66 ? 0.12 : 0.0);
    // A transient every half second, so peak-per-bucket would saturate.
    final spike = i % (rate ~/ 2) < 400 ? 0.95 : level;
    out[i] = math.sin(i * 0.05) * spike;
  }
  return out;
}

double _spread(List<double> wave) {
  var lo = double.infinity, hi = 0.0;
  for (final v in wave) {
    if (v < lo) lo = v;
    if (v > hi) hi = v;
  }
  return hi - lo;
}

void main() {
  test('a long take keeps its shape instead of flattening', () {
    // The reference case: three and a half minutes.
    final wave = Multitrack.envelope(_dynamics(seconds: 30), buckets: 56);

    expect(wave.length, 56);
    // A fence would have a spread near zero. Loud, quiet and silent sections
    // have to remain distinguishable.
    expect(_spread(wave), greaterThan(0.2),
        reason: 'every bar came out the same height');
  });

  test('the quiet section reads quieter than the loud one', () {
    final wave = Multitrack.envelope(_dynamics(seconds: 30), buckets: 60);
    final loud = wave.take(18).reduce(math.max);
    final quiet = wave.skip(22).take(14).reduce(math.max);

    expect(quiet, lessThan(loud * 0.6));
  });

  test('silence reads as silence', () {
    final wave = Multitrack.envelope(_dynamics(seconds: 30), buckets: 60);
    expect(wave.last, lessThan(0.05));
  });

  test('a short take still resolves detail', () {
    final wave = Multitrack.envelope(_dynamics(seconds: 4), buckets: 48);
    expect(_spread(wave), greaterThan(0.2));
  });

  test('loudness stays absolute between takes', () {
    // Not normalised per take: a quiet take must draw shorter than a loud
    // one, which is the comparison a mixer exists to make.
    final loud = Multitrack.envelope(
      Float64List.fromList(List<double>.filled(Multitrack.rate, 0.8)),
      buckets: 8,
    );
    final quiet = Multitrack.envelope(
      Float64List.fromList(List<double>.filled(Multitrack.rate, 0.1)),
      buckets: 8,
    );

    expect(loud.first, greaterThan(quiet.first * 4));
  });

  test('an empty take has no shape rather than a zero-length one', () {
    expect(Multitrack.envelope(Float64List(0)), isEmpty);
  });

  group('a click that follows the song', () {
    test('lands on the beats it was given, not on a count from zero', () {
      // The bug: a song whose first downbeat is at 480 ms got a click
      // starting at 0, wrong against the record for its whole length.
      final beats = <int>[480, 980, 1480, 1980];
      final click = Multitrack.clickOnBeats(
        beatsMs: beats,
        lengthSamples: Multitrack.rate * 3,
      );

      for (final at in beats) {
        final index = (at * Multitrack.rate / 1000).round();
        expect(click[index + 20].abs(), greaterThan(0.01),
            reason: 'no click at ${at}ms');
      }
      // And nothing at zero, where the old one would have struck.
      expect(click[40].abs(), lessThan(0.001));
    });

    test('no beats is no click rather than an exception', () {
      final click = Multitrack.clickOnBeats(
        beatsMs: const <int>[],
        lengthSamples: Multitrack.rate,
      );
      expect(Multitrack.peakOf(click), 0.0);
    });
  });
}
