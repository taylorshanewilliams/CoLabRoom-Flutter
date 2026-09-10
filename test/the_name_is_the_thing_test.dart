import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/songs/songs_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The room's name, without a sticker on it.
///
/// Taylor: "There are small little icon/images throughout the app, little red
/// guitars, a yellow light bulb, tiny microphone for example, they look a
/// little cheesy and dont seem to really be serving a purpose... if that bulb
/// was gone, ideas could be slightly larger, and where the room name south
/// dean is, theres a red guitar, if that guitar was gone South Dean could be
/// slightly larger."
///
/// The trade was real and it was being made the wrong way round: twenty
/// points of emoji beside a sixteen-point name, on the one word that says
/// which place you are looking at.
///
/// `room.icon` is still written and still stored. It is a column with a
/// default, a thing rooms were given before they could have a logo of their
/// own, and nothing now draws it — a room with a real uploaded logo shows
/// that, and a room without one is named rather than decorated.
Future<MusicBetaController> _rooms(WidgetTester tester) async {
  final controller = MusicBetaController(InMemoryMusicRepository.seeded());
  await controller.load();
  addTearDown(controller.dispose);
  return controller;
}

/// Every glyph the room picker used to offer, plus the two the seed uses.
const List<String> _glyphs = <String>['♪', '♬', '♫', '🎸', '🎹', '🎤', '💡'];

Iterable<String> _allText(WidgetTester tester) sync* {
  for (final element in find.byType(Text).evaluate()) {
    final widget = element.widget as Text;
    final data = widget.data;
    if (data != null) yield data;
  }
}

void main() {
  testWidgets('no room glyph is drawn in the library', (tester) async {
    final controller = await _rooms(tester);
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(BetaScope(
      controller: controller,
      child: MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: Scaffold(
          body: SongsScreen(
            displayName: 'Taylor',
            onOpenAccount: () {},
            onOpenNotifications: () {},
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('After Hours Studio'), findsWidgets,
        reason: 'the name is still there — it is the only thing that was');

    for (final text in _allText(tester)) {
      for (final glyph in _glyphs) {
        expect(text.contains(glyph), isFalse,
            reason: 'found "$glyph" in "$text"');
      }
    }
  });

  testWidgets('nor on the Rooms segment', (tester) async {
    final controller = await _rooms(tester);
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(BetaScope(
      controller: controller,
      child: MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: Scaffold(
          body: SongsScreen(
            displayName: 'Taylor',
            onOpenAccount: () {},
            onOpenNotifications: () {},
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Rooms'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Acoustic Ideas'), findsOneWidget);
    for (final text in _allText(tester)) {
      for (final glyph in _glyphs) {
        expect(text.contains(glyph), isFalse,
            reason: 'found "$glyph" in "$text"');
      }
    }
  });

  test('the glyph is still stored, so nothing that reads it breaks', () async {
    final controller = MusicBetaController(InMemoryMusicRepository.seeded());
    await controller.load();
    addTearDown(controller.dispose);

    // Removing it from the screens is a display change. The column keeps its
    // value, because a migration to drop it would be a real risk taken for a
    // cosmetic reason.
    expect(controller.rooms.first.icon, isNotEmpty);
  });
}
