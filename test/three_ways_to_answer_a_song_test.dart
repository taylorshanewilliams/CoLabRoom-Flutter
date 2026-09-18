import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/workspace/ask_bar.dart';
import 'package:colabroom/features/workspace/ask_thread_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Three ways to answer a song.
///
/// Every Musician, Same Song, 17 September 2026: feedback without scores.
/// Somebody answering a song they were asked about picks a door -- what
/// stayed with me, a question, an opinion -- and the opinion is held until
/// the person who asked says they are ready. These tests pin that: a held
/// opinion is invisible until opened, the other two doors are not held, the
/// sheet offers the doors from one end and one quiet control from the other,
/// and nothing anywhere counts anything.
void main() {
  Future<void> jessSays(
    InMemoryMusicRepository repo,
    String askId,
    String body, {
    ReplyDoor? door,
  }) =>
      repo.replyArrivesFrom(
        askId: askId,
        personId: 'preview-jess',
        personName: 'Jess',
        body: body,
        door: door,
      );

  group('the repository', () {
    test('a held opinion is invisible until the asker is ready', () async {
      final repo = InMemoryMusicRepository.seeded();
      final ask = await repo.askFor(projectId: 'song-1');
      await jessSays(repo, ask.id, 'The kitchen light line stayed with me.',
          door: ReplyDoor.stayed);
      await jessSays(repo, ask.id, 'Is the second verse the same singer?',
          door: ReplyDoor.question);
      await jessSays(repo, ask.id, 'The bridge drags.',
          door: ReplyDoor.opinion);

      // The two doors that arrive normally, and not the third.
      var heard = await repo.loadAskReplies(ask.id);
      expect(heard.map((r) => r.door),
          <ReplyDoor>[ReplyDoor.stayed, ReplyDoor.question]);
      expect(heard.map((r) => r.body), isNot(contains('The bridge drags.')));
      expect((await repo.loadAsks('song-1')).single.opinionsOpened, isFalse);

      await repo.openOpinions(ask.id);
      expect((await repo.loadAsks('song-1')).single.opinionsOpened, isTrue);
      heard = await repo.loadAskReplies(ask.id);
      expect(heard.map((r) => r.door), <ReplyDoor>[
        ReplyDoor.stayed,
        ReplyDoor.question,
        ReplyDoor.opinion,
      ]);

      // Once ready, the next opinion arrives normally.
      await jessSays(repo, ask.id, 'The last chorus could go round once more.',
          door: ReplyDoor.opinion);
      expect((await repo.loadAskReplies(ask.id)).map((r) => r.body),
          contains('The last chorus could go round once more.'));
    });

    test('your own opinion is yours to see and take back', () async {
      final repo = InMemoryMusicRepository.seeded();
      // Mara's ask of you, from the inbox: you are not the asker, and she
      // has not said she is ready, and still your own words are yours.
      final mine = await repo.replyToAsk(
        askId: 'preview-ask-1',
        body: 'The bridge drags.',
        door: ReplyDoor.opinion,
      );
      expect((await repo.loadAskReplies('preview-ask-1')).single.door,
          ReplyDoor.opinion);

      await repo.deleteAskReply(mine);
      expect(await repo.loadAskReplies('preview-ask-1'), isEmpty);
    });

    test('a plain line goes through no door', () async {
      final repo = InMemoryMusicRepository.seeded();
      final ask = await repo.askFor(projectId: 'song-1', part: 'drums');
      final line = await repo.replyToAsk(askId: ask.id, body: 'Thursday works');
      expect(line.door, isNull);
      expect(ReplyDoor.fromWireName(null), isNull);
      expect(ReplyDoor.fromWireName('rating'), isNull);
      expect(ReplyDoor.fromWireName('opinion'), ReplyDoor.opinion);
    });
  });

  group('the sheet, answering', () {
    testWidgets('offers three doors and the opinion says it will wait',
        (tester) async {
      final repo = InMemoryMusicRepository.seeded();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AskThreadSheet(
            repository: repo,
            askId: 'preview-ask-1',
            headline: 'Asking for bass',
            askedBy: 'preview-mara',
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // The doors, where the box would be, and no box yet. Never the
      // asker's control from this end.
      expect(find.byKey(const Key('ask_thread_door_stayed')), findsOneWidget);
      expect(find.text('What stayed with me'), findsOneWidget);
      expect(find.text('A question'), findsOneWidget);
      expect(find.text('An opinion'), findsOneWidget);
      expect(find.byKey(const Key('ask_thread_composer')), findsNothing);
      expect(find.byKey(const Key('ask_thread_ready')), findsNothing);

      // An opinion: the box opens under its name, with the one thing the
      // writer has to know.
      await tester.tap(find.byKey(const Key('ask_thread_door_opinion')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ask_thread_composer')), findsOneWidget);
      expect(find.byKey(const Key('ask_thread_door_chosen')), findsOneWidget);
      expect(
          find.text("They'll read this when they're ready."), findsOneWidget);

      // A change of mind goes back to the doors.
      await tester.tap(find.byKey(const Key('ask_thread_door_change')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ask_thread_composer')), findsNothing);
      expect(find.byKey(const Key('ask_thread_door_question')), findsOneWidget);

      // A question goes through with its door on it, and the doors come
      // back for the next line.
      await tester.tap(find.byKey(const Key('ask_thread_door_question')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ask_thread_door_notice')), findsNothing);
      await tester.enterText(
          find.byKey(const Key('ask_thread_composer')), 'What key is it in?');
      await tester.tap(find.byKey(const Key('ask_thread_send')));
      await tester.pumpAndSettle();

      expect(find.text('What key is it in?'), findsOneWidget);
      // On the line, and on the door that is offered again.
      expect(find.text('A question'), findsNWidgets(2));
      expect(find.byKey(const Key('ask_thread_door_stayed')), findsOneWidget);
      expect(find.byKey(const Key('ask_thread_composer')), findsNothing);
      expect((await repo.loadAskReplies('preview-ask-1')).single.door,
          ReplyDoor.question);
    });
  });

  group('the sheet, asking', () {
    testWidgets('one quiet control, and the opinion only after it',
        (tester) async {
      final repo = InMemoryMusicRepository.seeded();
      final ask = await repo.askFor(projectId: 'song-1');
      await jessSays(repo, ask.id, 'The kitchen light line stayed with me.',
          door: ReplyDoor.stayed);
      await jessSays(repo, ask.id, 'The bridge drags.',
          door: ReplyDoor.opinion);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AskThreadSheet(
            repository: repo,
            askId: ask.id,
            headline: ask.headline,
            askedBy: ask.askedBy,
            opinionsOpened: ask.opinionsOpened,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // No doors for the asker: the plain box, as it always was.
      expect(find.byKey(const Key('ask_thread_composer')), findsOneWidget);
      expect(find.byKey(const Key('ask_thread_door_stayed')), findsNothing);

      // What stayed is there under its name. The opinion is not, and
      // nothing on the sheet says one is waiting: no number, no dot, only
      // the control itself, which is there whether or not anything is.
      expect(find.text('The kitchen light line stayed with me.'),
          findsOneWidget);
      expect(find.text('What stayed with me'), findsOneWidget);
      expect(find.text('The bridge drags.'), findsNothing);
      expect(find.byKey(const Key('ask_thread_ready')), findsOneWidget);
      expect(find.text("I'm ready for opinions"), findsOneWidget);
      expect(find.textContaining(RegExp(r'\d')), findsNothing);

      await tester.tap(find.byKey(const Key('ask_thread_ready')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('ask_thread_ready')), findsNothing);
      expect(find.text('The bridge drags.'), findsOneWidget);
      expect(find.text('An opinion'), findsOneWidget);

      // The asker's own line goes through no door.
      await tester.enterText(find.byKey(const Key('ask_thread_composer')),
          'Fair. I will look at the bridge.');
      await tester.tap(find.byKey(const Key('ask_thread_send')));
      await tester.pumpAndSettle();
      final lines = await repo.loadAskReplies(ask.id);
      expect(lines.last.body, 'Fair. I will look at the bridge.');
      expect(lines.last.door, isNull);
    });

    testWidgets('an asker who was already ready sees no control',
        (tester) async {
      final repo = InMemoryMusicRepository.seeded();
      final ask = await repo.askFor(projectId: 'song-1');
      await repo.openOpinions(ask.id);
      await jessSays(repo, ask.id, 'The bridge drags.',
          door: ReplyDoor.opinion);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AskThreadSheet(
            repository: repo,
            askId: ask.id,
            headline: ask.headline,
            askedBy: ask.askedBy,
            opinionsOpened: true,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('ask_thread_ready')), findsNothing);
      expect(find.text('The bridge drags.'), findsOneWidget);
    });
  });

  group('the chip on the song', () {
    testWidgets('never counts, whatever has been said', (tester) async {
      final repo = InMemoryMusicRepository.seeded();
      final ask = await repo.askFor(projectId: 'song-1', part: 'drums');
      await jessSays(repo, ask.id, 'The kitchen light line stayed with me.',
          door: ReplyDoor.stayed);
      await jessSays(repo, ask.id, 'Is the second verse the same singer?',
          door: ReplyDoor.question);
      await jessSays(repo, ask.id, 'The bridge drags.',
          door: ReplyDoor.opinion);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AskBar(projectId: 'song-1', repository: repo),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('needs drums'), findsOneWidget);
      expect(find.textContaining('needs drums ·'), findsNothing);
      expect(find.textContaining(RegExp(r'\d')), findsNothing);
    });
  });
}
