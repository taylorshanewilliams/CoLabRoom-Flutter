// Walk the app at every size it runs at, photograph it, and measure it.
//
//     flutter test test_render/
//
// Leaves behind, in `build/eyes/`:
//
//   * one PNG per screen per device, at real pixel sizes with real fonts
//   * `_sheet.png` per device — the whole walk on one page
//   * `REPORT.md` — everything that missed a published threshold
//
// Not run by `flutter test`, which walks `test/` only. This is a thing you
// point at the app when you want to know how it is doing, not a gate.
import 'dart:ui' as ui;

import 'package:colabroom/app/colabroom_app.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'eyes.dart';
import 'rules.dart';

/// Everything measured across every device, collected for one report.
final List<Finding> _findings = <Finding>[];

/// Enough frames for a route transition and a rebuild, without requiring the
/// app to ever stop moving.
///
/// `pumpAndSettle` throws when an animation never ends, and this app has
/// controls that pulse on purpose. That is not a defect and a sweep like this
/// one should not treat it as one.
Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 350));
  // Consumed as they arrive. The binding holds one exception at a time and
  // reports "multiple exceptions" for the second, so a walk that only drained
  // at each photograph turned four real errors into one useless summary.
  // They are already recorded in `complaints` by this point.
  while (tester.takeException() != null) {}
}

Future<bool> _tapText(WidgetTester tester, String label) async {
  final finder = find.text(label);
  if (finder.evaluate().isEmpty) return false;
  await tester.tap(finder.last, warnIfMissed: false);
  await _frames(tester);
  return true;
}

/// Finds a control by the semantics label it was given.
///
/// Not `find.bySemanticsLabel`, which reads `debugSemantics` off the render
/// object and matched none of these — the Inbox and the Account screen were
/// skipped on every device, in every run, in silence. The existing suite
/// reaches for the bell the same way behind the same tolerant `if`, so it has
/// most likely never opened either screen either.
///
/// The Semantics widget itself carries the label, and matching it needs no
/// semantics pipeline at all.
Finder _byLabel(String label) => find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.label == label,
    );

Future<bool> _tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  if (finder.evaluate().isEmpty) return false;
  await tester.tap(finder.last, warnIfMissed: false);
  await _frames(tester);
  return true;
}

/// Back to the shell, however deep the walk currently is.
///
/// A single pop is not enough and assuming it is quietly cost this harness
/// four screens: coming out of Analyze left the walk one route down, the tab
/// labels were then not on screen, and Open Mic, the Inbox and Account were
/// all skipped — silently, because every step in this walk is tolerant by
/// design.
Future<void> _popToRoot(WidgetTester tester) async {
  for (var i = 0; i < 6; i += 1) {
    final navigators = find.byType(Navigator).evaluate();
    if (navigators.isEmpty) return;
    final state = tester.state<NavigatorState>(find.byType(Navigator).last);
    if (!state.canPop()) return;
    state.pop();
    await _frames(tester);
  }
}

Future<void> _back(WidgetTester tester) async {
  final finder = find.byTooltip('Back');
  if (finder.evaluate().isNotEmpty) {
    await tester.tap(finder.last, warnIfMissed: false);
    await _frames(tester);
    return;
  }
  final state = tester.state<NavigatorState>(find.byType(Navigator).first);
  if (state.canPop()) {
    state.pop();
    await _frames(tester);
  }
}

void main() {
  setUpAll(() async {
    await loadRealFonts();
    // A real store, empty. Several screens ask preferences a question before
    // they decide what to draw, and a channel that throws makes those screens
    // render their error path rather than themselves.
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // Analyze titles itself in Fraunces, which google_fonts fetches from
    // fonts.gstatic.com at runtime. There is no network here, so the request
    // fails asynchronously *after* the screen has drawn, and the exception
    // gets attributed to whatever the walk did next.
    GoogleFonts.config.allowRuntimeFetching = false;
    // The test binding turns shadows off so goldens stay stable across
    // platforms. These images are for looking at rather than diffing, and an
    // app photographed without its elevation is flatter than the real thing.
    debugDisableShadows = false;
  });

  tearDownAll(() async {
    debugDisableShadows = true;
    final report = await writeReport(_findings, path: 'build/eyes/REPORT.md');
    // ignore: avoid_print
    print('\neyes: ${_findings.length} findings → ${report.path}');
  });

  for (final device in kDevices) {
    testWidgets('${device.name} — walk, photograph, measure', (tester) async {
      // Disposed at the end of the body rather than in a tearDown: the
      // framework checks for leaked semantics handles *before* it runs
      // tearDowns, so an addTearDown here fails the test it just passed.
      stubPlatformChannels();
      final restoreErrors = collectComplaints();

      final semantics = tester.ensureSemantics();

      tester.view.physicalSize = device.size;
      // 1.0 so an image pixel is a logical pixel and every measurement in
      // rules.dart can compare the two without a conversion nobody would
      // remember to keep right.
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = device.textScale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      final controller = MusicBetaController(InMemoryMusicRepository.seeded());
      await controller.load();
      addTearDown(controller.dispose);

      await tester.pumpWidget(RepaintBoundary(
        key: rootKey,
        child: CoLabRoomApp.preview(controller: controller),
      ));
      await _frames(tester);

      final shots = <Shot>[];

      Future<void> shoot(String name) async {
        // ignore: avoid_print
        print('eyes: ${device.name} · $name');
        // The engine does not run on the test's fake clock, so photographing
        // and encoding both have to happen in the real async zone. Awaiting
        // them directly hangs the test until its timeout.
        //
        // Bounded, because a survey that stops dead on one stuck screen
        // reports less than one that notes the screen and carries on — and a
        // screen the engine cannot rasterise in twenty seconds is itself the
        // most interesting finding available.
        final captured = await tester
            .runAsync(() async {
              final ui.Image image = await take(tester);
              final pixels = await rawPixels(image);
              await writePng(image, device.slug, name);
              return (image, pixels);
            })
            .timeout(const Duration(seconds: 20), onTimeout: () => null);
        if (captured == null) {
          _findings.add(Finding(
            rule: 'Would not draw',
            standard: 'a frame is expected within twenty seconds',
            detail: 'the engine did not produce a frame for this screen',
            severity: Severity.fails,
            device: device.name,
            screen: name,
          ));
          return;
        }
        final (image, pixels) = captured;
        shots.add(Shot(name, image));
        if (pixels == null) return;

        final found = <Finding>[
          // Drained first, so a screen that threw is reported against the
          // screen rather than against whatever comes next.
          ...asFindings(drainComplaints()),
          ...auditContrast(tester, pixels, image.width, image.height),
          ...auditTapTargets(tester),
          ...auditLabels(tester),
          ...auditMeasure(tester, device.size),
          ...auditInk(pixels, image.width, image.height, device: device.name),
        ];
        for (final f in found) {
          f.screen = name;
          f.device = device.name;
        }
        _findings.addAll(found);

      }

      // Where the app opens. For a seeded account that is the shelf; for an
      // empty one it is the Open Mic, and which of those you get is itself a
      // decision worth being able to look at.
      await shoot('01-landing');

      // The two shell destinations, taken first and from the landing screen.
      //
      // They used to be taken last, after the walk had been into a song, back
      // out, into the Open Mic and back out again — and they were never once
      // reached, on any device, in any run. Both are in the top bar, which is
      // on screen the whole time; something about the walk's own state, six
      // navigations deep, was losing them. Nothing about that is worth
      // debugging when the destinations are one tap from the first screen.
      for (final entry in const <String, String>{
        'Notifications': '02-inbox',
        'Account': '03-account',
      }.entries) {
        final control = _byLabel(entry.key);
        if (control.evaluate().isEmpty) {
          _findings.add(Finding(
            rule: 'Nothing reaches it',
            standard: 'a destination that exists should be reachable',
            detail: 'no control labelled "${entry.key}" on the first screen',
            severity: Severity.warns,
            device: device.name,
            screen: '01-landing',
          ));
          continue;
        }
        await tester.tap(control.last, warnIfMissed: false);
        await _frames(tester);
        await shoot(entry.value);
        await _popToRoot(tester);
      }

      await _tapText(tester, 'Your music');
      await shoot('04-your-music');

      // The single most-used path in the app, and the one carrying the most
      // layout: a toolbar, the asks, and a full-height editor.
      if (await _tapText(tester, 'Midnight Signal')) {
        await shoot('05-song-workspace');

        if (await _tapKey(tester, 'workspace_layers_button')) {
          await shoot('06-takes');
          await _back(tester);
        }
        if (await _tapKey(tester, 'workspace_analyze_button')) {
          await shoot('07-analyze');
        }
      }
      await _popToRoot(tester);

      if (await _tapText(tester, 'Open Mic')) {
        await shoot('08-open-mic');
        if (await _tapKey(tester, 'open_mic_statement')) {
          await shoot('09-what-you-are-looking-at');
        }
      }
      await _popToRoot(tester);

      await tester.runAsync(() => contactSheet(
        shots,
        folder: device.slug,
        title: '${device.name} — ${device.size.width.round()}'
            'x${device.size.height.round()}'
            '${device.textScale == 1.0 ? '' : ' at ${device.textScale}x text'}',
        columns: shots.length <= 4 ? shots.length : 4,
      ));

      semantics.dispose();

      // Take the tree down before the test ends.
      //
      // Without this the body finishes, the sheet is written, and then the
      // test hangs to its timeout: screens that started something — a player,
      // a poll — are never disposed, so their timers outlive the walk and the
      // binding waits for a world that will not settle. Replacing the app
      // with nothing runs every dispose in the tree.
      await tester.pumpWidget(const SizedBox.shrink());
      await _frames(tester);

      // Anything still pending belongs to the last screen.
      for (final f in asFindings(drainComplaints())) {
        f.device = device.name;
        f.screen = 'after the walk';
        _findings.add(f);
      }
      while (tester.takeException() != null) {}
      restoreErrors();
      if (absentPlugins.isNotEmpty) {
        // ignore: avoid_print
        print('eyes: ${device.name} ran without '
            '${absentPlugins.length} platform plugin(s)');
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
}
