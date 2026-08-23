import 'package:colabroom/app/colabroom_app.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/widgets/music_tiles.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Rooms and song routes remain below the workspace scope', (tester) async {
    final controller = MusicBetaController(InMemoryMusicRepository.seeded());
    await controller.load();
    addTearDown(controller.dispose);

    await tester.pumpWidget(CoLabRoomApp.preview(controller: controller));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Rooms').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(RoomTile).first);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('After Hours Studio'), findsOneWidget);

    await tester.tap(find.byType(SongTile).first);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Midnight Signal'), findsOneWidget);
    // The three verbs live in the always-visible toolbar; everything else is
    // in the overflow. Each appears exactly once — analyze and perform used
    // to be in both the toolbar and the menu under two different names.
    expect(find.byKey(const Key('workspace_analyze_button')), findsOneWidget);
    expect(find.byKey(const Key('workspace_record_button')), findsOneWidget);
    expect(find.byKey(const Key('workspace_live_button')), findsOneWidget);
    expect(find.byKey(const Key('continuous_song_document')), findsOneWidget);
    expect(find.byKey(const Key('talk_to_text_button')), findsOneWidget);
    expect(find.text('Taylor'), findsNothing);

    // The continuous editor hydrates from the seeded contributions, joined
    // by newlines.
    final documentField = tester.widget<TextField>(
      find.byKey(const Key('continuous_song_document')),
    );
    expect(
      documentField.controller?.text,
      'Streetlights blur like a warning in the rain\nYour frequency keeps calling out my name',
    );

    await tester.enterText(
      find.byKey(const Key('continuous_song_document')),
      'Streetlights blur softly in the rain\nYour frequency keeps calling out my name',
    );
    await tester.pump(const Duration(milliseconds: 750));
    await tester.pumpAndSettle();

    expect(
      controller.projectById('song-1')?.contributions.first.body,
      'Streetlights blur softly in the rain',
    );
  });

  testWidgets('song workspace uses the compact two-pane landscape layout', (tester) async {
    tester.view.physicalSize = const Size(900, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = MusicBetaController(InMemoryMusicRepository.seeded());
    await controller.load();
    addTearDown(controller.dispose);

    await tester.pumpWidget(CoLabRoomApp.preview(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rooms').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(RoomTile).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SongTile).first);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('workspace_landscape_panel')), findsOneWidget);
    // Landscape offers the same three verbs as portrait, as icons — the two
    // orientations shouldn't drift apart in what they can reach.
    expect(find.byKey(const Key('workspace_analyze_button')), findsOneWidget);
    expect(find.byKey(const Key('workspace_record_button')), findsOneWidget);
    expect(find.byKey(const Key('workspace_live_button')), findsOneWidget);
    expect(find.byKey(const Key('continuous_song_document')), findsOneWidget);
  });
}
