import 'dart:ui' show SpellOutStringAttribute;

import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/meeting/your_code_screen.dart';
import 'package:colabroom/services/invite_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The code, said out loud.
///
/// Your code draws the code as selectable text, and selectable text reaches
/// a screen reader as a text box with no name: the one thing the screen
/// exists to show was announced as an unlabelled field (audit, 17 September
/// 2026).
void main() {
  testWidgets('a screen reader hears what it is and the code itself',
      (tester) async {
    final semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(390, 1100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final repository = InMemoryMusicRepository.seeded();
    final controller = MusicBetaController(repository);
    await controller.load();
    addTearDown(controller.dispose);

    await tester.pumpWidget(BetaScope(
      controller: controller,
      child: MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: YourCodeScreen(
          repository: repository,
          lookEvery: const Duration(hours: 1),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final said = meetingCodeSaid(await repository.myMeetingCode());
    final node = tester.getSemantics(find.byKey(const Key('meet_code_spoken')));

    expect(node.label, 'Your code, $said');
    expect(node.flagsCollection.isTextField, isFalse,
        reason: 'a code to read, not a box to type in');

    // Spelled out, so "k7m2" is not read as a word.
    final spelled = node.attributedLabel.attributes
        .whereType<SpellOutStringAttribute>()
        .single
        .range;
    expect(node.label.substring(spelled.start, spelled.end), said);

    // And nothing under it announces itself a second time.
    var children = 0;
    node.visitChildren((_) {
      children += 1;
      return true;
    });
    expect(children, 0);

    semantics.dispose();
  });
}
