import 'package:colabroom/app/colabroom_app.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Can this app be drawn — on a small phone, and by somebody who has turned
/// their text size up?
///
/// This suite exists because of what the other forty-five files are not. They
/// are strong on logic and nearly blind to layout: 11 of them render a widget
/// at all, and roughly 12 of 57 screens are named anywhere in a test. Every
/// layout defect this project has shipped went out through that gap.
///
///   * The Chart tab could not be laid out at all. `chord_chart_test.dart`
///     covered chord spelling, bar grouping, transposition and section
///     labels — everything about the chart except whether it could be drawn.
///   * A take strip overflowed by 47 pixels, then by 3.
///   * A fixed 30px box held two lines of 10px text: 24 logical pixels on the
///     phone it was written on, 31 on a phone whose owner had set their font
///     larger.
///
/// None of those are logic bugs and none were catchable by a unit test. All
/// three are caught by mounting the screen and looking at whether Flutter
/// complained.
///
/// **Two conditions do the work here.** A narrow screen, because 800x600 —
/// the test binding's default — is wider than any phone and hides horizontal
/// crowding. And 1.3x text, because ColabRoomApp clamps the reader's system
/// scale to 1.3, so that is the largest text this app can ever be asked to
/// draw and the point at which every fixed pixel height in the codebase is
/// wrong by the most.
///
/// Overflow is an exception in a widget test, so `takeException` catches the
/// yellow stripes as well as the crashes.
Future<MusicBetaController> _controller() async {
  final controller = MusicBetaController(InMemoryMusicRepository.seeded());
  await controller.load();
  return controller;
}

/// Pumps the app at a given phone size and text scale.
///
/// The MediaQuery goes inside the app rather than around it: MaterialApp
/// installs its own from the test window, so a scale wrapped outside would be
/// silently overwritten and every "large text" case here would quietly be
/// testing 1.0 again.
Future<void> _boot(
  WidgetTester tester,
  MusicBetaController controller, {
  required Size size,
  required double textScale,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: CoLabRoomApp.preview(controller: controller),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Taps something by its visible text, if it is there, and settles.
///
/// Tolerant on purpose. This suite is a smoke sweep over the whole app, and a
/// destination that has been renamed should not fail it — the thing being
/// tested is whether what *is* on screen can be drawn, not whether a
/// particular label still exists. The specific assertions about labels and
/// keys live in widget_test.dart, where a rename is supposed to fail.
Future<bool> _tapText(WidgetTester tester, String label) async {
  final finder = find.text(label);
  if (finder.evaluate().isEmpty) return false;
  await tester.tap(finder.last, warnIfMissed: false);
  await tester.pumpAndSettle();
  return true;
}

void main() {
  // A small phone and a large one. 360x690 is roughly the smallest Android
  // still in real use; 390x844 is an iPhone the beta is actually running on.
  const phones = <String, Size>{
    'small phone': Size(360, 690),
    'iPhone': Size(390, 844),
  };
  // 1.0 is the author's own device. 1.3 is the ceiling ColabRoomApp clamps
  // the reader's system setting to, and therefore the worst case that can
  // reach a real screen.
  const scales = <double>[1.0, 1.3];

  for (final phone in phones.entries) {
    for (final scale in scales) {
      final label = '${phone.key} at ${scale}x text';

      testWidgets('$label — every tab draws', (tester) async {
        final controller = await _controller();
        addTearDown(controller.dispose);
        await _boot(tester, controller, size: phone.value, textScale: scale);
        expect(tester.takeException(), isNull, reason: 'Home did not draw');

        for (final tab in <String>['Songs', 'Studio', 'Control Room', 'Home']) {
          await _tapText(tester, tab);
          expect(tester.takeException(), isNull, reason: '$tab did not draw');
        }
      });

      testWidgets('$label — a song and its workspace draw', (tester) async {
        final controller = await _controller();
        addTearDown(controller.dispose);
        await _boot(tester, controller, size: phone.value, textScale: scale);

        await _tapText(tester, 'Songs');
        expect(tester.takeException(), isNull, reason: 'Songs did not draw');

        // The seeded song. Opening one is the single most-used path in the
        // app and the one carrying the most layout: a toolbar, the ask bar,
        // and a full-height editor.
        await _tapText(tester, 'Midnight Signal');
        expect(
          tester.takeException(),
          isNull,
          reason: 'the song workspace did not draw',
        );
      });
    }
  }

  testWidgets('the keyboard appearing does not break the workspace',
      (tester) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    await _boot(tester, controller,
        size: const Size(360, 690), textScale: 1.3);

    await _tapText(tester, 'Songs');
    await _tapText(tester, 'Midnight Signal');
    expect(tester.takeException(), isNull);

    // Half the screen, which is roughly what a keyboard takes on a small
    // phone. Everything in the workspace has to survive being given half the
    // room it had a moment ago — this is where a column of fixed heights
    // stops fitting, and it is a state the app spends a lot of its life in.
    tester.view.viewInsets = const FakeViewPadding(bottom: 345);
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();

    expect(
      tester.takeException(),
      isNull,
      reason: 'the workspace did not survive the keyboard opening',
    );
  });
}
