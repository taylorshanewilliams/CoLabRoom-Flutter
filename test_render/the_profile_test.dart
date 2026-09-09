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
    debugDisableShadows = false;
  });
  tearDownAll(() => debugDisableShadows = true);

  for (final device in const <Device>[
    Device('Profile phone', Size(390, 900)),
    Device('Profile desk', Size(1440, 1000)),
  ]) {
    testWidgets(device.name, (tester) async {
      stubPlatformChannels();
      final restore = collectComplaints();
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

      restore();
    });
  }
}
