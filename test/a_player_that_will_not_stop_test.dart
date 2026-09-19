import 'package:colabroom/services/now_playing.dart';
import 'package:flutter_test/flutter_test.dart';

/// Play swallows a stop that fails.
///
/// The third of the leaks in "a recording that fails cleans up after itself".
/// NowPlaying.play stops whatever was sounding before it takes the new path,
/// and that one call sat outside any try — while everything under it is
/// caught: a recording that will not sign goes quiet, a source that will not
/// play goes quiet, and the button goes back to how it was. So a player that
/// would not stop was the one way a tap on a row in a feed could throw out of
/// the button that was pressed.
///
/// Its own file rather than a group in the other one. There is no audio
/// plugin in a test, so the player fails at construction; a widget test
/// builds its players inside a fake clock, and a later plain test asking the
/// same global scope whether it is ready waits on a future that clock will
/// never complete. Nothing here builds a widget, so nothing can.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a play that cannot stop the last one still fails quietly', () async {
    // With no plugin behind it the player throws MissingPluginException out
    // of stop(), which is what a browser tab that has lost its audio context
    // does too. The test is that this returns at all.
    await NowPlaying.instance.play('room-1/project-1/analysis/reference.m4a');

    expect(NowPlaying.instance.playing, isFalse);
    // Nothing could be signed either, which is the quiet answer play() gives
    // for a recording it cannot reach: no path loaded and no exception.
    expect(NowPlaying.instance.path, isNull);
  });
}
