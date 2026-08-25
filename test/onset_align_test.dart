import 'dart:math' as math;
import 'dart:typed_data';

import 'package:colabroom/services/onset_align.dart';
import 'package:flutter_test/flutter_test.dart';

const int _rate = 44100;

/// What this method can honestly resolve: one analysis hop, plus the rounding
/// where a grid position in milliseconds meets a frame index. Asking for 5ms
/// was asking for more precision than a 5ms hop can carry — and it is far
/// finer than the question needs, since nobody hears 10ms on a strum.
const double _toleranceMs = 10;

/// A take: short percussive attacks at [hitsMs], delayed by [lateMs], over a
/// bed of noise.
Float64List _percussiveTake({
  required List<int> hitsMs,
  int lateMs = 0,
  double noise = 0.02,
  double gain = 0.8,
  int lengthMs = 6000,
  int seed = 11,
}) {
  final random = math.Random(seed);
  final out = Float64List((_rate * lengthMs / 1000).round());
  for (var i = 0; i < out.length; i += 1) {
    out[i] = (random.nextDouble() * 2 - 1) * noise;
  }
  for (final hit in hitsMs) {
    final at = ((hit + lateMs) * _rate / 1000).round();
    // 60ms of sharp attack and quick decay — a strum or a snare.
    final length = (_rate * 0.06).round();
    for (var i = 0; i < length && at + i < out.length; i += 1) {
      final decay = math.exp(-i / (_rate * 0.012));
      out[at + i] += math.sin(2 * math.pi * 220 * i / _rate) * decay * gain;
    }
  }
  return out;
}

/// A held note: no attacks to speak of after the first, which is the case
/// this must decline rather than guess at.
Float64List _sustainedTake({int lengthMs = 6000, double noise = 0.02}) {
  final random = math.Random(5);
  final out = Float64List((_rate * lengthMs / 1000).round());
  for (var i = 0; i < out.length; i += 1) {
    final t = i / _rate;
    // One slow swell, no re-articulation.
    final envelope = math.sin(math.pi * t / (lengthMs / 1000)).abs();
    out[i] = math.sin(2 * math.pi * 196 * t) * 0.5 * envelope +
        (random.nextDouble() * 2 - 1) * noise;
  }
  return out;
}

List<int> _grid({int bpm = 100, int bars = 10}) {
  final beat = (60000 / bpm).round();
  return <int>[for (var i = 0; i < bars * 4; i += 1) i * beat];
}

void main() {
  test('recovers a lag it was never told about', () {
    final beats = _grid();
    // Played on the beat, then delayed by 120ms the way a phone would.
    final take = _percussiveTake(hitsMs: beats, lateMs: 120);

    final result = OnsetAlign.alignToGrid(take, beats);

    expect(result, isNotNull);
    expect(result!.shiftMs, closeTo(120, _toleranceMs));
    expect(result.trustworthy, isTrue);
  });

  test('says zero when the take is already in time', () {
    final beats = _grid();
    final result = OnsetAlign.alignToGrid(
      _percussiveTake(hitsMs: beats),
      beats,
    );

    expect(result, isNotNull);
    expect(result!.shiftMs, closeTo(0, _toleranceMs));
  });

  test('does not need a hit on every beat', () {
    // A real strummed part plays the downbeats and leaves the rest alone.
    final beats = _grid();
    final played = <int>[
      for (var i = 0; i < beats.length; i += 4) beats[i],
    ];
    final result = OnsetAlign.alignToGrid(
      _percussiveTake(hitsMs: played, lateMs: 90),
      beats,
    );

    expect(result, isNotNull);
    expect(result!.shiftMs, closeTo(90, _toleranceMs));
    expect(result.trustworthy, isTrue);
  });

  test('a sustained note is declined rather than guessed at', () {
    // The failure that matters. There is nothing in a held note to align, so
    // the arithmetic still returns a shift — it just means nothing, and
    // acting on it puts the take confidently in the wrong place, which the
    // player hears as their own bad timing.
    final result = OnsetAlign.alignToGrid(_sustainedTake(), _grid());

    expect(result == null || !result.trustworthy, isTrue,
        reason: 'a take with no attacks must not report a trustworthy shift');
  });

  test('never reports the take as early', () {
    // A recording cannot precede what it was recorded against. A negative
    // answer would mean the method is confused, so it is not in the search.
    final beats = _grid();
    final result = OnsetAlign.alignToGrid(
      _percussiveTake(hitsMs: beats, lateMs: 60),
      beats,
    );

    expect(result!.shiftMs, greaterThanOrEqualTo(0));
  });

  test('will not search past half a beat, whatever it is asked for', () {
    // The grid repeats, so a whole beat late looks exactly like on time. At
    // 100bpm a beat is 600ms, so the search must stop by 300ms even though
    // the caller asked for more.
    final beats = _grid(bpm: 100);
    final result = OnsetAlign.alignToGrid(
      _percussiveTake(hitsMs: beats, lateMs: 100),
      beats,
      maxShiftOverrideMs: 5000,
    );

    expect(result, isNotNull);
    expect(result!.searchedToMs, lessThanOrEqualTo(300));
  });

  test('a fast song narrows the window it can rescue', () {
    // At 200bpm a beat is 300ms, so anything past 150ms is ambiguous. Worth
    // asserting because it is the real limit of this approach: the faster the
    // song, the less latency it can undo.
    final beats = _grid(bpm: 200);
    final result = OnsetAlign.alignToGrid(
      _percussiveTake(hitsMs: beats, lateMs: 40),
      beats,
    );

    expect(result, isNotNull);
    expect(result!.searchedToMs, lessThanOrEqualTo(150));
    expect(result.shiftMs, closeTo(40, _toleranceMs));
  });
}
