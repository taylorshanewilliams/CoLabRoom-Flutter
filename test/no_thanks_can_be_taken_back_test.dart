import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/notifications/notifications_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// No thanks, with a few seconds to take it back.
///
/// "No thanks" on an invitation declined at once, with no Undo (audit, 17
/// September 2026). Declining is final on the server and tells whoever sent
/// the invitation straight away, so the card leaves the inbox at once and the
/// answer is only sent once Undo has gone without being pressed.
///
/// The seeded preview holds one of each kind: Jess's coded invitation to
/// Studio Session, and Dev's invitation by name to South Dean.
const _coded = 'invite-1';
const _byName = 'preview-room-invite-1';

Future<(MusicBetaController, InMemoryMusicRepository)> _open(
  WidgetTester tester, {
  bool behindHome = false,
}) async {
  tester.view.physicalSize = const Size(390, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final repository = InMemoryMusicRepository.seeded();
  final controller = MusicBetaController(repository);
  await controller.load();
  addTearDown(controller.dispose);

  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: behindHome
          ? Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    key: const Key('open_inbox'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const NotificationsScreen(),
                      ),
                    ),
                    child: const Text('Inbox'),
                  ),
                ),
              ),
            )
          : const NotificationsScreen(),
    ),
  ));
  if (behindHome) {
    await tester.tap(find.byKey(const Key('open_inbox')));
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 500));
  }
  return (controller, repository);
}

/// Long enough for a snackbar to show, wait out its four seconds, and leave.
Future<void> _letUndoGo(WidgetTester tester) async {
  for (var i = 0; i < 12; i += 1) {
    await tester.pump(const Duration(milliseconds: 500));
  }
}

Future<List<String>> _stillOpen(InMemoryMusicRepository repository) async =>
    <String>[
      for (final invite in await repository.loadInvites()) invite.id,
      for (final invite in await repository.roomInvitesForMe()) invite.id,
    ];

void main() {
  testWidgets('the card goes at once, and Undo brings it back unsent',
      (tester) async {
    final (controller, repository) = await _open(tester);

    await tester.tap(find.byKey(const Key('invite_decline_$_coded')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 750));

    expect(find.byKey(const Key('invite_decline_$_coded')), findsNothing,
        reason: 'the answer shows on screen straight away');
    expect(controller.invites.map((i) => i.id), isNot(contains(_coded)),
        reason: 'and the bell stops counting it');
    expect(await _stillOpen(repository), contains(_coded),
        reason: 'but nothing has been sent yet');

    await tester.tap(find.byKey(const Key('inbox_undo_$_coded')));
    await _letUndoGo(tester);

    expect(find.byKey(const Key('invite_decline_$_coded')), findsOneWidget);
    expect(controller.invites.map((i) => i.id), contains(_coded));
    expect(await _stillOpen(repository), contains(_coded),
        reason: 'Undo means Jess is never told anything');
  });

  testWidgets('an invitation by name can be taken back the same way',
      (tester) async {
    final (controller, repository) = await _open(tester);

    await tester.tap(find.byKey(const Key('room_invite_decline_$_byName')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 750));
    expect(find.byKey(const Key('room_invite_join_$_byName')), findsNothing);

    await tester.tap(find.byKey(const Key('inbox_undo_$_byName')));
    await _letUndoGo(tester);

    expect(controller.roomInvitesForMe.map((i) => i.id), contains(_byName));
    expect(await _stillOpen(repository), contains(_byName));
  });

  testWidgets('left alone, the decline is sent when Undo goes',
      (tester) async {
    final (controller, repository) = await _open(tester);

    await tester.tap(find.byKey(const Key('invite_decline_$_coded')));
    await tester.pump();
    await _letUndoGo(tester);

    expect(await _stillOpen(repository), isNot(contains(_coded)));
    expect(controller.invites.map((i) => i.id), isNot(contains(_coded)));
    expect(find.byKey(const Key('invite_decline_$_coded')), findsNothing,
        reason: 'sent, and still gone once it is');
  });

  testWidgets('leaving the inbox before Undo goes still sends it',
      (tester) async {
    final (_, repository) = await _open(tester, behindHome: true);

    await tester.tap(find.byKey(const Key('room_invite_decline_$_byName')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Back to where they came from, with Undo still on screen.
    await tester.pageBack();
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('open_inbox')), findsOneWidget);
    expect(await _stillOpen(repository), contains(_byName));

    await _letUndoGo(tester);

    expect(await _stillOpen(repository), isNot(contains(_byName)),
        reason: 'a no that was never sent would leave Dev waiting forever');
  });

  testWidgets('a second no thanks sends the first rather than dropping it',
      (tester) async {
    final (_, repository) = await _open(tester);

    await tester.tap(find.byKey(const Key('room_invite_decline_$_byName')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 750));
    await tester.tap(find.byKey(const Key('invite_decline_$_coded')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 750));

    // The first snackbar made way for the second, which is not an Undo.
    expect(await _stillOpen(repository), isNot(contains(_byName)));
    expect(await _stillOpen(repository), contains(_coded));

    await _letUndoGo(tester);
    expect(await _stillOpen(repository), isEmpty);
  });
}
