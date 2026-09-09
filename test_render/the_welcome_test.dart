// The first two minutes, photographed — including the bits that move.
//
//     flutter test test_render/the_welcome_test.dart
//
// Writes `build/eyes/welcome/`. The interludes get frames of their own,
// sampled across the animation, because the entire bet of this flow is that
// the space between the questions is worth looking at — and that is not a
// claim anybody should take on trust from the person who wrote it.
import 'dart:ui' as ui;

import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/welcome/interludes.dart';
import 'package:colabroom/features/welcome/welcome_flow.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'eyes.dart';

const Device _phone = Device('Welcome', Size(390, 844));

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 4; i += 1) {
    await tester.pump(const Duration(milliseconds: 350));
  }
}

void main() {
  setUpAll(() async {
    await loadRealFonts();
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues(<String, Object>{});
    debugDisableShadows = false;
  });

  tearDownAll(() => debugDisableShadows = true);

  testWidgets('the questions', (tester) async {
    tester.view.physicalSize = _phone.size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(RepaintBoundary(
      key: rootKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: CoLabRoomTheme.dark(),
        home: WelcomeFlow(
          repository: InMemoryMusicRepository.seeded(),
          displayName: 'Taylor',
        ),
      ),
    ));
    await _frames(tester);

    final shots = <Shot>[];

    Future<void> shoot(String name) async {
      final captured = await tester.runAsync(() async {
        final ui.Image image = await take(tester);
        await writePng(image, 'welcome', name);
        return image;
      });
      if (captured != null) shots.add(Shot(name, captured));
    }

    await shoot('1-hello');

    // Straight through, tapping a few answers on the way so the pictures show
    // the flow being used rather than the flow sitting empty.
    await tester.tap(find.text("Let's go"));
    await tester.pump(const Duration(milliseconds: 2100));
    await _frames(tester);
    await tester.tap(find.text('Singer'));
    await tester.tap(find.text('Keys'));
    await _frames(tester);
    await shoot('2-what-you-play');

    await tester.tap(find.text('Next'));
    await tester.pump(const Duration(milliseconds: 2100));
    await _frames(tester);
    await tester.enterText(find.byType(TextField), 'Deltona');
    await _frames(tester);
    await shoot('3-where-you-are');

    await tester.tap(find.text('Next'));
    await tester.pump(const Duration(milliseconds: 2100));
    await _frames(tester);
    await tester.tap(find.text('indie'));
    await tester.tap(find.text('folk'));
    await _frames(tester);
    await shoot('4-who-you-sound-like');

    await tester.tap(find.text('Next'));
    await tester.pump(const Duration(milliseconds: 2200));
    await _frames(tester);
    await shoot('5-can-they-find-you');

    await tester.runAsync(() => contactSheet(
          shots,
          folder: 'welcome',
          title: 'Welcome — 390x844',
          columns: shots.length,
        ));
  });

  // The same flow asked for a second time: the tour.
  testWidgets('the tour', (tester) async {
    tester.view.physicalSize = _phone.size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MediaQuery(
      // No motion, so the walk spends its frames on cards rather than on
      // waiting out seven interludes.
      data: const MediaQueryData(disableAnimations: true),
      child: RepaintBoundary(
        key: rootKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: CoLabRoomTheme.dark(),
          home: WelcomeFlow(
            repository: InMemoryMusicRepository.seeded(),
            displayName: 'Taylor',
            mode: WelcomeMode.tour,
          ),
        ),
      ),
    ));
    await _frames(tester);

    final shots = <Shot>[];
    Future<void> shoot(String name) async {
      final captured = await tester.runAsync(() async {
        final ui.Image image = await take(tester);
        await writePng(image, 'welcome', name);
        return image;
      });
      if (captured != null) shots.add(Shot(name, captured));
    }

    await shoot('tour-1-hello');
    for (final step in const <String>[
      'Show me',
      'Next',
      'Next',
      'Next',
      'Next',
      'Next',
      'Next',
    ]) {
      final finder = find.text(step);
      if (finder.evaluate().isEmpty) continue;
      await tester.tap(finder.last);
      await _frames(tester);
      await shoot('tour-${shots.length + 1}');
    }

    await tester.runAsync(() => contactSheet(
          shots,
          folder: 'welcome',
          title: 'The tour, asked for again — 390x844',
          name: '_sheet-tour',
          columns: shots.length,
          thumbWidth: 230,
        ));
  });

  // Each interlude, sampled across its own run. A still of a transition is
  // not the transition, but five stills say whether the shapes are right —
  // which is the part that cannot be checked any other way without a device.
  for (final kind in Interlude.values) {
    testWidgets('the ${kind.name} interlude', (tester) async {
      tester.view.physicalSize = _phone.size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(RepaintBoundary(
        key: rootKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: CoLabRoomTheme.dark(),
          home: Scaffold(
            backgroundColor: AppColors.deepNavy,
            body: Stack(
              children: <Widget>[
                const Center(
                  child: Text(
                    'underneath',
                    style: TextStyle(color: AppColors.muted, fontSize: 22),
                  ),
                ),
                Positioned.fill(
                  child: InterludeCurtain(
                    kind: kind,
                    onMidpoint: () {},
                    onDone: () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      ));

      final shots = <Shot>[];
      // Eight even steps over roughly the longest interlude. Stepped up with
      // the durations: at 140ms these stopped a third of the way in and every
      // sheet showed the approach and none of the impact.
      for (var i = 0; i < 8; i += 1) {
        await tester.pump(const Duration(milliseconds: 240));
        final captured = await tester.runAsync(() async {
          final ui.Image image = await take(tester);
          await writePng(image, 'welcome', '${kind.name}-$i');
          return image;
        });
        if (captured != null) shots.add(Shot('${(i + 1) * 240}ms', captured));
      }

      await tester.runAsync(() => contactSheet(
            shots,
            folder: 'welcome',
            title: 'Interlude — ${kind.name}',
            name: '_sheet-${kind.name}',
            columns: 8,
            thumbWidth: 190,
          ));

      // Let the controller finish so it is not disposed mid-flight.
      await tester.pump(const Duration(seconds: 2));
    });
  }
}
