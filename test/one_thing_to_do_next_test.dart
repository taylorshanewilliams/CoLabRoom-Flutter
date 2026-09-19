import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/workspace/song_workspace_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The screen says which of its doors you probably want.
///
/// The workspace toolbar carried five equal-weight pills, and on a song with
/// nothing recorded **none of them was emphasised** — the one state where
/// somebody most needs telling what to do next, and the screen said nothing.
/// It already knew: `hasRecording` is right there and two of the labels change
/// on it.
///
/// Emphasis, not removal. The sheet pill was dropped from an empty song
/// altogether on the reasoning that Record went to the same screen anyway;
/// that stopped being true the day the sheet got a chart somebody could bring
/// (0168), because a song with no recording is exactly the song whose chords
/// live on a brought chart, and the only pill left reaching them started
/// recording on arrival. Landscape never hid it either, so two orientations
/// were offering the same song different doors. It is back, and quiet: a
/// condition may change what a door looks like, never whether it is there
/// (Taylor, 19 September 2026).
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

/// The colour of a pill's label, which is how the toolbar says which door it
/// thinks you want: the text colour when it is lit, muted when it is not.
Color _pillColour(WidgetTester tester, String key) => tester
    .widget<Text>(find.descendant(
      of: find.byKey(Key(key)),
      matching: find.byType(Text),
    ))
    .style!
    .color!;

void main() {
  testWidgets('a song with nothing on it says to record', (tester) async {
    await _open(tester);

    expect(find.byKey(const Key('workspace_record_button')), findsOneWidget);
    // Record is the lit one, because nothing this app works out for you can
    // happen until something is recorded.
    expect(_pillColour(tester, 'workspace_record_button'), AppColors.text);

    // And the sheet is still there, quietly: it is where a chart somebody
    // brought is read, and that needs no recording at all (0168).
    expect(find.byKey(const Key('workspace_analyze_button')), findsOneWidget);
    expect(_pillColour(tester, 'workspace_analyze_button'), AppColors.muted);
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
