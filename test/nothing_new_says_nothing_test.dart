import 'dart:convert';
import 'dart:io';

import 'package:colabroom/app/colabroom_app.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/account/account_screen.dart';
import 'package:colabroom/features/layers/song_layers_screen.dart';
import 'package:colabroom/features/notifications/notifications_screen.dart';
import 'package:colabroom/features/openmic/open_mic_screen.dart';
import 'package:colabroom/features/songs/songs_screen.dart';
import 'package:colabroom/features/workspace/song_workspace_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_render/rules.dart';

/// The list of painted things that announce nothing, written down.
///
/// Every Musician, Same Song, 17 September 2026 puts the accessibility
/// baseline first, and #357 paid the first instalment: the chord diagrams
/// speak. This file is the part that stops the next drawing shipping silent.
/// It walks the app, asks [silentPaint] what says nothing, and compares the
/// answer with [_snapshot] — so the list can only get shorter.
///
/// **A non-empty snapshot is debt, not permission.** Every line in that file
/// is a `CustomPaint`, an `Image` or an icon-only control that VoiceOver and
/// TalkBack read as a blank rectangle. It is recorded rather than failed
/// because a gate that is red on the day it is written is a gate somebody
/// turns off; recorded, it cannot grow, and the slices that pay it down
/// delete lines from it.
///
/// When a line here is fixed, or a screen is renamed, re-record rather than
/// hand-editing:
///
///     UPDATE_SILENT_PAINT=1 flutter test test/nothing_new_says_nothing_test.dart
///
/// The whole app at every size lives in `test_render/`, which writes
/// `build/eyes/SILENT.md` with the same list by widget type and by screen.
/// This one is in `test/` because the full suite runs `test/` only, and a
/// rule nobody runs is a comment.
final File _snapshot = File('test/nothing_new_says_nothing.txt');

/// What the recorded file says about itself, rewritten with it.
///
/// The list is empty today, and an empty file in a repository is a thing
/// somebody deletes as a leftover. So it explains what it is instead, and
/// lines beginning with `#` are read as comment rather than as debt.
const String _header = '''
# Painted things these screens say nothing about: a CustomPaint, an Image or
# an icon-only control with no label, hint or value, and no declaration that
# it is decoration. One line per screen and thing. WCAG 2.1 SC 1.1.1 (A).
#
# Empty is the state to keep it in. Adding a line is how a drawing ships
# silent, so a line appearing here has to be argued for in the pull request.
#
# Re-record rather than hand-editing:
#   UPDATE_SILENT_PAINT=1 flutter test test/nothing_new_says_nothing_test.dart
''';

/// The screens this walks, in order, and the widget each one is.
///
/// Both halves are the lesson `test_render/the_app_test.dart` learned twice.
/// Every step below is tolerant, because a rename should not fail this file —
/// and a tolerant walk that quietly reaches four screens instead of six
/// reports a shorter list and reads exactly like somebody having fixed
/// things. Worse, a tap that misses lands on whatever is at those
/// coordinates: the walk then files a second look at the screen it never left
/// under the name of the one it never reached. So arriving is asserted by the
/// screen's own widget being on screen, and the screens reached are checked
/// against this list before the list of silent things is believed.
const Map<String, Type> _screens = <String, Type>{
  'the first screen': SongsScreen,
  'the inbox': NotificationsScreen,
  'your account': AccountScreen,
  'your music': SongsScreen,
  'a song': SongWorkspaceScreen,
  'the takes': SongLayersScreen,
  'the open mic': OpenMicScreen,
};

/// Lets a few frames go by, without requiring the app to ever stop moving.
///
/// `pumpAndSettle` throws when an animation never ends, and this app has
/// controls that pulse on purpose.
Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 3; i += 1) {
    await tester.pump(const Duration(milliseconds: 350));
  }
  while (tester.takeException() != null) {}
}

Future<bool> _tapText(WidgetTester tester, String label) async {
  final finder = find.text(label);
  if (finder.evaluate().isEmpty) return false;
  await tester.tap(finder.last, warnIfMissed: false);
  await _frames(tester);
  return true;
}

Future<bool> _tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  if (finder.evaluate().isEmpty) return false;
  await tester.ensureVisible(finder.last);
  await _frames(tester);
  await tester.tap(finder.last, warnIfMissed: false);
  await _frames(tester);
  return true;
}

/// One transparent pixel, as a PNG.
///
/// The rule reads the widget rather than the pixels, so the smallest real
/// picture that decodes is the right size for this.
const String _onePixel =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNkYAAAAAYA'
    'AjCB0C8AAAAASUVORK5CYII=';

/// A face, a cover and a room logo, put there before the walk starts.
///
/// Nobody in the seeded repository has ever uploaded a photograph, and every
/// picture in this app is drawn only when there are bytes to draw — the
/// fallback is initials or a glyph. So without this the walk builds no
/// `Image` at all, the rule judges none, and the empty list that comes back
/// reads exactly like an app whose pictures are all labelled. That is the
/// difference between a gate and something that has never once been asked the
/// question, which is why [paintedCensus] is asserted on below as well.
Future<void> _seedPhotographs(
  InMemoryMusicRepository repository,
  MusicBetaController controller,
) async {
  final bytes = base64Decode(_onePixel);
  await repository.setAvatar(bytes);
  for (final room in controller.rooms) {
    await repository.setRoomLogo(room: room, bytes: bytes);
  }
  for (final project in controller.projects.toList()) {
    await repository.setProjectCover(project: project, bytes: bytes);
  }
  await controller.load();
}

/// A control by the label the `Semantics` widget was given.
///
/// Not `find.bySemanticsLabel`, which reads `debugSemantics` off the render
/// object and matches none of these — the same lesson `test_render` learned,
/// where reaching for the bell that way skipped the Inbox in every run.
Finder _byLabel(String label) => find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.label == label,
    );

/// Back to the shell, however deep the walk currently is.
Future<void> _popToRoot(WidgetTester tester) async {
  for (var i = 0; i < 6; i += 1) {
    if (find.byType(Navigator).evaluate().isEmpty) return;
    final state = tester.state<NavigatorState>(find.byType(Navigator).last);
    if (!state.canPop()) return;
    state.pop();
    await _frames(tester);
  }
}

void main() {
  setUpAll(() {
    // The welcome has to be marked seen or this walks the tour instead of the
    // app, and then the list is a list of the tour's paintings.
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues(<String, Object>{
      'welcome_flow_seen_v2': true,
      'welcome_room_questions_seen_v1': true,
    });
  });

  testWidgets('nothing new on these screens says nothing', (tester) async {
    // One phone at the text size the app is drawn at by default. The list is
    // about what is said, not about what fits, and saying it nine times at
    // nine sizes would be nine copies of the same line.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final repository = InMemoryMusicRepository.seeded();
    final controller = MusicBetaController(repository);
    await controller.load();
    addTearDown(controller.dispose);
    await _seedPhotographs(repository, controller);

    await tester.pumpWidget(CoLabRoomApp.preview(controller: controller));
    await _frames(tester);

    final found = <SilentThing>[];
    final walked = <String>[];
    // What each screen actually put in front of the rule, and what the walk
    // as a whole did.
    //
    // The way a list like this goes quietly wrong is by being empty for the
    // wrong reason: a screen that did not draw, or a walk that photographed a
    // modal barrier, considers nothing and reports nothing, and a clean sheet
    // is what somebody reads. Counted per kind as well as per screen, because
    // a walk can show the rule two hundred icons and not a single picture and
    // still look thorough.
    final painted = <String, int>{};
    final judged = <String, int>{for (final kind in SilentThing.kinds) kind: 0};
    void look(String screen) {
      // Only if this is actually the screen. A look that is really a second
      // look at the last one is worse than a missing look, because it is
      // counted.
      if (find.byType(_screens[screen]!).evaluate().isEmpty) return;
      walked.add(screen);
      final census = paintedCensus(tester);
      painted[screen] = census.values.fold(0, (sum, count) => sum + count);
      census.forEach((kind, count) => judged[kind] = judged[kind]! + count);
      for (final thing in silentPaint(tester)) {
        thing.screen = screen;
        found.add(thing);
      }
    }

    look('the first screen');

    for (final entry in const <String, String>{
      'Notifications': 'the inbox',
      'Account': 'your account',
    }.entries) {
      final control = _byLabel(entry.key);
      if (control.evaluate().isEmpty) continue;
      await tester.tap(control.last, warnIfMissed: false);
      await _frames(tester);
      look(entry.value);
      await _popToRoot(tester);
    }

    // The shelf is where the app opens, so "the first screen" is already it;
    // this is here because the account screen was pushed over the top of it.
    await _tapText(tester, 'Your music');
    look('your music');
    if (await _tapText(tester, 'Midnight Signal')) {
      look('a song');
      if (await _tapKey(tester, 'workspace_layers_button')) {
        look('the takes');
      }
    }
    await _popToRoot(tester);

    if (await _tapText(tester, 'Open Mic')) look('the open mic');

    // Before the list is believed. A walk that lost a screen reports fewer
    // silent things and reads exactly like somebody having fixed them.
    expect(
      walked,
      _screens.keys,
      reason: 'this walk did not reach the screens it is supposed to, so the '
          'list below is shorter than the app',
    );
    expect(
      painted.entries.where((e) => e.value == 0).map((e) => e.key),
      isEmpty,
      reason: 'these screens drew nothing this rule can judge, so finding '
          'nothing silent on them proves nothing',
    );
    expect(
      judged.entries.where((e) => e.value == 0).map((e) => e.key),
      isEmpty,
      reason: 'the rule was never once shown one of these on the whole walk, '
          'so an empty list says nothing about that kind. A picture is only '
          'built when somebody has uploaded one, which is what '
          '_seedPhotographs is for',
    );

    // Taken down before the test ends: screens that started a player or a
    // poll are otherwise never disposed and their timers outlive the walk.
    await tester.pumpWidget(const SizedBox.shrink());
    await _frames(tester);

    final lines = silentPaintLines(found);
    if (Platform.environment['UPDATE_SILENT_PAINT'] == '1') {
      _snapshot.writeAsStringSync(
        _header + lines.map((line) => '$line\n').join(),
        flush: true,
      );
      // ignore: avoid_print
      print('re-recorded ${lines.length} line(s) → ${_snapshot.path}');
      return;
    }

    expect(_snapshot.existsSync(), isTrue,
        reason: '${_snapshot.path} is the recorded list and is missing');
    final recorded = <String>[
      for (final line in LineSplitter.split(_snapshot.readAsStringSync()))
        if (line.trim().isNotEmpty && !line.trimLeft().startsWith('#'))
          line.trim(),
    ];

    final added = lines.where((line) => !recorded.contains(line)).toList();
    expect(
      added,
      isEmpty,
      reason: 'these are painted and announce nothing, and are not in '
          '${_snapshot.path}:\n\n${added.map((l) => '  · $l').join('\n')}\n\n'
          'Give the drawing a Semantics label that reads the way somebody '
          'would say it out loud, or — if it carries no meaning at all — wrap '
          'it in ExcludeSemantics so an assistive technology skips it. An '
          'icon-only control takes a tooltip. Recording it here instead is '
          'the last resort, and it needs a reason in the pull request.',
    );

    final gone = recorded.where((line) => !lines.contains(line)).toList();
    expect(
      gone,
      isEmpty,
      reason: 'these are in ${_snapshot.path} and are no longer silent, '
          'which is good news:\n\n${gone.map((l) => '  · $l').join('\n')}\n\n'
          'Re-record so the file stays the real debt: '
          'UPDATE_SILENT_PAINT=1 flutter test '
          'test/nothing_new_says_nothing_test.dart',
    );
  });
}
