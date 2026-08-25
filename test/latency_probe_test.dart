import 'dart:math' as math;
import 'dart:typed_data';

import 'package:colabroom/services/latency_probe.dart';
import 'package:flutter_test/flutter_test.dart';

/// A recording that contains the calibration signal delayed by [offset]
/// samples, buried in room noise at [noise] amplitude.
Float64List _fakeRecording({
  required int offset,
  double noise = 0.05,
  double gain = 0.6,
  int? gapOverride,
  int seed = 7,
}) {
  final random = math.Random(seed);
  final pulse = LatencyProbe.marker();
  final lead = (LatencyProbe.sampleRate * 0.25).round();
  final gap = gapOverride ?? LatencyProbe.sampleRate;
  final total = offset + lead + gap + pulse.length + LatencyProbe.sampleRate;
  final out = Float64List(total);
  for (var i = 0; i < total; i += 1) {
    out[i] = (random.nextDouble() * 2 - 1) * noise;
  }
  for (var i = 0; i < pulse.length; i += 1) {
    out[offset + lead + i] += pulse[i] * gain;
    out[offset + lead + gap + i] += pulse[i] * gain;
  }
  return out;
}

void main() {
  test('finds the marker where it was planted', () {
    final pulse = LatencyProbe.marker();
    final recording = _fakeRecording(offset: 4410);
    final match = LatencyProbe.locate(recording, pulse);

    expect(match, isNotNull);
    // The lead silence is part of the signal, so the first marker sits at
    // offset + lead. read() is what subtracts the lead; locate() does not.
    expect(match!.offsetSamples, closeTo(4410 + (44100 * 0.25).round(), 2));
    expect(match.confidence, greaterThan(3.0));
  });

  test('reports the lag an overdub would have to be shifted by', () {
    // 150ms is an ordinary Android round trip.
    final offset = (LatencyProbe.sampleRate * 0.150).round();
    final reading = LatencyProbe.read(_fakeRecording(offset: offset));

    expect(reading, isNotNull);
    expect(reading!.offsetMs, closeTo(150, 1));
    expect(reading.plausible, isTrue);
  });

  test('a drifting clock shows up as gap error, not as lag', () {
    // Same start, but the markers come back 1.02s apart instead of 1.00s.
    // A fixed offset cannot rescue this, so the two have to be told apart.
    final reading = LatencyProbe.read(_fakeRecording(
      offset: 4410,
      gapOverride: (LatencyProbe.sampleRate * 1.02).round(),
    ));

    expect(reading, isNotNull);
    expect(reading!.offsetMs, closeTo(100, 1));
    expect(reading.clockErrorMs, isNotNull);
    expect(reading.clockErrorMs!, closeTo(20, 1));
  });

  test('refuses a recording with no marker in it rather than guessing', () {
    // The failure that matters. A silent take, a dead microphone, or a
    // muted phone must not produce a confident number — a wrong offset is
    // applied silently and puts every later overdub out of time.
    final random = math.Random(3);
    final noiseOnly = Float64List(LatencyProbe.sampleRate * 2);
    for (var i = 0; i < noiseOnly.length; i += 1) {
      noiseOnly[i] = (random.nextDouble() * 2 - 1) * 0.05;
    }

    expect(LatencyProbe.read(noiseOnly), isNull);
  });

  test('survives a room louder than the marker', () {
    final reading = LatencyProbe.read(_fakeRecording(
      offset: 8820,
      noise: 0.25,
      gain: 0.2,
    ));

    expect(reading, isNotNull);
    expect(reading!.offsetMs, closeTo(200, 2));
  });

  test('audio survives the round trip through a wav file', () {
    final original = LatencyProbe.calibrationSignal();
    final restored = LatencyProbe.fromWav(LatencyProbe.toWav(original));

    expect(restored.length, original.length);
    for (var i = 0; i < original.length; i += 997) {
      // 16-bit quantisation is the only thing allowed to change.
      expect(restored[i], closeTo(original[i], 1 / 32767));
    }
  });

  test('a wav with an extra chunk before the data still reads', () {
    // record is free to emit LIST or fact chunks and some Android encoders
    // do. Assuming a 44-byte header reads the chunk as samples, and the
    // recording comes back as noise with no explanation.
    final plain = LatencyProbe.toWav(LatencyProbe.marker());
    final extra = BytesBuilder()
      ..add(plain.sublist(0, 36))
      ..add(Uint8List.fromList('LIST'.codeUnits))
      ..add(Uint8List.fromList(<int>[4, 0, 0, 0]))
      ..add(Uint8List.fromList(<int>[1, 2, 3, 4]))
      ..add(plain.sublist(36));

    final restored = LatencyProbe.fromWav(extra.toBytes());
    expect(restored.length, LatencyProbe.marker().length);
  });
}
