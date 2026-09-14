import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:colabroom/features/workspace/tuner_sheet.dart';
import 'package:colabroom/services/pitch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A tuner is the one thing every musician opens every day. This is the
/// phone hearing one note: the detector on synthetic strings, the naming,
/// and the sheet fed a sine wave instead of a microphone.
Float64List tone(double hz, {int samples = 4096, int rate = 44100, List<double> partials = const <double>[1]}) {
  final out = Float64List(samples);
  for (var i = 0; i < samples; i++) {
    var v = 0.0;
    for (var k = 0; k < partials.length; k++) {
      v += partials[k] * math.sin(2 * math.pi * hz * (k + 1) * i / rate);
    }
    out[i] = v * 0.4;
  }
  return out;
}

Uint8List pcm16(Float64List floats) {
  final bytes = ByteData(floats.length * 2);
  for (var i = 0; i < floats.length; i++) {
    bytes.setInt16(i * 2, (floats[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
  }
  return bytes.buffer.asUint8List();
}

void main() {
  group('hearing a frequency', () {
    test('a pure A', () {
      expect(detectPitch(tone(440), 44100), closeTo(440, 0.5));
    });

    test('a guitar low E, whose loudest partial is not its fundamental', () {
      // The case an FFT peak gets wrong by an octave.
      final e2 = tone(82.41, partials: const <double>[0.4, 1.0, 0.6, 0.3]);
      expect(detectPitch(e2, 44100), closeTo(82.41, 0.6));
    });

    test('a high E, the other end of the guitar', () {
      expect(detectPitch(tone(329.63, partials: const <double>[1, 0.5, 0.2]), 44100), closeTo(329.63, 0.6));
    });

    test('silence and the hum of a room are not a note', () {
      expect(detectPitch(Float64List(4096), 44100), isNull);
      final random = math.Random(7);
      final noise = Float64List.fromList(List<double>.generate(4096, (_) => (random.nextDouble() - 0.5) * 0.02));
      expect(detectPitch(noise, 44100), isNull);
    });

    test('pcm16 bytes become floats in -1..1', () {
      final floats = pcm16ToFloats(pcm16(tone(440)));
      expect(floats.length, 4096);
      expect(floats.reduce(math.max), lessThanOrEqualTo(1));
      expect(detectPitch(floats, 44100), closeTo(440, 0.5));
    });
  });

  group('naming it', () {
    test('A4 is A, octave 4, dead on', () {
      final r = readPitch(440)!;
      expect(r.name, 'A');
      expect(r.octave, 4);
      expect(r.cents, closeTo(0, 0.01));
      expect(r.inTune, isTrue);
      expect(r.label, 'A4');
    });

    test('a little sharp is said in cents', () {
      final r = readPitch(446)!;
      expect(r.name, 'A');
      expect(r.cents, closeTo(23.4, 0.5));
      expect(r.inTune, isFalse);
    });

    test('the guitar strings', () {
      expect(readPitch(82.41)!.label, 'E2');
      expect(readPitch(110)!.label, 'A2');
      expect(readPitch(146.83)!.label, 'D3');
      expect(readPitch(196)!.label, 'G3');
      expect(readPitch(246.94)!.label, 'B3');
      expect(readPitch(329.63)!.label, 'E4');
    });

    test('sharps are spelled with the sign, and middle C is C4', () {
      expect(readPitch(277.18)!.label, 'C♯4');
      expect(readPitch(261.63)!.label, 'C4');
      expect(readPitch(null), isNull);
    });
  });

  testWidgets('fed an A, the sheet says A and in tune', (tester) async {
    final controller = StreamController<Uint8List>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TunerSheet(openStream: () async => controller.stream),
      ),
    ));
    // A test stream opens at once, so the "opening" hint is gone before the
    // first frame can be looked at.
    await tester.pump();
    await tester.pump();
    expect(find.text('Play one string, or sing one note.'), findsOneWidget);

    // Three frames, so the median has something to be the median of.
    for (var i = 0; i < 3; i++) {
      controller.add(pcm16(tone(440)));
      await tester.pump();
    }
    await tester.pump();

    expect(find.byKey(const Key('tuner_note')), findsOneWidget);
    expect(find.text('In tune.'), findsOneWidget);
    expect(find.textContaining('440.0 Hz'), findsOneWidget);

    // Then a sharp one.
    for (var i = 0; i < 3; i++) {
      controller.add(pcm16(tone(446)));
      await tester.pump();
    }
    await tester.pump();
    expect(find.text('A little sharp — loosen.'), findsOneWidget);

    await controller.close();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
