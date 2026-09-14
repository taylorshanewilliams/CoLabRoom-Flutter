import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/workspace/ask_the_song_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ask the app about this song.
///
/// The server does the thinking; these pin what the sheet does with what
/// comes back: the answer, the honesty line under it, and the seam -- every
/// answer ends in "or ask somebody", which asks the room for the part the
/// question was about.
void main() {
  group('the answer', () {
    test('names the part to ask for, in a person\'s words', () {
      const withPart = SongAnswer(
        answer: 'Try Bm before the chorus.',
        askPart: 'drums',
        askLabel: 'Or ask somebody: the room, for drums',
        model: 'preview',
      );
      expect(withPart.askPart, 'drums');
      const noPart = SongAnswer(
        answer: 'It is in D major.',
        askLabel: 'Or ask somebody in the room',
        model: 'preview',
      );
      expect(noPart.askPart, isNull);
    });
  });

  group('the sheet', () {
    Future<void> open(WidgetTester tester, InMemoryMusicRepository repo) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AskTheSongSheet(
            repository: repo,
            projectId: 'song-1',
            songTitle: 'Weathervane',
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('a typed question gets an answer and a way to a person',
        (tester) async {
      final repo = InMemoryMusicRepository.seeded();
      await open(tester, repo);

      expect(find.text('Ask about Weathervane'), findsOneWidget);
      expect(find.byKey(const Key('ask_song_starter_0')), findsOneWidget);

      await tester.enterText(find.byKey(const Key('ask_song_question')),
          'What could the drums do in the chorus?');
      await tester.tap(find.byKey(const Key('ask_song_send')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('ask_song_answer')), findsOneWidget);
      expect(find.textContaining('Check it against your ears'), findsOneWidget);
      expect(find.byKey(const Key('ask_song_or_ask')), findsOneWidget);
      expect(find.textContaining('drums'), findsWidgets);
      expect(repo.lastQuestion, 'What could the drums do in the chorus?');
    });

    testWidgets('a starter is one tap', (tester) async {
      final repo = InMemoryMusicRepository.seeded();
      await open(tester, repo);

      await tester.tap(find.byKey(const Key('ask_song_starter_1')));
      await tester.pumpAndSettle();

      expect(repo.lastQuestion, AskTheSongSheet.starters[1]);
      expect(find.byKey(const Key('ask_song_answer')), findsOneWidget);
    });

    testWidgets('or ask somebody asks the room for the part', (tester) async {
      final repo = InMemoryMusicRepository.seeded();
      await open(tester, repo);

      await tester.enterText(find.byKey(const Key('ask_song_question')),
          'What could the drums do here?');
      await tester.tap(find.byKey(const Key('ask_song_send')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('ask_song_or_ask')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ask_song_or_ask_confirm')), findsOneWidget);
      await tester.tap(find.byKey(const Key('ask_song_or_ask_confirm')));
      await tester.pumpAndSettle();

      final asks = await repo.loadAsks('song-1');
      expect(asks.single.part, 'drums');
    });
  });
}
