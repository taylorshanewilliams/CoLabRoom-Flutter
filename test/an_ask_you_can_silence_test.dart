import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/notifications/notification_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The switch for being asked.
///
/// `notification_preferences` covered three types and there are seven. Two of
/// the missing ones are answers to something you started, and silencing those
/// would mean the app quietly not telling you the thing you asked it for. The
/// third is somebody else's activity arriving uninvited — a stranger asking
/// you to play on their song — which is the category the other switches exist
/// for, and it is also the one this app is designed to produce a lot of.
///
/// What is worth testing is not that a switch is drawn. It is that it is a
/// switch and not a trapdoor: it goes back, and it reaches only itself. A
/// preference that turns off and cannot turn on, or that takes the other
/// three with it, is the version of this that costs somebody the app.
Future<MusicBetaController> _boot(WidgetTester tester,
    InMemoryMusicRepository repository) async {
  final controller = MusicBetaController(repository);
  await controller.load();
  addTearDown(controller.dispose);

  tester.view.physicalSize = const Size(360, 690);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: const NotificationSettingsScreen(),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 120));
  return controller;
}

Future<void> _flip(WidgetTester tester, String title) async {
  await tester.tap(find.ancestor(
    of: find.text(title),
    matching: find.byType(SwitchListTile),
  ));
  // The controller writes and reloads, so the frame after the tap is not
  // necessarily the frame that shows the new value.
  await tester.pump(const Duration(milliseconds: 120));
}

void main() {
  testWidgets('being asked can be turned off, and back on', (tester) async {
    final repository = InMemoryMusicRepository.seeded();
    await _boot(tester, repository);

    expect((await repository.loadNotificationPreferences()).asks, isTrue,
        reason: 'asks should start on: nobody opts in to being findable and '
            'then opts in again to hearing about it');

    await _flip(tester, 'Being asked');
    expect((await repository.loadNotificationPreferences()).asks, isFalse);

    await _flip(tester, 'Being asked');
    expect((await repository.loadNotificationPreferences()).asks, isTrue,
        reason: 'a switch that only goes one way is worse than no switch');
  });

  testWidgets('silencing asks reaches nothing else', (tester) async {
    final repository = InMemoryMusicRepository.seeded();
    await _boot(tester, repository);

    await _flip(tester, 'Being asked');

    final after = await repository.loadNotificationPreferences();
    expect(after.asks, isFalse);
    expect(after.invites, isTrue);
    expect(after.inviteResponses, isTrue);
    expect(after.projectUpdates, isTrue);
  });
}
