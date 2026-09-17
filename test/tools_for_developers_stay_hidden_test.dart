import 'package:colabroom/app/beta_config.dart';
import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/account/account_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A measuring tool is not for testers.
///
/// Account listed "Recording latency (debug)" in every debug build, and
/// testers install debug APKs, so testers saw it (audit, 17 September 2026).
/// Tests run in debug mode too, which is what makes this a fair check of the
/// old gate: under `kDebugMode` the row would be here.
Future<void> _account(WidgetTester tester, Widget screen) async {
  tester.view.physicalSize = const Size(390, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final controller = MusicBetaController(InMemoryMusicRepository.seeded());
  await controller.load();
  addTearDown(controller.dispose);

  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(theme: CoLabRoomTheme.dark(), home: screen),
  ));
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  test('no build is given the switch unless somebody asks for it', () {
    expect(BetaConfig.devTools, isFalse);
  });

  testWidgets('Account does not list the latency tool by default',
      (tester) async {
    await _account(tester, const AccountScreen());

    expect(find.text('Blocked people'), findsOneWidget,
        reason: 'the list it would have ended is here');
    expect(find.textContaining('Recording latency'), findsNothing);
  });

  testWidgets('and does, for a developer who switched it on', (tester) async {
    await _account(tester, const AccountScreen(showDevTools: true));

    expect(find.textContaining('Recording latency'), findsOneWidget);
  });
}
