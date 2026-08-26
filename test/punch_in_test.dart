import 'dart:typed_data';

import 'package:colabroom/services/multitrack.dart';
import 'package:flutter_test/flutter_test.dart';

/// Where a take sits, as opposed to how much of its front to throw away.
///
/// Two numbers live at the front of every take, both in milliseconds, and
/// confusing them is the whole risk here:
///
///   * offsetMs is the latency TRIM — drop this much of the recording.
///   * startMs is the PLACEMENT — the take belongs this far into the song.
///
/// Before punching in, every take was mixed from zero and only the trim
/// existed. A harmony recorded over the last chorus would have been mixed
/// over the intro.

Take _take({
  required String id,
  int offsetMs = 0,
  int startMs = 0,
  double gain = 1.0,
  bool enabled = true,
}) {
  return Take(
    id: id,
    path: '/tmp/$id.wav',
    label: id,
    recordedAt: DateTime(2026),
    offsetMs: offsetMs,
    startMs: startMs,
    gain: gain,
    enabled: enabled,
  );
}

Float64List _flat(double value, int length) =>
    Float64List.fromList(List<double>.filled(length, value));

void main() {
  const rate = Multitrack.rate;

  test('a take placed late is silent before it starts', () {
    final result = Multitrack.mix(
      <Take>[
        _take(id: 'song'),
        _take(id: 'harmony', startMs: 1000),
      ],
      <Float64List>[_flat(0.2, rate * 3), _flat(0.5, rate)],
    );

    // Before one second: the song only.
    expect(result.samples[rate ~/ 2], closeTo(0.2, 1e-9));
    // After: both.
    expect(result.samples[rate + 100], closeTo(0.7, 1e-9));
    // And after the harmony ends, the song again.
    expect(result.samples[rate * 2 + 100], closeTo(0.2, 1e-9));
  });

  test('a take punched in near the end can run past the song', () {
    // A harmony started over the last chorus that overruns. The mix has to
    // grow to hold it rather than truncating somebody's playing.
    final result = Multitrack.mix(
      <Take>[
        _take(id: 'song'),
        _take(id: 'tail', startMs: 2000),
      ],
      <Float64List>[_flat(0.2, rate * 3), _flat(0.4, rate * 2)],
    );

    expect(result.samples.length, rate * 4);
    expect(result.samples[rate * 3 + 100], closeTo(0.4, 1e-9));
  });

  test('placement and trim are different numbers and both apply', () {
    // Punched in at one second, and 200ms of latency to trim off the front.
    // The take should be heard from 1.0s, starting at its 200ms mark.
    final take = _flat(0.0, rate);
    for (var i = (rate * 0.2).round(); i < take.length; i += 1) {
      take[i] = 0.6;
    }

    final result = Multitrack.mix(
      <Take>[
        _take(id: 'song'),
        _take(id: 'late', startMs: 1000, offsetMs: 200),
      ],
      <Float64List>[_flat(0.1, rate * 3), take],
    );

    // Just before the punch-in: song only.
    expect(result.samples[rate - 200], closeTo(0.1, 1e-9));
    // Just after: the trimmed take is already at full level, because the
    // silent 200ms was dropped rather than played at 1.0s.
    expect(result.samples[rate + 200], closeTo(0.7, 1e-9));
  });

  test('a take with no placement still starts at the top', () {
    // Every take recorded before punching in existed has startMs 0, and must
    // keep behaving exactly as it did.
    final result = Multitrack.mix(
      <Take>[_take(id: 'a'), _take(id: 'b')],
      <Float64List>[_flat(0.2, 100), _flat(0.3, 100)],
    );

    expect(result.samples.length, 100);
    expect(result.samples[0], closeTo(0.5, 1e-9));
  });

  test('a muted take does not stretch the mix to reach its placement', () {
    final result = Multitrack.mix(
      <Take>[
        _take(id: 'song'),
        _take(id: 'muted', startMs: 60000, enabled: false),
      ],
      <Float64List>[_flat(0.2, rate), _flat(0.5, rate)],
    );

    expect(result.samples.length, rate);
  });
}
