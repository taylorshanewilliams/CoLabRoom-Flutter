import 'dart:typed_data';

import 'package:colabroom/services/multitrack.dart';
import 'package:flutter_test/flutter_test.dart';

/// The click, as arithmetic.
///
/// Summed into the mix rather than played beside it, for the reason at the
/// top of multitrack.dart: a second player has its own clock, and a metronome
/// that drifts teaches somebody their timing is wrong when it is the app's.

int _peakIndexNear(Float64List samples, int around, int window) {
  var best = around;
  var bestValue = 0.0;
  for (var i = (around - window).clamp(0, samples.length - 1);
      i < (around + window).clamp(0, samples.length);
      i += 1) {
    final v = samples[i].abs();
    if (v > bestValue) {
      bestValue = v;
      best = i;
    }
  }
  return best;
}

void main() {
  const rate = Multitrack.rate;

  test('clicks land on the beat', () {
    // 120bpm is half a second a beat.
    final samples = Multitrack.click(bpm: 120, lengthSamples: rate * 4);

    for (var beat = 0; beat < 8; beat += 1) {
      final expected = (beat * 0.5 * rate).round();
      final found = _peakIndexNear(samples, expected, 400);
      expect((found - expected).abs(), lessThan(200),
          reason: 'beat $beat drifted');
    }
  });

  test('the downbeat is louder than the beats after it', () {
    final samples = Multitrack.click(bpm: 120, lengthSamples: rate * 4);
    final downbeat = samples[_peakIndexNear(samples, 0, 400)].abs();
    final second = samples[_peakIndexNear(samples, (0.5 * rate).round(), 400)].abs();

    expect(downbeat, greaterThan(second));
  });

  test('a click leaves headroom rather than filling the mix', () {
    // It plays under a band, not over one.
    final samples = Multitrack.click(bpm: 100, lengthSamples: rate * 2);
    expect(Multitrack.peakOf(samples), lessThan(0.4));
  });

  test('no tempo produces no clicks rather than dividing by zero', () {
    final samples = Multitrack.click(bpm: 0, lengthSamples: rate);
    expect(Multitrack.peakOf(samples), 0.0);
  });

  group('the grid a click implies', () {
    test('120bpm is a beat every 500ms', () {
      final beats = Multitrack.beatsForTempo(bpm: 120, throughMs: 2000);
      expect(beats, <int>[0, 500, 1000, 1500, 2000]);
    });

    test('an awkward tempo still lands on whole milliseconds', () {
      final beats = Multitrack.beatsForTempo(bpm: 137, throughMs: 2000);
      expect(beats.first, 0);
      // 60000/137 = 437.956...
      expect(beats[1], 438);
      expect(beats.every((ms) => ms >= 0), isTrue);
    });

    test('no tempo is no grid, not an empty answer that looks like one', () {
      expect(Multitrack.beatsForTempo(bpm: 0, throughMs: 2000), isEmpty);
      expect(Multitrack.beatsForTempo(bpm: 120, throughMs: 0), isEmpty);
    });
  });
}
