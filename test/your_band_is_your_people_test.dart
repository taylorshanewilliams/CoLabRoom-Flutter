import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/your_people.dart';
import 'package:colabroom/features/openmic/people_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Your band is your people.
///
/// Taylor's three band-mates showed under "asked, no answer yet" and
/// nowhere else: he had sent each a connection request, none had answered,
/// and an unanswered request was being read as "not your people" -- while
/// the same three were in his room, on his songs, and one thread away.
void main() {
  const me = 'me';
  final room = MusicRoom(
    id: 'r1',
    accountId: me,
    name: 'South Dean',
    icon: '♪',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    members: const <RoomMember>[
      RoomMember(userId: me, displayName: 'Me', role: RoomRole.owner, colorValue: 1),
      RoomMember(userId: 'dak', displayName: 'Dakota', role: RoomRole.editor, colorValue: 2),
      RoomMember(userId: 'bam', displayName: 'Bam', role: RoomRole.editor, colorValue: 3),
    ],
  );

  group('the rule', () {
    test('a band-mate you asked and who never answered is still your person', () {
      final people = yourPeople(
        me: me,
        rooms: <MusicRoom>[room],
        connections: const <Connection>[
          Connection(personId: 'dak', displayName: 'Dakota', accepted: false, incoming: false),
        ],
      );
      expect(people.map((p) => p.id), <String>['bam', 'dak']);
      final dakota = people.firstWhere((p) => p.id == 'dak');
      expect(dakota.canMessage, isTrue, reason: 'may_tell allows a room-mate');
      expect(dakota.connected, isFalse);
      expect(dakota.line, 'In South Dean with you');
      expect(dakota.roomMate, isTrue);
    });

    test('a connection comes first and is never listed twice', () {
      final people = yourPeople(
        me: me,
        rooms: <MusicRoom>[room],
        connections: const <Connection>[
          Connection(personId: 'bam', displayName: 'Bam', accepted: true, incoming: false, plays: <String>['Drums']),
        ],
        suggested: const <SuggestedPerson>[
          SuggestedPerson(personId: 'bam', displayName: 'Bam', because: 'In South Dean with you', canMessage: true),
          SuggestedPerson(personId: 'ray', displayName: 'Ray', because: 'Played on a song with you'),
        ],
      );
      expect(people.map((p) => p.id), <String>['bam', 'dak', 'ray']);
      expect(people.first.connected, isTrue);
      expect(people.first.line, 'Drums');
      expect(people.first.roomNames, <String>['South Dean']);
      expect(people.last.canMessage, isFalse, reason: 'only played together; not in a room');
    });

    test('you are never one of your own people', () {
      final people = yourPeople(me: me, rooms: <MusicRoom>[room], connections: const <Connection>[]);
      expect(people.any((p) => p.id == me), isFalse);
    });
  });

  group('the People screen', () {
    testWidgets('a room-mate who is also a connection is one row, with a message button',
        (tester) async {
      tester.view.physicalSize = const Size(420, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final controller = MusicBetaController(InMemoryMusicRepository.seeded());
      await controller.load();
      addTearDown(controller.dispose);
      await tester.pumpWidget(BetaScope(
        controller: controller,
        child: MaterialApp(theme: CoLabRoomTheme.dark(), home: const PeopleScreen()),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      // Jess is in After Hours Studio with you and an accepted connection.
      expect(find.text('YOUR PEOPLE · 1'), findsOneWidget);
      expect(find.byKey(const Key('message_preview-jess')), findsOneWidget);
      expect(find.text('Jess'), findsOneWidget);
      // Sam, asked and not in a room with you, still waits where he was.
      expect(find.text('ASKED, NO ANSWER YET'), findsOneWidget);
      expect(find.byKey(const Key('remove_preview-sam')), findsOneWidget);
    });
  });
}
