import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/openmic/open_mic_song_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Heard it, from the Open Mic.
///
/// A stranger who liked a song and had nothing to add could do nothing at
/// all. Now they can say they heard it, with one line if they like, and the
/// person who put it up hears about it. These pin the nod with a note, what
/// the song page reads back, and the button's two states.
void main() {
  group('the repository', () {
    test('a nod can carry one line, and the song page reads it back',
        () async {
      final repo = InMemoryMusicRepository.seeded();
      final before = await repo.openMicSong('preview-open-1');
      expect(before!.heardByMe, isFalse);
      expect(before.heard, 0);

      await repo.setNod(
          projectId: 'preview-open-1', heard: true, note: 'That chorus.');
      expect(await repo.loadNods('preview-open-1'), contains(repo.currentUserId));
      expect(await repo.nodNote('preview-open-1'), 'That chorus.');

      final after = await repo.openMicSong('preview-open-1');
      expect(after!.heardByMe, isTrue);
      expect(after.heard, 1);

      await repo.setNod(projectId: 'preview-open-1', heard: false);
      expect((await repo.openMicSong('preview-open-1'))!.heardByMe, isFalse);
      expect(await repo.nodNote('preview-open-1'), isNull);
    });
  });

  group('the song page', () {
    testWidgets('says you heard it, with a line, and can take it back',
        (tester) async {
      final repo = InMemoryMusicRepository.seeded();
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        home: OpenMicSongScreen(
          projectId: 'preview-open-1',
          repository: repo,
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('open_mic_heard')), findsOneWidget);
      expect(find.text('Heard it'), findsOneWidget);

      await tester.tap(find.byKey(const Key('open_mic_heard')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('heard_it_note')), findsOneWidget);

      await tester.enterText(
          find.byKey(const Key('heard_it_note')), 'That chorus stayed with me');
      await tester.tap(find.byKey(const Key('heard_it_send')));
      await tester.pumpAndSettle();

      expect(find.text('You heard it'), findsOneWidget);
      expect(await repo.nodNote('preview-open-1'), 'That chorus stayed with me');

      // Takeable back, as every nod has been since 0049.
      await tester.tap(find.byKey(const Key('open_mic_heard')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Take it back'));
      await tester.pumpAndSettle();
      expect(find.text('Heard it'), findsOneWidget);
      expect(await repo.loadNods('preview-open-1'), isEmpty);
    });

    testWidgets('the nod on its own is one tap', (tester) async {
      final repo = InMemoryMusicRepository.seeded();
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        home: OpenMicSongScreen(
          projectId: 'preview-open-1',
          repository: repo,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('open_mic_heard')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('heard_it_plain')));
      await tester.pumpAndSettle();

      expect(find.text('You heard it'), findsOneWidget);
      expect(await repo.nodNote('preview-open-1'), isNull);
    });
  });
}
