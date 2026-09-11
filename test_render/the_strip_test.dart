// What the notification strip actually looks like, at the sizes it runs at.
//
//     flutter test test_render/the_strip_test.dart
//
// Written because the last two versions of this were both reported by
// screenshot rather than caught by a test: nothing overflowed, nothing threw,
// and both of them looked like a single grey line at the top of the screen.
// "Cramped, empty and ugly" are pictures, so this writes pictures.
import 'dart:ui' as ui;

import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/songs/waiting_on_you.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'eyes.dart';

/// One of each kind, which is the state the strip is hardest in: a face, an
/// icon, a play button, an outline button, a long title and a long sentence,
/// all in the same row.
List<WaitingItem> _everything() {
  final now = DateTime.now();
  return <WaitingItem>[
    WaitingItem(
      id: 'n1',
      kind: WaitingKind.news,
      who: 'Dylan Reyes',
      about: 'Midnight Signal',
      at: now.subtract(const Duration(hours: 9)),
      eyebrow: 'New take',
      line: 'Dylan added bass',
      actionLabel: 'Hear it',
      audioPath: 'room/project/takes/abc.m4a',
      audioMs: 41000,
      onAction: () {},
      onDismiss: () {},
    ),
    WaitingItem(
      id: 'n2',
      kind: WaitingKind.news,
      who: 'Mara',
      about: 'The Long Way Around From Here',
      at: now.subtract(const Duration(minutes: 40)),
      eyebrow: 'New message',
      line: 'Mara left a note on the second verse',
      actionLabel: 'Read it',
      onAction: () {},
      onDismiss: () {},
    ),
    WaitingItem(
      id: 'r1',
      kind: WaitingKind.request,
      who: 'Jess Turner',
      at: now.subtract(const Duration(days: 1)),
      line: 'Jess Turner',
      actionLabel: 'See who',
      onAction: () {},
    ),
    WaitingItem(
      id: 'u1',
      kind: WaitingKind.unfinished,
      eyebrow: 'Left 3 weeks ago',
      line: 'Buried My Fears',
      detail: 'It already has a song sheet — the chords, the key, your words.',
      actionLabel: 'Open',
      onAction: () {},
      onDismiss: () {},
    ),
    WaitingItem(
      id: 's1',
      kind: WaitingKind.sheet,
      line: 'Hold The Line For Me',
      detail: 'It has a recording and nothing written down.',
      actionLabel: 'Make it',
      onAction: () {},
      onDismiss: () {},
    ),
  ];
}

Future<void> _shoot(
  WidgetTester tester,
  Device device,
  String name,
  List<WaitingItem> items,
) async {
  stubPlatformChannels();
  final restore = collectComplaints();
  // Shadows on, per test, and put back before the test body ends. Set once in
  // `setUpAll` it is still changed when the framework checks painting debug
  // variables, and every test fails with "the value of a painting debug
  // variable was changed by the test" — which reads like a rendering fault
  // and is nothing of the kind. See the same note in the_app_test.dart.
  debugDisableShadows = false;
  tester.view.physicalSize = device.size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final controller = MusicBetaController(InMemoryMusicRepository.seeded());
  await controller.load();

  await tester.pumpWidget(RepaintBoundary(
    key: rootKey,
    child: BetaScope(
      controller: controller,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: CoLabRoomTheme.dark(),
        home: MediaQuery(
          data: MediaQueryData(
            size: device.size,
            textScaler: TextScaler.linear(device.textScale),
          ),
          child: Scaffold(
            body: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const SizedBox(height: 10),
                  WaitingOnYou(items: items),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(18, 6, 18, 10),
                    child: Text(
                      'Your music',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: AppColors.text,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  ));
  for (var i = 0; i < 6; i += 1) {
    await tester.pump(const Duration(milliseconds: 300));
    while (tester.takeException() != null) {}
  }

  await tester.runAsync(() async {
    final ui.Image image = await take(tester);
    await writePng(image, 'strip', name);
  });

  // audioplayers opens a per-instance event channel named with a fresh uuid,
  // so `stubPlatformChannels` cannot name it and the listen fails. It is the
  // harness having no platform rather than the app being wrong, and it
  // arrives late — after the pump loop, while the player is being built — so
  // it is drained here as well as in the loop.
  for (var i = 0; i < 3; i += 1) {
    await tester.pump(const Duration(milliseconds: 100));
    while (tester.takeException() != null) {}
  }

  // Both at the end of the body rather than in a tearDown: the framework
  // checks for leaks and for changed debug variables *before* it runs
  // tearDowns, so doing either there fails a test that has already passed.
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
  debugDisableShadows = true;
  restore();
}

void main() {
  setUpAll(() async {
    await loadRealFonts();
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  for (final device in const <Device>[
    Device('Small phone', Size(360, 690)),
    Device('iPhone', Size(390, 844)),
    Device('Big text', Size(390, 844), textScale: 1.3),
    Device('Desk', Size(1100, 900)),
  ]) {
    testWidgets('${device.name} — a row of everything', (tester) async {
      await _shoot(tester, device, '${device.slug}-all', _everything());
    });
  }

  // The state Taylor was actually looking at, and the one that read as a
  // single grey line: one chore and nothing else.
  testWidgets('one chore on its own', (tester) async {
    await _shoot(
      tester,
      const Device('iPhone', Size(390, 844)),
      'iphone-one-chore',
      <WaitingItem>[_everything().last],
    );
  });

  testWidgets('one piece of news on its own', (tester) async {
    await _shoot(
      tester,
      const Device('iPhone', Size(390, 844)),
      'iphone-one-news',
      <WaitingItem>[_everything().first],
    );
  });
}
