import 'package:audioplayers/audioplayers.dart';
import 'package:colabroom/services/audio_source_for.dart';
import 'package:flutter_test/flutter_test.dart';

/// Audio that plays in a browser.
///
/// Taylor's first-ever bug report, sent through the app on 2026-09-10 — the
/// same day the reporting was fixed enough to carry it — arrived with its own
/// diagnosis attached:
///
///     MissingPluginException(No implementation found for method
///     getApplicationDocumentsDirectory on channel
///     plugins.flutter.io/path_provider)
///
/// Every service in this app held audio as a local file path: download the
/// bytes into a temporary directory, hand the player the path. That is right
/// on a phone. In a browser there is no filesystem, and `path_provider` does
/// not degrade gracefully — it throws, which is why the Takes screen told
/// everybody on app.colabroom.com that the song had a recording it could not
/// load.
///
/// The services return a signed URL on the web now, and this decides which
/// kind of source to build from whichever string it is handed.
void main() {
  test('a signed URL becomes a streaming source', () {
    // Signing is the permission check — Supabase applies row level security
    // when the URL is created, not when it is used — so a URL only exists for
    // a recording the person was already allowed to hear.
    final source = audioSourceFor(
      'https://abc.supabase.co/storage/v1/object/sign/room-files/a/b.m4a?token=x',
    );
    expect(source, isA<UrlSource>());
  });

  test('a file path stays a file', () {
    // The phone path must not move. A local file survives the screen that
    // fetched it and can be seeked into without asking the network anything.
    expect(
      audioSourceFor('/data/user/0/com.colabroom.beta/files/layers/x/y.m4a'),
      isA<DeviceFileSource>(),
    );
  });

  test('matched on the scheme, not on the platform', () {
    // Deliberate: the caller should not have to know which platform produced
    // the string it is holding, and a URL handed to a phone works there too.
    expect(audioSourceFor('http://example.com/a.mp3'), isA<UrlSource>());
    expect(audioSourceFor('  https://example.com/a.mp3  '), isA<UrlSource>());
    expect(audioSourceFor('C:/Users/x/a.mp3'), isA<DeviceFileSource>());
  });

  test('what can be mixed and what can only be streamed', () {
    // The difference that genuinely matters: a local file can be handed to a
    // decoder or a mixdown, and a URL cannot. That is why the multi-track
    // console is not available in a browser, and why the screen says so
    // rather than doing nothing when the button is pressed.
    expect(isRemoteAudio('https://example.com/a.mp3'), isTrue);
    expect(isRemoteAudio('/tmp/a.wav'), isFalse);
  });
}
