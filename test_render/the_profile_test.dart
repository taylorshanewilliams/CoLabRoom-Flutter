// What a profile actually looks like, before anybody redesigns it.
//
//     flutter test test_render/the_profile_test.dart
import 'dart:ui' as ui;

import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/openmic/musician_profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'eyes.dart';

void main() {
  setUpAll(() async {
    await loadRealFonts();
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  for (final device in const <Device>[
    Device('Profile phone', Size(390, 900)),
    Device('Profile desk', Size(1440, 1000)),
  ]) {
    testWidgets(device.name, (tester) async {
      stubPlatformChannels();
      final restore = collectComplaints();
      // Shadows on, per test, and put back before the test body ends.
      //
      // The binding turns them off so goldens stay stable across platforms,
      // and these images are for looking at rather than diffing — a profile
      // photographed without its elevation is flatter than the real thing.
      //
      // Set once in `setUpAll` it is still changed when the framework checks
      // painting debug variables, which it does at the end of every test body
      // and before any tearDown: both devices failed with "the value of a
      // painting debug variable was changed by the test", which reads like a
      // rendering fault and is nothing of the kind. See the same note in
      // the_app_test.dart.
      debugDisableShadows = false;
      tester.view.physicalSize = device.size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final repository = InMemoryMusicRepository.seeded();

      await tester.pumpWidget(RepaintBoundary(
        key: rootKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: CoLabRoomTheme.dark(),
          home: MusicianProfileScreen(
            // Somebody else's, which is the version most people see.
            profileId: 'preview-mara',
            repository: repository,
          ),
        ),
      ));
      for (var i = 0; i < 6; i += 1) {
        await tester.pump(const Duration(milliseconds: 300));
        while (tester.takeException() != null) {}
      }

      await tester.runAsync(() async {
        final ui.Image image = await take(tester);
        await writePng(image, 'profile', device.slug);
      });

      // At the end of the body rather than in a tearDown: the framework
      // checks for changed debug variables before it runs tearDowns, so
      // putting this back there fails a test that has already passed.
      debugDisableShadows = true;
      restore();
    });
  }
}
