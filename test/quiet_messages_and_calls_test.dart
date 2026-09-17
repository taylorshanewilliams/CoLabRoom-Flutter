import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/notifications/notification_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Messages and calls can be quieted.
///
/// The audit of 17 September 2026 found four switches, and none for the two
/// kinds most likely to arrive often: a message and "X started a call". The
/// only way to stop a busy band thread buzzing was to turn the whole app off.
/// Each is its own switch, starts on, goes back, and reaches nothing else.
Future<void> _boot(WidgetTester tester, InMemoryMusicRepository repository) async {
  final controller = MusicBetaController(repository);
  await controller.load();
  addTearDown(controller.dispose);
  tester.view.physicalSize = const Size(390, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(theme: CoLabRoomTheme.dark(), home: const NotificationSettingsScreen()),
  ));
  await tester.pump(const Duration(milliseconds: 120));
}

Future<void> _flip(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.tap(find.byKey(Key(key)));
  await tester.pump(const Duration(milliseconds: 120));
}

void main() {
  testWidgets('messages can be quieted, and only messages', (tester) async {
    final repository = InMemoryMusicRepository.seeded();
    await _boot(tester, repository);
    expect((await repository.loadNotificationPreferences()).messages, isTrue);

    await _flip(tester, 'notify_messages');

    final after = await repository.loadNotificationPreferences();
    expect(after.messages, isFalse);
    expect(after.calls, isTrue);
    expect(after.invites, isTrue);
    expect(after.asks, isTrue);

    await _flip(tester, 'notify_messages');
    expect((await repository.loadNotificationPreferences()).messages, isTrue);
  });

  testWidgets('calls can be quieted, and only calls', (tester) async {
    final repository = InMemoryMusicRepository.seeded();
    await _boot(tester, repository);
    expect((await repository.loadNotificationPreferences()).calls, isTrue);

    await _flip(tester, 'notify_calls');

    final after = await repository.loadNotificationPreferences();
    expect(after.calls, isFalse);
    expect(after.messages, isTrue);
    expect(after.projectUpdates, isTrue);

    await _flip(tester, 'notify_calls');
    expect((await repository.loadNotificationPreferences()).calls, isTrue);
  });
}
