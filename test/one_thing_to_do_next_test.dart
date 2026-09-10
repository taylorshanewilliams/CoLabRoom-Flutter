import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/workspace/song_workspace_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The screen says which of its five doors you probably want.
///
/// The workspace toolbar carried five equal-weight pills, and on a song with
/// nothing recorded **none of them was emphasised** — the one state where
/// somebody most needs telling what to do next, and the screen said nothing.
/// It already knew: `hasRecording` is right there and two of the labels change
/// on it.
///
/// Two of the five also went to the same place. "Make it" and "Record" both
/// push `SongAnalysisScreen`, one of them with `autoRecord` — so the quieter
/// button was the one that took an extra tap to do the same thing.
Future<void> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final controller = MusicBetaController(InMemoryMusicRepository.seeded());
  await controller.load();
  addTearDown(controller.dispose);

  final project =
      controller.rooms.expand((room) => room.projects).first;

  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: SongWorkspaceScreen(projectId: project.id),
    ),
  ));
  for (var i = 0; i < 5; i += 1) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

void main() {
  testWidgets('a song with nothing on it says to record', (tester) async {
    await _open(tester);

    expect(find.byKey(const Key('workspace_record_button')), findsOneWidget);
    // Nothing else on this screen can happen until something is recorded, so
    // the sheet button — which on an empty song is the same destination one
    // tap further away — is not offered.
    expect(
      find.byKey(const Key('workspace_analyze_button')),
      findsNothing,
      reason: 'on an empty song this was the same destination as Record, and '
          'the slower of the two',
    );
  });

  testWidgets('and the other verbs are still there', (tester) async {
    await _open(tester);

    // Simplifying the toolbar must not mean losing it. Takes, Perform and
    // Talk are genuinely different places and all three stay.
    expect(find.byKey(const Key('workspace_layers_button')), findsOneWidget);
    expect(find.byKey(const Key('workspace_live_button')), findsOneWidget);
    expect(find.byKey(const Key('workspace_cowork_button')), findsOneWidget);
  });
}
