import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/notifications/notifications_screen.dart';
import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The two safeguards a pre-launch audit found missing.
///
/// This app is people sending each other unreviewed audio, which makes it
/// exactly the kind of app both stores look hardest at. App Store 1.2 asks
/// for four things wherever user content appears — filtering, a way to
/// report, a way to block, and a published contact — and the inbox had
/// neither of the middle two, which mattered more once a stranger's song
/// started playing inside the card.
void main() {
  testWidgets('a stranger’s song can be reported and its sender blocked',
      (tester) async {
    tester.view.physicalSize = const Size(390, 820);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = MusicBetaController(InMemoryMusicRepository.seeded());
    await controller.load();
    addTearDown(controller.dispose);

    await tester.pumpWidget(BetaScope(
      controller: controller,
      child: MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: const NotificationsScreen(),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    // The ask is there, and so is the way out of it.
    expect(find.textContaining('asked you to play'), findsWidgets);
    await tester.tap(find.byKey(const Key('ask_card_more')).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Report this'), findsOneWidget);
    expect(find.textContaining('Block '), findsOneWidget);
  });

  test('the ask knows who sent it, so the card can act on them', () {
    // Returned by asks_for_me since 0061 and never mapped, which is why the
    // card could not offer either of the two things above.
    final ask = AskForMe(
      id: 'a',
      projectId: 'p',
      songTitle: 'T',
      askedByName: 'Mara',
      askedById: 'preview-mara',
      createdAt: DateTime(2026, 9, 8),
    );
    expect(ask.askedById, isNotNull);
  });
}
