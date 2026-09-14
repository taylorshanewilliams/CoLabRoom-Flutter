import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/workspace/ask_bar.dart';
import 'package:colabroom/features/workspace/ask_thread_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Replies on an ask.
///
/// The thread is the first place in the app a person can type a sentence to
/// another person about a request. These tests pin the shape: a reply lands
/// on the ask and counts on its chip, the chip opens the thread, and your
/// own words can be taken back.
void main() {
  group('the repository', () {
    test('a reply lands on the ask and counts on it', () async {
      final repo = InMemoryMusicRepository.seeded();
      final ask = await repo.askFor(projectId: 'song-1', part: 'drums');
      expect(await repo.loadAskReplies(ask.id), isEmpty);

      final reply =
          await repo.replyToAsk(askId: ask.id, body: '  Thursday works  ');
      expect(reply.body, 'Thursday works');
      expect(reply.askId, ask.id);
      expect(reply.authorId, repo.currentUserId);

      final replies = await repo.loadAskReplies(ask.id);
      expect(replies.map((r) => r.body), <String>['Thursday works']);

      final asks = await repo.loadAsks('song-1');
      expect(asks.single.replyCount, 1);

      await repo.deleteAskReply(reply);
      expect(await repo.loadAskReplies(ask.id), isEmpty);
      expect((await repo.loadAsks('song-1')).single.replyCount, 0);
    });
  });

  group('the sheet', () {
    testWidgets('says nothing has been said, then shows what was',
        (tester) async {
      final repo = InMemoryMusicRepository.seeded();
      final ask = await repo.askFor(projectId: 'song-1', part: 'drums');

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AskThreadSheet(
            repository: repo,
            askId: ask.id,
            headline: 'Asking for drums',
            note: 'brushes, not sticks',
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('ask_thread_headline')), findsOneWidget);
      expect(find.text('“brushes, not sticks”'), findsOneWidget);
      expect(find.byKey(const Key('ask_thread_empty')), findsOneWidget);

      await tester.enterText(
          find.byKey(const Key('ask_thread_composer')), 'Thursday works');
      await tester.tap(find.byKey(const Key('ask_thread_send')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('ask_thread_empty')), findsNothing);
      expect(find.text('Thursday works'), findsOneWidget);
      expect(find.textContaining('You · '), findsOneWidget);
      // The box empties, so the next thing typed is not the last thing sent.
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('ask_thread_composer')))
            .controller!
            .text,
        isEmpty,
      );

      // Blank sends go nowhere.
      await tester.tap(find.byKey(const Key('ask_thread_send')));
      await tester.pumpAndSettle();
      expect((await repo.loadAskReplies(ask.id)).length, 1);

      // Your own words can be taken back, and the label is on the row.
      final reply = (await repo.loadAskReplies(ask.id)).single;
      await tester.tap(find.byKey(Key('ask_thread_take_back_${reply.id}')));
      await tester.pumpAndSettle();
      expect(find.text('Thursday works'), findsNothing);
      expect(find.byKey(const Key('ask_thread_empty')), findsOneWidget);
    });
  });

  group('the chip on the song', () {
    testWidgets('carries the count and opens the thread', (tester) async {
      final repo = InMemoryMusicRepository.seeded();
      final ask = await repo.askFor(projectId: 'song-1', part: 'drums');
      await repo.replyToAsk(askId: ask.id, body: 'I can do Thursday');

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AskBar(projectId: 'song-1', repository: repo),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('needs drums · 1'), findsOneWidget);

      await tester.tap(find.byKey(Key('ask_chip_${ask.id}')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('ask_thread_composer')), findsOneWidget);
      expect(find.text('I can do Thursday'), findsOneWidget);
      expect(find.text('Asking for drums'), findsOneWidget);

      await tester.enterText(
          find.byKey(const Key('ask_thread_composer')), 'Great');
      await tester.tap(find.byKey(const Key('ask_thread_send')));
      await tester.pumpAndSettle();

      // Closing the sheet brings the count on the chip up to date.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('needs drums · 2'), findsOneWidget);
    });
  });
}
