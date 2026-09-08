import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/openmic/ask_somebody_not_here.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reaching past the edge of the room.
///
/// The Open Mic can only offer the people already in it, and after the seeded
/// accounts went that is four. But nobody looking for a bass player has run
/// out of bass players — they have run out of bass players *on this app*, and
/// they almost certainly know one.
///
/// The message is the whole feature, so the message is what is tested. "Join
/// my app" is a favour somebody is asking. "I want you to play bass on this
/// song" is a compliment with a reason attached, and it has to survive every
/// future tidy-up of this file intact.
Future<void> _open(WidgetTester tester, {String? about}) async {
  tester.view.physicalSize = const Size(390, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    theme: CoLabRoomTheme.dark(),
    home: Scaffold(
      body: AskSomebodyNotHere(
        repository: InMemoryMusicRepository.seeded(),
        myName: 'Taylor',
        about: about,
      ),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 80));
}

Future<void> _write(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField), 'sam@example.com');
  await tester.tap(find.text('Write the message'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 120));
}

void main() {
  testWidgets('the message leads with the ask, never with the product',
      (tester) async {
    await _open(tester, about: 'bass');
    await _write(tester);

    expect(find.textContaining('Taylor would like you to play bass on'),
        findsOneWidget);
    // The promise that makes it safe to accept from somebody you half know.
    expect(find.textContaining('nothing else of theirs'), findsOneWidget);
    expect(find.textContaining('invite code'), findsOneWidget);
  });

  testWidgets('and it works without knowing what you want', (tester) async {
    await _open(tester);
    await _write(tester);

    // "Play on" rather than a part somebody never named. Not knowing what a
    // song needs is the normal state of an unfinished song.
    expect(find.textContaining('would like you to play on'), findsOneWidget);
  });

  testWidgets('it says the app is needed rather than promising a link',
      (tester) async {
    await _open(tester, about: 'bass');
    await _write(tester);

    // There is no public download yet. A message inventing one would be the
    // app lying in the first sentence anybody reads about it.
    expect(find.textContaining('They will need the app'), findsOneWidget);
  });
}
