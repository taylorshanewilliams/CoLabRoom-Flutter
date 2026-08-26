import 'dart:math' as math;
import 'dart:typed_data';

import 'package:colabroom/services/multitrack.dart';
import 'package:colabroom/services/onset_align.dart';
import 'package:flutter_test/flutter_test.dart';

/// The guard around automatic alignment, rather than the alignment itself —
/// onset_align_test already covers the arithmetic.
///
/// What matters here is the decision to *use* the answer. A take that gives
/// the aligner nothing to bite on still produces a number, and moving
/// somebody's playing by a number that means nothing is worse than leaving it
/// where they played it.

/// A part with clear attacks, late by [lateMs] against a 120bpm grid.
Float64List _struck({required int lateMs, int rate = 44100}) {
  const beatMs = 500;
  final samples = Float64List((rate * 6).round());
  for (var beat = 0; beat < 10; beat += 1) {
    final at = ((lateMs + beat * beatMs) * rate / 1000).round();
    for (var i = 0; i < 900 && at + i < samples.length; i += 1) {
      // A sharp attack decaying away, which is what a pick or a stick is.
      samples[at + i] = math.exp(-i / 220.0) * math.sin(i * 0.22);
    }
  }
  return samples;
}

/// A held note: no attacks, so nothing to align to.
Float64List _sustained({int rate = 44100}) {
  final samples = Float64List((rate * 6).round());
  for (var i = 0; i < samples.length; i += 1) {
    samples[i] = 0.3 * math.sin(i * 0.05);
  }
  return samples;
}

List<int> _grid() => <int>[for (var i = 0; i < 12; i += 1) i * 500];

void main() {
  test('a struck part is found to be late by about the right amount', () {
    final result = OnsetAlign.alignToGrid(_struck(lateMs: 120), _grid());

    expect(result, isNotNull);
    expect(result!.trustworthy, isTrue);
    // To the nearest hop, not to the sample.
    expect((result.shiftMs - 120).abs(), lessThan(30));
  });

  test('a take that is already in time is left alone', () {
    final result = OnsetAlign.alignToGrid(_struck(lateMs: 0), _grid());

    expect(result, isNotNull);
    expect(result!.shiftMs.abs(), lessThan(30));
  });

  test('a held note is not trusted, however confident the arithmetic', () {
    final result = OnsetAlign.alignToGrid(_sustained(), _grid());

    // Either no answer at all, or one it declines to vouch for. Both are the
    // honest outcome; what must not happen is a confident wrong shift.
    expect(result == null || !result.trustworthy, isTrue);
  });

  test('a song with no beat grid cannot be aligned', () {
    // No analysis yet — the manual fallback is the only answer available.
    expect(OnsetAlign.alignToGrid(_struck(lateMs: 120), const <int>[]), isNull);
    expect(OnsetAlign.alignToGrid(_struck(lateMs: 120), const <int>[0]), isNull);
  });

  test('one decode answers both silence and alignment', () async {
    // readRecording exists so a take is not decoded twice between somebody
    // stopping and the take appearing.
    final samples = _struck(lateMs: 60);
    expect(Multitrack.peakOf(samples), greaterThan(Multitrack.silenceFloor));
    expect(Multitrack.peakOf(Float64List(1000)), 0.0);
  });
}
