import 'package:colabroom/services/now_playing.dart';
import 'package:colabroom/widgets/now_playing_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Does the music keep playing when you look somewhere else?
///
/// Every play button in this app stopped mattering the moment somebody
/// scrolled: sound belonged to whichever screen started it. Browsing the Open
/// Mic meant starting a song, deciding, and starting another — three
/// deliberate acts where a listening app has one continuous one.
///
/// **These do not touch the player.** `AudioPlayer` talks to a platform
/// channel that does not exist in a widget test, so calling play or stop here
/// would test the absence of a plugin rather than the bar. What is asserted
/// is the one thing that can go wrong without any audio at all: the bar
/// appearing when nothing is playing, and taking 56 pixels from every screen
/// to say "silence".
void main() {
  Widget wrap(Widget child) =>
      MaterialApp(home: Scaffold(bottomNavigationBar: child));

  testWidgets('nothing playing takes no room at all', (tester) async {
    await tester.pumpWidget(wrap(NowPlayingBar(onOpen: (_) {})));
    await tester.pump();

    expect(find.byKey(const Key('now_playing_bar')), findsNothing);
    expect(find.byKey(const Key('now_playing_toggle')), findsNothing);
    expect(find.byKey(const Key('now_playing_stop')), findsNothing);
  });

  test('an empty path is never the thing playing', () {
    // Every silent row in a list carries an empty path. If one of those
    // counted as current, the bar would appear the moment anything drew and
    // every one of those rows would light up together.
    expect(NowPlaying.instance.isCurrent(''), isFalse);
    expect(NowPlaying.instance.path, isNull);
    expect(NowPlaying.instance.title, isEmpty);
    expect(NowPlaying.instance.songId, isNull);
  });
}
