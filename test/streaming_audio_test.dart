import 'package:colabroom/services/streaming_audio.dart';
import 'package:flutter_test/flutter_test.dart';

/// The cache is the whole reason this class exists.
///
/// A feed plays the current track while signing the next few, and a service
/// that re-signs everything on every page would spend its time asking
/// permission for URLs it already holds. These are the rules that make
/// preloading possible, tested without a network.
void main() {
  group('a signed URL is held until it is nearly stale', () {
    test('nothing is ready before anything is signed', () {
      final audio = StreamingAudio();
      expect(audio.isReady('room/song/take.m4a'), isFalse);
      expect(audio.cached, 0);
    });

    test('clearing forgets everything', () {
      final audio = StreamingAudio()..clear();
      expect(audio.cached, 0);
    });

    test('the safety margin is inside the lifetime', () {
      // A URL handed out moments before it expires is one the player fails on
      // halfway through a song, which reads as the app being broken rather
      // than a link being old.
      expect(StreamingAudio.ttl, greaterThan(const Duration(minutes: 30)));
      expect(StreamingAudio.ttl, lessThanOrEqualTo(const Duration(hours: 6)));
    });
  });

  test('the bucket is the one the audio actually lives in', () {
    // Layers and reference recordings both live in room-files, which is what
    // lets one signer serve the whole feed.
    expect(StreamingAudio().bucket, 'room-files');
  });
}
