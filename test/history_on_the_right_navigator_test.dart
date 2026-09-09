import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/app/workspace_shell.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/services/browser_history.dart';
import 'package:colabroom/services/current_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The observers have to be on the navigator that receives the pushes.
///
/// `MaterialApp.navigatorObservers` watches the navigator MaterialApp builds.
/// [WorkspaceShell] builds a second, nested one — deliberately, so every
/// route and dialog in the app sits below `BetaScope` — and every push inside
/// the app goes there instead.
///
/// So a history observer registered on the MaterialApp saw nothing at all:
/// the browser back button stayed broken while the code that fixed it looked
/// present and correct. That failure is silent, which is exactly why it is
/// worth a test.
void main() {
  testWidgets('the navigator that receives pushes carries the observers',
      (tester) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = MusicBetaController(InMemoryMusicRepository.seeded());
    await controller.load();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: WorkspaceShell(controller: controller)),
    );
    await tester.pump(const Duration(milliseconds: 200));

    final nested = tester.widget<Navigator>(
      find.descendant(
        of: find.byType(WorkspaceShell),
        matching: find.byType(Navigator),
      ),
    );

    expect(
      nested.observers.whereType<BrowserHistory>(),
      isNotEmpty,
      reason: 'without this the browser back button leaves the site from the '
          'middle of a song, and nothing about the code looks wrong',
    );
    expect(
      nested.observers.whereType<RouteTracker>(),
      isNotEmpty,
      reason: 'a crash report should name the screen somebody was on',
    );
  });

  test('the observer is inert off the web', () {
    // Constructed on every platform, and does nothing on a phone, where the
    // platform back button already pops the navigator.
    final history = BrowserHistory(onWeb: false);
    history.didPush(
      MaterialPageRoute<void>(builder: (_) => const SizedBox()),
      MaterialPageRoute<void>(builder: (_) => const SizedBox()),
    );
    // Reaching here without a channel call or an exception is the assertion.
    expect(history, isA<NavigatorObserver>());
  });
}
