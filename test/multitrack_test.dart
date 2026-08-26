import 'dart:io';
import 'dart:typed_data';

import 'package:colabroom/services/latency_probe.dart';
import 'package:colabroom/services/multitrack.dart';
import 'package:flutter_test/flutter_test.dart';

Take _take({
  int offsetMs = 0,
  double gain = 1.0,
  bool enabled = true,
  String id = 'a',
}) {
  return Take(
    id: id,
    path: '/tmp/$id.wav',
    label: id,
    recordedAt: DateTime(2026),
    offsetMs: offsetMs,
    gain: gain,
    enabled: enabled,
  );
}

Float64List _flat(double value, int length) =>
    Float64List.fromList(List<double>.filled(length, value));

void main() {
  test('layers add up', () {
    final result = Multitrack.mix(
      <Take>[_take(id: 'riff'), _take(id: 'vocal')],
      <Float64List>[_flat(0.2, 100), _flat(0.3, 100)],
    );

    expect(result.samples.length, 100);
    expect(result.samples[0], closeTo(0.5, 1e-9));
    expect(result.scaled, isFalse);
  });

  test('the mix is as long as its longest layer', () {
    // A vocal that runs past the riff it was sung over must not be truncated
    // to the riff's length.
    final result = Multitrack.mix(
      <Take>[_take(id: 'riff'), _take(id: 'vocal')],
      <Float64List>[_flat(0.2, 100), _flat(0.3, 250)],
    );

    expect(result.samples.length, 250);
    expect(result.samples[0], closeTo(0.5, 1e-9));
    // Past the riff, only the vocal remains.
    expect(result.samples[200], closeTo(0.3, 1e-9));
  });

  test('a muted take is left out without being lost', () {
    final result = Multitrack.mix(
      <Take>[_take(id: 'riff'), _take(id: 'vocal', enabled: false)],
      <Float64List>[_flat(0.2, 100), _flat(0.3, 100)],
    );

    expect(result.samples[0], closeTo(0.2, 1e-9));
  });

  test('a late take is pulled forward by its own offset', () {
    // 100ms of latency at 44.1kHz is 4410 samples. The take starts with that
    // much of the backing track already gone by, so the correction drops it.
    final late = Float64List(44100);
    for (var i = 4410; i < late.length; i += 1) {
      late[i] = 0.5;
    }

    final result = Multitrack.mix(
      <Take>[_take(id: 'vocal', offsetMs: 100)],
      <Float64List>[late],
    );

    // The first sample kept is now the first sample that was played.
    expect(result.samples[0], closeTo(0.5, 1e-9));
    expect(result.samples.length, 44100 - 4410);
  });

  test('a mix that would clip is turned down, not squared off', () {
    // Four loud layers sum past full scale. Hard clipping would sound like a
    // bad take rather than a full mix, so the whole thing scales instead —
    // which keeps the balance between layers exactly as it was.
    final result = Multitrack.mix(
      <Take>[for (var i = 0; i < 4; i += 1) _take(id: '$i')],
      <Float64List>[for (var i = 0; i < 4; i += 1) _flat(0.4, 50)],
    );

    expect(result.peak, closeTo(1.6, 1e-9));
    expect(result.scaled, isTrue);
    expect(result.samples[0], closeTo(0.99, 1e-6));
    // Relative balance survives: every sample scaled by the same factor.
    expect(result.samples[10], closeTo(result.samples[0], 1e-9));
  });

  test('per-take gain is respected', () {
    final result = Multitrack.mix(
      <Take>[_take(id: 'riff', gain: 0.5), _take(id: 'vocal')],
      <Float64List>[_flat(0.4, 20), _flat(0.2, 20)],
    );

    expect(result.samples[0], closeTo(0.4, 1e-9));
  });

  test('nothing enabled is an empty mix, not a crash', () {
    final result = Multitrack.mix(
      <Take>[_take(id: 'riff', enabled: false)],
      <Float64List>[_flat(0.2, 100)],
    );

    expect(result.samples, isEmpty);
  });

  test('an offset longer than the take does not read off the end', () {
    // Someone measures 400ms of latency, then records a 200ms stab. There is
    // nothing left after the correction, and that has to be empty rather
    // than an exception in the middle of a session.
    final result = Multitrack.mix(
      <Take>[_take(id: 'stab', offsetMs: 400)],
      <Float64List>[_flat(0.5, 8820)],
    );

    expect(result.samples, isEmpty);
  });

  test('a take survives the json round trip', () {
    final original = _take(id: 'lead', offsetMs: 120, gain: 0.8, enabled: false);
    final restored = Take.fromJson(original.toJson());

    expect(restored.id, 'lead');
    expect(restored.offsetMs, 120);
    expect(restored.gain, 0.8);
    expect(restored.enabled, isFalse);
    expect(restored.path, original.path);
  });

  group('reading a layer off disk', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('multitrack_samples');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Take fileTake(String name) => Take(
          id: name,
          path: '${tmp.path}/$name',
          label: name,
          recordedAt: DateTime(2026),
        );

    test('a wav layer is read directly', () async {
      final take = fileTake('a.wav');
      await File(take.path).writeAsBytes(
        LatencyProbe.toWav(_flat(0.25, 500)),
        flush: true,
      );

      final samples = await Multitrack.samplesFor(take);
      expect(samples.length, 500);
      expect(samples[0], closeTo(0.25, 1e-4));
    });

    test('a missing layer is silence, not an exception', () async {
      // Mid-session, a take whose file has gone must not take the mix down.
      expect(await Multitrack.samplesFor(fileTake('gone.wav')), isEmpty);
    });

    test('a layer that will not decode is silence, not an exception', () async {
      // Same reasoning, one step further in: everything else still plays, and
      // the take is still on disk and still exportable.
      final take = fileTake('broken.m4a');
      await File(take.path).writeAsBytes(
        Uint8List.fromList(List<int>.filled(64, 7)),
        flush: true,
      );

      expect(await Multitrack.samplesFor(take), isEmpty);
    });

    group('telling a silent take from a broken one', () {
      // The distinction the band actually experiences. Both used to arrive as
      // a part in the list that nobody could hear, and only one of them means
      // "record it again" — the other means the microphone never opened.

      test('a recording that captured nothing peaks at zero', () async {
        final take = fileTake('silence.wav');
        await File(take.path).writeAsBytes(
          LatencyProbe.toWav(_flat(0.0, 4000)),
          flush: true,
        );

        final peak = await Multitrack.peakOfRecording(take.path);
        expect(peak, isNotNull);
        expect(peak, lessThan(Multitrack.silenceFloor));
      });

      test('a real performance clears the floor by a wide margin', () async {
        // Quiet on purpose: an acoustic guitar picked up across a room. The
        // guard must never refuse to save something somebody played.
        final take = fileTake('quiet.wav');
        await File(take.path).writeAsBytes(
          LatencyProbe.toWav(_flat(0.05, 4000)),
          flush: true,
        );

        final peak = await Multitrack.peakOfRecording(take.path);
        expect(peak, isNotNull);
        expect(peak!, greaterThan(Multitrack.silenceFloor * 10));
      });

      test('a file that will not decode reports null, not silence', () async {
        final take = fileTake('rubbish.m4a');
        await File(take.path).writeAsBytes(
          Uint8List.fromList(List<int>.filled(64, 7)),
          flush: true,
        );

        expect(await Multitrack.peakOfRecording(take.path), isNull);
      });
    });
  });
}
