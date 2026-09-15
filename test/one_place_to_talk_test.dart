import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/messages/messages_screen.dart';
import 'package:colabroom/widgets/app_top_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// One place to talk.
///
/// Taylor: "some way of seeing all messages with users on the home page, in
/// an intuitive way, so you don't need to go to each user individually" --
/// and rooms for the band, "all in one place, seamless and intuitive."
///
/// The seeded preview has two rooms and one line from Jess in the first.
/// These pin that the Messages screen lists rooms and people together, that
/// what was last said and what is unread show on the row, that opening a
/// thread and saying something works, and that the count clears on the
/// way out -- on the row and on the icon every screen wears.
Future<MusicBetaController> _controller([InMemoryMusicRepository? repo]) async {
  final controller = MusicBetaController(repo ?? InMemoryMusicRepository.seeded());
  await controller.load();
  return controller;
}

Future<void> _pump(WidgetTester tester, MusicBetaController controller,
    {Widget? home}) async {
  tester.view.physicalSize = const Size(390, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(controller.dispose);
  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: home ?? const MessagesScreen(),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  group('the list', () {
    testWidgets('rooms and people, together, with what was last said',
        (tester) async {
      final repo = InMemoryMusicRepository.seeded();
      await repo.sendMessageTo(personId: 'preview-jess', body: 'Still up for Thursday?');
      final controller = await _controller(repo);
      await _pump(tester, controller);

      // Both rooms, the person, in one list.
      expect(find.text('After Hours Studio'), findsOneWidget);
      expect(find.text('Acoustic Ideas'), findsOneWidget);
      expect(find.byKey(const Key('thread_person_preview-jess')), findsOneWidget);

      // The room shows who said what; your own line says "You".
      expect(find.textContaining('Jess: Got a bass idea'), findsOneWidget);
      expect(find.textContaining('You: Still up for Thursday?'), findsOneWidget);

      // A room nobody has spoken in sits under its own label.
      expect(find.text('YOUR ROOMS · NOTHING SAID YET'), findsOneWidget);
      expect(find.text('1 in the room'), findsOneWidget);
    });

    testWidgets('a room without a picture wears its initials, never an emoji',
        (tester) async {
      final controller = await _controller();
      await _pump(tester, controller);
      expect(find.text('AH'), findsOneWidget, reason: 'After Hours Studio');
      expect(find.text('AI'), findsOneWidget, reason: 'Acoustic Ideas');
      expect(find.text('♪'), findsNothing);
      expect(find.text('♬'), findsNothing);
    });

    testWidgets('everybody you know is a row above the threads',
        (tester) async {
      final controller = await _controller();
      await _pump(tester, controller);
      expect(find.byKey(const Key('people_strip')), findsOneWidget);
      // Jess is a connection; nobody is here now in a test.
      expect(find.byKey(const Key('strip_person_preview-jess')), findsOneWidget);
      expect(find.byKey(const Key('strip_here_preview-jess')), findsNothing);
      expect(find.text('YOUR PEOPLE · 1'), findsOneWidget);

      // A face opens the thread between the two of you.
      await tester.tap(find.byKey(const Key('strip_person_preview-jess')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('person_thread_headline')), findsOneWidget);
      expect(find.text('Jess'), findsWidgets);
    });

    testWidgets('the unread count is on the row and on the icon',
        (tester) async {
      final controller = await _controller();
      expect(controller.unreadThreadCount, 1);
      await _pump(tester, controller);
      expect(find.byKey(const Key('thread_unread_room-1')), findsOneWidget);
    });

    testWidgets('as a tab it wears the top bar and its own headline',
        (tester) async {
      final controller = await _controller();
      await _pump(
        tester,
        controller,
        home: MessagesScreen(
          embedded: true,
          showTopBar: true,
          displayName: 'Taylor',
          onOpenAccount: () {},
          onOpenNotifications: () {},
        ),
      );
      expect(find.byType(AppTopBar), findsOneWidget);
      expect(find.byKey(const Key('messages_headline')), findsOneWidget);
      expect(find.byKey(const Key('messages_new')), findsOneWidget);
      expect(find.byKey(const Key('thread_room_room-1')), findsOneWidget);
    });
  });

  group('a thread', () {
    testWidgets('opens from its row, takes a line, and clears on the way out',
        (tester) async {
      final repo = InMemoryMusicRepository.seeded();
      final controller = await _controller(repo);
      await _pump(tester, controller);

      await tester.tap(find.byKey(const Key('thread_room_room-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('room_thread_headline')), findsOneWidget);
      expect(find.text('Got a bass idea for the chorus. Thursday?'), findsOneWidget);

      await tester.enterText(
          find.byKey(const Key('room_thread_composer')), 'Thursday works.');
      await tester.tap(find.byKey(const Key('room_thread_send')));
      await tester.pumpAndSettle();
      expect(find.text('Thursday works.'), findsOneWidget);
      final said = await repo.loadRoomMessages('room-1');
      expect(said.last.body, 'Thursday works.');

      // Close the sheet: seen.
      await tester.tapAt(const Offset(195, 40));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('room_thread_headline')), findsNothing);
      expect(controller.unreadThreadCount, 0);
      expect(find.byKey(const Key('thread_unread_room-1')), findsNothing);
      expect(find.textContaining('You: Thursday works.'), findsOneWidget);
    });

    testWidgets('an open thread shows a line that arrives while it is open',
        (tester) async {
      final repo = InMemoryMusicRepository.seeded();
      final controller = await _controller(repo);
      await _pump(tester, controller);

      await tester.tap(find.byKey(const Key('thread_room_room-1')));
      await tester.pumpAndSettle();
      expect(find.text('Sound check at seven.'), findsNothing);

      // Somebody else writes; the app hears about it the way it hears
      // about everything -- the controller reloads and notifies.
      await repo.sendRoomMessage(roomId: 'room-1', body: 'Sound check at seven.');
      controller.notifyListeners();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      expect(find.text('Sound check at seven.'), findsOneWidget);
    });

    testWidgets('a room with nobody in it but you still has its thread',
        (tester) async {
      final repo = InMemoryMusicRepository.seeded();
      final controller = await _controller(repo);
      await _pump(tester, controller);

      await tester.tap(find.byKey(const Key('thread_room_room-2')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('room_thread_empty')), findsOneWidget);
    });
    testWidgets('the thread carries the room: invite, picture, songs, delete',
        (tester) async {
      final repo = InMemoryMusicRepository.seeded();
      final controller = await _controller(repo);
      await _pump(tester, controller);

      await tester.tap(find.byKey(const Key('thread_room_room-2')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('room_thread_mark')), findsOneWidget);
      expect(find.byKey(const Key('room_thread_invite')), findsOneWidget);
      expect(find.byKey(const Key('room_thread_picture')), findsOneWidget);
      expect(find.byKey(const Key('room_thread_songs')), findsOneWidget);
      // Nobody to list in a room of one.
      expect(find.byKey(const Key('room_thread_members')), findsNothing);

      // The owner can delete it, from here, and the list forgets it.
      await tester.tap(find.byKey(const Key('room_thread_more')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('room_thread_leave')), findsNothing);
      await tester.tap(find.byKey(const Key('room_thread_delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete_room_confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('room_thread_headline')), findsNothing);
      expect(find.text('Acoustic Ideas'), findsNothing);
      final rooms = await repo.loadRooms();
      expect(rooms.any((r) => r.id == 'room-2'), isFalse);
    });

    testWidgets('a room can be started from here and opens as a thread',
        (tester) async {
      final repo = InMemoryMusicRepository.seeded();
      final controller = await _controller(repo);
      await _pump(tester, controller);

      await tester.tap(find.byKey(const Key('messages_new')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('messages_new_person')), findsOneWidget);
      await tester.tap(find.byKey(const Key('messages_new_room')));
      await tester.pumpAndSettle();
      expect(find.text('Create a room'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Thursday Band');
      await tester.tap(find.text('Create room'));
      await tester.pumpAndSettle();

      // The new room's thread is open, empty, ready.
      expect(find.byKey(const Key('room_thread_headline')), findsOneWidget);
      expect(find.byKey(const Key('room_thread_empty')), findsOneWidget);

      // Closing it leaves the room in the list.
      await tester.tapAt(const Offset(195, 40));
      await tester.pumpAndSettle();
      final threads = await repo.myThreads();
      expect(threads.any((t) => t.name == 'Thursday Band'), isTrue);
      expect(find.text('Thursday Band'), findsOneWidget);
    });
  });

  group('the summary', () {
    test('the preview lists every room, said or not, newest first', () async {
      final repo = InMemoryMusicRepository.seeded();
      final threads = await repo.myThreads();
      expect(threads.map((t) => t.kind), everyElement(ThreadKind.room));
      expect(threads.first.targetId, 'room-1');
      expect(threads.first.unread, 1);
      expect(threads.last.lastAt, isNull);

      await repo.markThreadRead(kind: ThreadKind.room, targetId: 'room-1');
      final again = await repo.myThreads();
      expect(again.first.unread, 0);
    });
  });
}
