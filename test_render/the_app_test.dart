// Walk the app at every size it runs at, photograph it, and measure it.
//
//     flutter test test_render/
//
// Leaves behind, in `build/eyes/`:
//
//   * one PNG per screen per device, at real pixel sizes with real fonts
//   * `_sheet.png` per device — the whole walk on one page
//   * `REPORT.md` — everything that missed a published threshold
//   * `SILENT.md` — every painted thing that announces nothing, by widget
//     type and by screen
//
// Not run by `flutter test`, which walks `test/` only. This is mostly a thing
// you point at the app when you want to know how it is doing rather than a
// gate — with one exception. A screen that overflowed fails its device's walk,
// because the reader's own text size is no longer clamped and a row that runs
// off the side at 2x is not a matter of taste. See _overflowed.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:colabroom/app/colabroom_app.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/workspace/live_performance_screen.dart';
import 'package:colabroom/features/workspace/song_workspace_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'eyes.dart';
import 'rules.dart';

/// Everything measured across every device, collected for one report.
final List<Finding> _findings = <Finding>[];

/// Every painted thing on the walk that announces nothing.
///
/// Every Musician, Same Song, 17 September 2026: #357 gave the chord diagrams
/// a reading, and the question straight after it is how the next silent
/// drawing gets caught before it ships rather than after. So the walk keeps
/// the list as well as the findings — a `CustomPaint`, an `Image` or an
/// icon-only control with no label, hint or value — and writes it out by
/// widget type and by screen, which is the shape somebody paying it down can
/// actually work from.
final List<SilentThing> _silent = <SilentThing>[];

/// How many painted things of each kind the walk put in front of that rule.
///
/// Kept because an empty list has two readings and only one of them is good
/// news. Nobody in the seeded repository has uploaded a photograph, and every
/// picture in this app is drawn only where there are bytes to draw, so this
/// walk builds no `Image` at all and cannot have an opinion about one. Said
/// out loud in `SILENT.md` rather than left to be assumed.
final Map<String, int> _judged = <String, int>{};

/// The one finding this walk is a gate for.
///
/// Everything else here is a survey: it is written down, a human weighs it up,
/// and the walk carries on so the twelve screens after a bad one still get
/// photographed. A box that could not hold its text is different. Since
/// ColabRoomApp stopped clamping the reader's own text size — Every Musician,
/// Same Song, 17 September 2026 — the largest iOS size reaches these screens
/// for real, and a row that runs off the side at 2x is a musician who cannot
/// read the app. So overflow is collected per device and asserted at the end
/// of that device's walk, which keeps the walk complete and still fails.
final List<Finding> _overflowed = <Finding>[];

String _overflowReport(String device) {
  final lines = <String>[
    'the app overflowed on $device, at ${_overflowed.length} place(s):',
    '',
    for (final f in _overflowed) '  · ${f.screen}: ${f.detail}',
    '',
    'Text wraps or the screen scrolls; nothing is cut off and nothing is '
        'shrunk to fit. A fixed height becomes an intrinsic one, and a Row '
        'holding text gets Flexible children.',
  ];
  return lines.join(Platform.lineTerminator);
}

/// How much each screen asks of somebody, on one phone.
///
/// Only the iPhone: the point of this table is comparing screens with each
/// other, and six copies of every row at different widths would bury that
/// under exactly the kind of noise it exists to cut through.
final List<List<String>> _density = <List<String>>[];

/// Enough frames for a route transition and a rebuild, without requiring the
/// app to ever stop moving.
///
/// `pumpAndSettle` throws when an animation never ends, and this app has
/// controls that pulse on purpose. That is not a defect and a sweep like this
/// one should not treat it as one.
Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  // Long enough that a route transition has finished before anything is
  // measured. At two pumps the walk was photographing screens mid-fade, and
  // every rule that reads pixels then reads a blend of two screens.
  for (var i = 0; i < 4; i += 1) {
    await tester.pump(const Duration(milliseconds: 350));
  }
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

/// Scrolls something into view and taps it.
///
/// "Not on screen" and "on screen but below the fold" are different problems
/// and a tolerant tap tells them apart by pressing whatever is at those
/// coordinates — which, near the bottom of a phone, is the tab bar. That is
/// how this walk spent every 2x run photographing the Open Mic and calling it
/// the song workspace.
Future<bool> _revealAndTap(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    // Named rather than left to itself: Your music holds two scrollables, the
    // page and the row of cards that runs sideways across the top of it, and
    // `scrollUntilVisible` asks for *the* Scrollable and throws on two.
    final down = find.byWidgetPredicate((widget) =>
        widget is Scrollable && widget.axisDirection == AxisDirection.down);
    if (down.evaluate().isEmpty) return false;
    try {
      await tester.scrollUntilVisible(finder, 220,
          maxScrolls: 12, scrollable: down.first);
    } on StateError {
      // Not on this screen at all. A survey says so and carries on.
      return false;
    }
    await _frames(tester);
  }
  if (finder.evaluate().isEmpty) return false;
  await tester.ensureVisible(finder.last);
  await _frames(tester);
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

/// Scrolls a keyed control into view, then taps it.
///
/// The same lesson `_revealAndTap` was written for, one helper along: at the
/// largest text sizes the song's toolbar is below the fold, and a tolerant
/// tap on a control that is built but off screen presses whatever is at those
/// coordinates — which on a phone is the tab bar. That is how the 3.12x walk
/// left the song instead of opening Perform, and then reported three screens
/// it never saw.
Future<bool> _tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  if (finder.evaluate().isEmpty) return false;
  try {
    await tester.ensureVisible(finder.last);
    await _frames(tester);
  } on StateError {
    // Not inside anything that scrolls. Then where it is drawn is where it
    // is, and the tap below is the whole of what can be done.
  }
  await tester.tap(finder.last, warnIfMissed: false);
  await _frames(tester);
  return true;
}

/// Closes a dialog, if one is open, and says whether it had to.
///
/// A modal barrier swallows every tap on the screen behind it, so one
/// unexpected dialog turns the rest of a walk into a series of presses on a
/// grey rectangle — and every one of them is tolerant, so nothing says a word.
///
/// One route at a time, and from whichever Navigator is actually holding it.
/// This app has two, and `showDialog` puts its route on the root one while the
/// screens are pushed onto the inner one — so "pop the last Navigator" pops a
/// screen and leaves the dialog exactly where it was.
Future<bool> _dismissDialog(WidgetTester tester) async {
  if (find.byType(AlertDialog).evaluate().isEmpty) return false;
  for (var attempt = 0; attempt < 3; attempt += 1) {
    final count = find.byType(Navigator).evaluate().length;
    var popped = false;
    for (var i = count - 1; i >= 0; i -= 1) {
      final state = tester.state<NavigatorState>(find.byType(Navigator).at(i));
      if (!state.canPop()) continue;
      state.pop();
      await _frames(tester);
      popped = true;
      break;
    }
    if (find.byType(AlertDialog).evaluate().isEmpty) return true;
    if (!popped) return false;
  }
  return find.byType(AlertDialog).evaluate().isEmpty;
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

/// One step back out of wherever the walk is.
///
/// The innermost Navigator, not the outermost. There are two in this app and
/// the one the screens are pushed onto is the inner one, so asking the outer
/// one to pop found a route it could not pop and did nothing at all —
/// silently, because this helper has no way to say it failed. `_popToRoot`
/// has always used `.last` for exactly this reason; this one did not, and the
/// first screen it cost was Perform: the walk came out of it still inside it,
/// and Takes and Analyze were both skipped after it.
Future<void> _back(WidgetTester tester) async {
  final finder = find.byTooltip('Back');
  if (finder.evaluate().isNotEmpty) {
    await tester.tap(finder.last, warnIfMissed: false);
    await _frames(tester);
    return;
  }
  if (find.byType(Navigator).evaluate().isEmpty) return;
  final state = tester.state<NavigatorState>(find.byType(Navigator).last);
  if (state.canPop()) {
    state.pop();
    await _frames(tester);
  }
}

/// What each screen asks of somebody, as a table.
///
/// Two numbers, and neither is a threshold. A dense list of songs is supposed
/// to have forty tappable rows and a screen with one button is not therefore
/// better. What they are good for is comparison — two screens doing a similar
/// job with very different numbers is worth a look, and so is a screen whose
/// numbers climbed without anybody adding a feature.
Future<void> _writeDensity() async {
  final rows = <String>[
    '# What each screen asks of you',
    '',
    'Measured on a 390x844 phone. Neither number is a threshold; they are for',
    'comparing screens with each other and with themselves over time.',
    '',
    '| Screen | Things you can tap | Words to read |',
    '|---|---|---|',
    for (final row in _density) '| ${row[0]} | ${row[1]} | ${row[2]} |',
  ];
  final file = File('build/eyes/DENSITY.md');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(rows.join(Platform.lineTerminator), flush: true);
}

void main() {
  setUpAll(() async {
    await loadRealFonts();
    // A real store, with the welcome already seen. Several screens ask
    // preferences a question before they decide what to draw, and a channel
    // that throws makes those screens render their error path rather than
    // themselves.
    //
    // The welcome has to be marked seen or this walk photographs the tour
    // instead of the app. WelcomeFlow.offerOnce opens over the first screen,
    // writes the key, and closes — so the *first* device in the list walked a
    // modal (its landing shot was "A look around", and neither the bell nor
    // the account face was reachable behind it) and every later device walked
    // the real app. That made the findings depend on which device happened to
    // run first. The welcome has its own harness in the_welcome_test.dart.
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues(<String, Object>{
      'welcome_flow_seen_v2': true,
      'welcome_room_questions_seen_v1': true,
    });
    // Analyze titles itself in Fraunces, which google_fonts fetches from
    // fonts.gstatic.com at runtime. There is no network here, so it throws
    // whichever way this is set: left alone it fails on the request, turned
    // off it fails on the missing asset. Left alone is the honest one — it is
    // what a device with no connection does — and `collectComplaints` sorts
    // the result out of the findings, because a fetched font falling back to
    // the platform one is not a defect in this app.
  });

  tearDownAll(() async {
    await _writeDensity();
    final report = await writeReport(_findings, path: 'build/eyes/REPORT.md');
    final silent = await writeSilentPaint(_silent,
        path: 'build/eyes/SILENT.md', judged: _judged);
    // ignore: avoid_print
    print('\neyes: ${_findings.length} findings → ${report.path}');
    // Printed rather than asserted, even though the list is empty today.
    // This walk is a survey run deliberately, and a gate belongs where it
    // runs on every change: that is
    // test/nothing_new_says_nothing_test.dart, which holds the same list and
    // fails when something is added to it. What this print is for is the
    // other direction: that gate walks six screens and this walks thirteen,
    // so a silent painter on Perform, Analyze, Sets or Messages shows up
    // here first.
    // ignore: avoid_print
    print('eyes: ${silentPaintLines(_silent).length} painted things say '
        'nothing → ${silent.path}');
  });

  for (final device in kDevices) {
    testWidgets('${device.name} — walk, photograph, measure', (tester) async {
      // Disposed at the end of the body rather than in a tearDown: the
      // framework checks for leaked semantics handles *before* it runs
      // tearDowns, so an addTearDown here fails the test it just passed.
      stubPlatformChannels();
      final restoreErrors = collectComplaints();
      _overflowed.clear();

      // Shadows on, per test, and put back before the test ends.
      //
      // The binding turns them off so goldens stay stable across platforms,
      // and these images are for looking at rather than diffing — an app
      // photographed without its elevation is flatter than the real thing.
      //
      // But it has to be a *per test* change. Set once in `setUpAll` it is
      // still changed at the end of every test body, and the framework checks
      // painting debug variables exactly there: every device failed with "the
      // value of a painting debug variable was changed by the test", which
      // reads like a rendering fault and is nothing of the kind. The harness
      // has been exiting non-zero over it since it was written, which trains
      // people to ignore the one tool meant to tell them something is wrong.
      debugDisableShadows = false;

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

        // Gathered once and used twice: as findings for the report, and as
        // the list itself for SILENT.md.
        final silent = silentPaint(tester);
        for (final thing in silent) {
          thing.screen = name;
          thing.device = device.name;
        }
        _silent.addAll(silent);
        paintedCensus(tester).forEach((kind, count) {
          _judged[kind] = (_judged[kind] ?? 0) + count;
        });

        final found = <Finding>[
          // Drained first, so a screen that threw is reported against the
          // screen rather than against whatever comes next.
          ...asFindings(drainComplaints()),
          ...auditContrast(tester, pixels, image.width, image.height),
          ...auditTapTargets(tester),
          ...auditLabels(tester),
          ...paintedMeaning(silent),
          ...auditMeasure(tester, device.size),
          ...auditInk(pixels, image.width, image.height, device: device.name),
        ];
        for (final f in found) {
          f.screen = name;
          f.device = device.name;
        }
        _findings.addAll(found);
        _overflowed.addAll(found.where((f) => f.rule == 'Overflowed'));

        // One phone only. The point of this table is comparing screens with
        // each other, and six copies of every row at different widths would
        // bury that under the noise it exists to cut through.
        if (device.name == 'iPhone') {
          _density.add(<String>[
            name,
            countControls(tester).toString(),
            countWords(tester, device.size).toString(),
          ]);
        }
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

      // The third tab. It was the one destination in the bottom bar this walk
      // had never opened, so nothing had ever looked at it — which matters now
      // that the reader's own text size reaches it.
      if (await _tapText(tester, 'Messages')) {
        await shoot('04b-messages');
        await _tapText(tester, 'Your music');
      }

      // The single most-used path in the app, and the one carrying the most
      // layout: a toolbar, the asks, and a full-height editor.
      //
      // Scrolled to, then checked. At 2x text the shelf is taller than the
      // screen and the song sits below the fold: the tap landed on the Open
      // Mic tab instead, 05-song-workspace was a photograph of the Open Mic,
      // and 06-takes and 07-analyze were skipped without a word. A walk that
      // files the wrong picture under the right name is worse than one that
      // says it could not get there.
      await _revealAndTap(tester, find.text('Midnight Signal'));
      // On a desk the song is already open beside the library, so the last
      // "Midnight Signal" on screen is the workspace's own header — which is
      // the control that renames the song. The tap above therefore opened the
      // rename dialog, 05-song-workspace was a photograph of that dialog, and
      // every step after it pressed a modal barrier: Perform was reported
      // unreachable on all three wide devices. Closed rather than avoided,
      // because the song being open already is the right answer on a desk.
      await _dismissDialog(tester);
      if (find.byType(SongWorkspaceScreen).evaluate().isNotEmpty) {
        await shoot('05-song-workspace');

        // Perform. The screen somebody is looking at while their hands are
        // busy, and the one the reader's own text size matters most on: the
        // whole point of it is words you can read from a music stand. It has
        // never been in this walk, and until today it was drawn at 1.3
        // whatever the phone said, because the workspace clamped everything
        // inside it (Every Musician, Same Song, 17 September 2026).
        //
        // The destination is asserted rather than assumed, and the walk only
        // comes back out if it got in. Perform is opened by an async load
        // that asks a server this harness does not have; when that does not
        // land, the tap leaves the workspace exactly where it was, the shot
        // is a second photograph of the workspace filed under Perform, and
        // the `_back` after it pops the workspace itself — which is how
        // Takes and Analyze both vanished from this walk the first time this
        // step was added.
        await _tapKey(tester, 'workspace_live_button');
        if (find.byType(LivePerformanceScreen).evaluate().isNotEmpty) {
          await shoot('05b-perform');
          await _back(tester);
        } else {
          _findings.add(Finding(
            rule: 'Nothing reaches it',
            standard: 'the song opens into Perform',
            detail: 'pressing Perform on the song did not open it, so the '
                'screen the words are read from was not walked',
            severity: Severity.warns,
            device: device.name,
            screen: '05-song-workspace',
          ));
        }

        if (await _tapKey(tester, 'workspace_layers_button')) {
          await shoot('06-takes');
          await _back(tester);
        }
        // Whichever of the two the song's state offers. On an empty song the
        // sheet pill is gone — it was the same destination as Record and the
        // slower of the two — so the walk follows the same path a person does.
        if (await _tapKey(tester, 'workspace_analyze_button') ||
            await _tapKey(tester, 'workspace_record_button')) {
          await shoot('07-analyze');
        }
      } else {
        _findings.add(Finding(
          rule: 'Nothing reaches it',
          standard: 'a song on the shelf opens its workspace',
          detail: 'tapping the seeded song did not open the workspace, so '
              'the workspace, Takes and Analyze were not walked',
          severity: Severity.warns,
          device: device.name,
          screen: '04-your-music',
        ));
      }
      await _popToRoot(tester);

      // Sets, the other half of Your music. A song and a set are the two
      // kinds of thing on that tab, and only one of them had ever been
      // photographed.
      if (await _tapText(tester, 'Your music')) {
        if (await _revealAndTap(tester, find.text('Sets'))) {
          await shoot('04c-sets');
          await _revealAndTap(tester, find.text('Songs'));
        } else {
          _findings.add(Finding(
            rule: 'Nothing reaches it',
            standard: 'a song and a set are the two kinds of thing here',
            detail: 'nothing on this tab reached Sets, so half of what Your '
                'music holds was not walked',
            severity: Severity.warns,
            device: device.name,
            screen: '04-your-music',
          ));
        }
      }
      await _popToRoot(tester);

      if (await _tapText(tester, 'Open Mic')) {
        await shoot('08-open-mic');
        if (await _tapKey(tester, 'open_mic_statement')) {
          await shoot('09-what-you-are-looking-at');
        }
        // A song on the Open Mic, which is the ask card in full: what the
        // song wants, who has offered, and the way to answer it. The room
        // opens on the people in it, so the songs are two taps down — the
        // same two a person makes.
        if (await _tapText(tester, 'Who needs it') &&
            await _tapText(tester, 'Everybody') &&
            await _revealAndTap(tester, find.text('Ladder Of Life'))) {
          await shoot('10-a-song-on-the-open-mic');
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
      debugDisableShadows = true;

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
        if (f.rule == 'Overflowed') _overflowed.add(f);
      }
      while (tester.takeException() != null) {}
      restoreErrors();
      if (absentPlugins.isNotEmpty) {
        // ignore: avoid_print
        print('eyes: ${device.name} ran without '
            '${absentPlugins.length} platform plugin(s)');
      }

      // Last, so the sheets and the report are written either way and the
      // walk is complete before anything can throw.
      expect(_overflowed, isEmpty, reason: _overflowReport(device.name));
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
}
