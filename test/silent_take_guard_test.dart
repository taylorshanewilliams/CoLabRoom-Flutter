import 'package:flutter_test/flutter_test.dart';

/// The arithmetic behind refusing a take that recorded nothing.
///
/// Two takes have now reached the database at exactly 2,486 bytes — once for
/// 4,000 ms and once for 3,600 ms. Both were AAC-LC asked for 96 kbps, which
/// is 12,000 bytes a second, so both were about six per cent of a recording.
/// Both were saved, and both were parts nobody could hear.
///
/// The decoded-peak check missed the second one: encoded silence decodes to a
/// noise floor, and a floor low enough never to reject a real quiet take is
/// also low enough to accept that. Weight is the blunter instrument and the
/// harder one to fool.

const int bitRate = 96000;
const double expectedBytesPerSecond = bitRate / 8;

/// Mirrors the guard in song_layers_screen.
bool wouldBeRefused({required int bytes, required int durationMs}) {
  final seconds = durationMs / 1000;
  if (seconds <= 0.5) return false;
  return bytes < expectedBytesPerSecond * seconds * 0.25;
}

void main() {
  test('the take that started all of this is refused', () {
    expect(wouldBeRefused(bytes: 2486, durationMs: 4000), isTrue);
  });

  test('and the one that came back a second time', () {
    expect(wouldBeRefused(bytes: 2486, durationMs: 3600), isTrue);
  });

  test('a real recording is kept', () {
    // The take that worked: recorded dry, with nothing playing.
    expect(wouldBeRefused(bytes: 41073, durationMs: 3200), isFalse);
  });

  test('a quiet real take is still kept', () {
    // Half the expected weight is a legitimately sparse performance — a held
    // note, somebody playing softly. The guard must not reach that far.
    expect(
      wouldBeRefused(bytes: (expectedBytesPerSecond * 4 * 0.5).round(), durationMs: 4000),
      isFalse,
    );
  });

  test('an empty container does not grow with the take it claims to be', () {
    // The clue that reframed this. Two takes, two durations, byte-identical
    // sizes — 2,486 bytes for 4,000 ms and again for 3,600 ms. Encoded
    // silence still costs *something* per second, so a size that does not
    // move with duration is a container with no frames in it: the encoder
    // never started. Both are refused, and the ratio is what refuses them.
    expect(wouldBeRefused(bytes: 2486, durationMs: 4000), isTrue);
    expect(wouldBeRefused(bytes: 2486, durationMs: 3600), isTrue);
    expect(wouldBeRefused(bytes: 2486, durationMs: 30000), isTrue);
  });

  test('a very short take is left alone', () {
    // Container overhead dominates under half a second, so the ratio means
    // nothing there and refusing on it would reject real stabs.
    expect(wouldBeRefused(bytes: 300, durationMs: 400), isFalse);
  });
}
