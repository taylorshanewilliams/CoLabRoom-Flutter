import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/rooms/room_detail_screen.dart';
import 'package:colabroom/features/songs/songs_screen.dart';
import 'package:colabroom/features/workspace/song_workspace_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The library stops disappearing.
///
/// Taylor, on the web layout: the three panes work — the songs and rooms on
/// the left, the song in the middle, its options on the right — "but when you
/// click 'all 23 songs' on the left it opens the room view instead of just
/// expanding all songs down, then when you click a project from there, it
/// opens the song alone, and does not go back to the view as it was before."
///
/// Two different jumps, one cause. Both 'All 23 in South Dean' and the room
/// heading called `_openRoom`, which pushed a full-screen route over a layout
/// whose whole point is that nothing is ever full-screen. From inside it a
/// song pushed again — three deep, two pops back, and the second pop landed
/// on a room screen nobody had asked to see twice.
Future<MusicBetaController> _seedRoomWithManySongs(WidgetTester tester) async {
  final controller = MusicBetaController(InMemoryMusicRepository.seeded());
  await controller.load();
  addTearDown(controller.dispose);

  // Seven, because six is what the group shows before it offers the rest.
  //
  // Re-read the room each time: `createSong` builds the new room from the
  // snapshot it is handed, so passing the same stale one seven times leaves
  // seven rooms each holding one song, and the list under test never grows.
  for (var i = 0; i < 7; i++) {
    await controller.createSong(controller.rooms.first, 'Song number $i');
  }
  return controller;
}

Future<void> _pumpDesk(WidgetTester tester, MusicBetaController controller) async {
  tester.view.physicalSize = const Size(1500, 950);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      // Under a Scaffold, because that is what the shell supplies. This
      // screen is a tab body and inherits its Material from there.
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
}

void main() {
  testWidgets('the rest of a room’s songs open where the list already is',
      (tester) async {
    final controller = await _seedRoomWithManySongs(tester);
    await _pumpDesk(tester, controller);

    final more = find.textContaining('All 8 in');
    expect(more, findsOneWidget, reason: 'seven added to the one seeded');

    await tester.tap(more);
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byType(RoomDetailScreen),
      findsNothing,
      reason: 'this is a request for the rest of a list somebody is already '
          'reading, not for a different screen',
    );
    expect(find.text('Fewer'), findsOneWidget,
        reason: 'what unfolds has to fold back up');
    expect(find.text('Song number 0'), findsOneWidget,
        reason: 'the seventh song was the one being asked for');
  });

  testWidgets('a room opens beside the library rather than on top of it',
      (tester) async {
    final controller = await _seedRoomWithManySongs(tester);
    await _pumpDesk(tester, controller);

    await tester.tap(find.text('After Hours Studio').first);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(RoomDetailScreen), findsOneWidget);
    expect(
      find.text('Acoustic Ideas'),
      findsWidgets,
      reason: 'the other room is still listed on the left, which is the '
          'whole difference between a pane and a route',
    );
  });

  testWidgets('a song opened from that room lands in the same pane',
      (tester) async {
    final controller = await _seedRoomWithManySongs(tester);
    await _pumpDesk(tester, controller);

    await tester.tap(find.text('After Hours Studio').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(RoomDetailScreen), findsOneWidget);

    await tester.tap(find.text('Song number 3').last);
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(RoomDetailScreen), findsNothing,
        reason: 'the room handed the pane over rather than stacking on it');
    expect(find.byType(SongWorkspaceScreen), findsOneWidget);
    expect(find.text('Acoustic Ideas'), findsWidgets,
        reason: 'and the library never went anywhere');
  });

  testWidgets('rooms are a place to stand, not only a grouping',
      (tester) async {
    final controller = await _seedRoomWithManySongs(tester);
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(BetaScope(
      controller: controller,
      child: MaterialApp(
        theme: CoLabRoomTheme.dark(),
        // Under a Scaffold, because that is what the shell supplies. This
        // screen is a tab body and inherits its Material from there.
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

    // On a phone the rooms were only ever headings inside a long list, which
    // answers "where is this song" and not "what rooms do I have".
    await tester.tap(find.text('Rooms'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('After Hours Studio'), findsOneWidget);
    expect(find.text('Acoustic Ideas'), findsOneWidget);
    expect(find.textContaining('just you'), findsWidgets,
        reason: 'who else can see it is the only privacy signal in the app, '
            'and it should never take a tap to find out');
  });
}
