import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/workspace/audience_dial.dart';
import 'package:colabroom/features/workspace/song_workspace_screen.dart';
import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The desk stops wasting its own space.
///
/// Taylor, on the workspace at 1920 wide: "this is very unpleasant and not
/// very workable for a webpage" — lyrics in a column of their natural measure
/// with a thousand pixels of empty navy beside them, and everything else
/// behind an icon in the corner.
///
/// The layout was called two-pane and was one: a header row, then the editor
/// across the whole width. And the pane that never existed was hiding two
/// specific things — **portrait showed the audience dial and the ask bar,
/// landscape showed neither.** The layout with the most room on screen was
/// the one leaving out the control that answers who can hear this song.
Future<void> _open(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final repository = InMemoryMusicRepository.seeded();
  final controller = MusicBetaController(repository);
  await controller.load();
  addTearDown(controller.dispose);

  final project = controller.rooms
      .expand((room) => room.projects)
      .first;

  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: SongWorkspaceScreen(projectId: project.id),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('a desk shows who can hear the song', (tester) async {
    await _open(tester, const Size(1440, 900));

    expect(find.byType(AudienceDial), findsOneWidget,
        reason: 'the widest layout was the one that hid the dial, which is '
            'the only thing in the app that answers who can hear this');
  });

  testWidgets('a phone held sideways is not given a side panel',
      (tester) async {
    // 720 wide is landscape by the workspace's own test, and a 340px panel
    // there would leave the words about two hundred pixels — worse than the
    // single column it replaces.
    await _open(tester, const Size(720, 400));

    expect(find.byType(AudienceDial), findsOneWidget,
        reason: 'the dial still shows, it just stacks instead of splitting');
    expect(tester.takeException(), isNull);
  });

  testWidgets('and a phone in portrait is untouched', (tester) async {
    await _open(tester, const Size(390, 844));

    expect(find.byType(AudienceDial), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
