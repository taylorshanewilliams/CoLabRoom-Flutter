import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/notifications/notifications_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The same question, asked the same way.
///
/// The Inbox drew "INVITATIONS" twice — once for room invitations and once for
/// coded ones — while the comment directly above that code says they belong in
/// one section "because to a person they are the same thing: somebody wants
/// you in their band". Whenever both lists had something in them, which is
/// most of the time anybody is being invited at all, the heading appeared
/// twice with two different card designs under it.
///
/// And the two cards asked the identical question in **opposite orders**: one
/// offered [Join] [No thanks], the other [Decline] [Join] with both weighted
/// equally. The dismissive answer sat where the eye and the thumb go first on
/// one of them.
Future<void> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 1400);
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
  for (var i = 0; i < 5; i += 1) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

void main() {
  testWidgets('invitations are one section, however they arrived',
      (tester) async {
    await _open(tester);

    expect(
      find.text('INVITATIONS'),
      findsOneWidget,
      reason: 'a room invitation and a coded invitation are the same thing to '
          'the person reading them, and the code above this already said so',
    );
  });

  testWidgets('and every one of them puts Join in the same place',
      (tester) async {
    await _open(tester);

    // Whichever kind arrived, the answer that moves you forward is first and
    // filled, and the one that does not is quiet.
    expect(find.text('Join'), findsWidgets);
    expect(find.text('Decline'), findsNothing,
        reason: 'two words for the same answer, on two cards side by side');
    expect(find.text('No thanks'), findsWidgets);
  });
}
