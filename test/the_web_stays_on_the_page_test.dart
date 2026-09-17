import 'package:colabroom/app/colabroom_app.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The web app stays on the page.
///
/// 17 September 2026: Taylor typed app.colabroom.com, saw "Opening your
/// rooms…", and landed back on Google, every time. A recorder in the live page
/// showed why. Chrome prerenders an address while it is being typed, and a
/// prerendered page cannot add history entries. MaterialApp's own navigator
/// selects single-entry history when it starts, BrowserHistory selects
/// multi-entry, and switching from single to multi steps history back one
/// entry (`history.go(-1)`) to undo the entry single-entry added. When that
/// entry was never added, the step back leaves the site.
///
/// On the web the app now runs under a Router, whose navigator never asks for
/// single-entry history, so there is never a switch to undo.
void main() {
  Future<List<String>> historyCalls(WidgetTester tester, {required bool onWeb}) async {
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.navigation, (call) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.navigation, null));

    final controller = MusicBetaController(InMemoryMusicRepository.seeded());
    await controller.load();
    addTearDown(controller.dispose);
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(CoLabRoomApp.preview(controller: controller, onWeb: onWeb));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    return calls;
  }

  testWidgets('the web app never asks for single-entry history, so it never steps back to undo it',
      (tester) async {
    final calls = await historyCalls(tester, onWeb: true);
    expect(calls, isNot(contains('selectSingleEntryHistory')));
  });

  testWidgets('the phone app is unchanged, and the old shape did ask for it', (tester) async {
    // The check above means something only if the old shape would fail it.
    final calls = await historyCalls(tester, onWeb: false);
    expect(calls, contains('selectSingleEntryHistory'));
  });
}
