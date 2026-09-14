import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/openmic/people_screen.dart';
import 'package:colabroom/features/openmic/person_thread_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A thread between two people.
///
/// A connection could be found, told and asked, and not answered with a
/// sentence. These pin the rule for who can be written to (the same one as
/// telling somebody about a song), the round trip, the sheet, and the way in
/// from the People screen.
void main() {
  group('the repository', () {
    test('only somebody you may tell can be written to', () async {
      final repo = InMemoryMusicRepository.seeded();
      expect(await repo.canMessage('preview-jess'), isTrue,
          reason: 'Jess is an accepted connection');
      expect(await repo.canMessage('preview-sam'), isFalse,
          reason: 'Sam has not answered yet');
      expect(await repo.canMessage(repo.currentUserId), isFalse,
          reason: 'never yourself');
    });

    test('a message lands between the two of you and can be taken back',
        () async {
      final repo = InMemoryMusicRepository.seeded();
      expect(await repo.loadMessagesWith('preview-jess'), isEmpty);

      final sent = await repo.sendMessageTo(
          personId: 'preview-jess', body: '  Still up for Thursday?  ');
      expect(sent.body, 'Still up for Thursday?');
      expect(sent.personId, 'preview-jess');
      expect(sent.authorId, repo.currentUserId);

      final thread = await repo.loadMessagesWith('preview-jess');
      expect(thread.map((m) => m.body), <String>['Still up for Thursday?']);
      expect(await repo.loadMessagesWith('preview-mara'), isEmpty,
          reason: 'a thread is one pair, not one person');

      await repo.deleteMessage(sent);
      expect(await repo.loadMessagesWith('preview-jess'), isEmpty);
    });

    test('the server word for it is known to this build', () {
      expect(notificationTypeFromSql('direct_message'),
          NotificationType.directMessage);
    });
  });

  group('the sheet', () {
    testWidgets('carries the name, sends, and takes back', (tester) async {
      final repo = InMemoryMusicRepository.seeded();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PersonThreadSheet(
            repository: repo,
            personId: 'preview-jess',
            personName: 'Jess',
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Jess'), findsOneWidget);
      expect(find.byKey(const Key('person_thread_empty')), findsOneWidget);

      await tester.enterText(
          find.byKey(const Key('person_thread_composer')), 'Hey');
      await tester.tap(find.byKey(const Key('person_thread_send')));
      await tester.pumpAndSettle();

      expect(find.text('Hey'), findsOneWidget);
      expect(find.textContaining('You · '), findsOneWidget);

      final sent = (await repo.loadMessagesWith('preview-jess')).single;
      await tester.tap(find.byKey(Key('person_thread_take_back_${sent.id}')));
      await tester.pumpAndSettle();
      expect(find.text('Hey'), findsNothing);
      expect(find.byKey(const Key('person_thread_empty')), findsOneWidget);
    });
  });

  group('the People screen', () {
    testWidgets('your people can be written to from their row',
        (tester) async {
      final controller = MusicBetaController(InMemoryMusicRepository.seeded());
      await controller.load();
      addTearDown(controller.dispose);

      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(BetaScope(
        controller: controller,
        child: MaterialApp(
          theme: CoLabRoomTheme.dark(),
          home: const PeopleScreen(),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(const Key('message_preview-jess')), findsOneWidget,
          reason: 'an accepted connection can be written to');
      expect(find.byKey(const Key('message_preview-sam')), findsNothing,
          reason: 'somebody who has not answered cannot');

      await tester.tap(find.byKey(const Key('message_preview-jess')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('person_thread_composer')), findsOneWidget);
      expect(find.byKey(const Key('person_thread_headline')), findsOneWidget);
    });
  });
}
