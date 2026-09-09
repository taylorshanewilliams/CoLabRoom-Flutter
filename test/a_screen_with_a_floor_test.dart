import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/account/account_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every screen has something behind it.
///
/// The Account screen returned a bare `ListView` and nothing else, so the page
/// took whatever colour happened to be underneath — which is white. Every card
/// on it is dark navy and all of them were floating on a white page, with the
/// "Account" heading set in near-white on near-white and therefore invisible.
///
/// It shipped on every device. On a phone the cards cover most of the screen
/// and it reads as an odd margin; on a desk two thirds of the window is white,
/// which is where somebody finally said so.
void main() {
  testWidgets('the account screen is not white', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = MusicBetaController(InMemoryMusicRepository.seeded());
    await controller.load();
    addTearDown(controller.dispose);

    await tester.pumpWidget(BetaScope(
      controller: controller,
      child: MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: const AccountScreen(),
      ),
    ));
    await tester.pump();

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(
      scaffold.backgroundColor,
      AppColors.ink,
      reason: 'without a Scaffold of its own this screen has no background '
          'at all, and what shows through is white',
    );
  });
}
