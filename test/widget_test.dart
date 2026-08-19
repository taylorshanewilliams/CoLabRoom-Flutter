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
    expect(find.byKey(const Key('workspace_auto_scroll')), findsOneWidget);
    expect(find.byKey(const Key('workspace_import_lyrics')), findsOneWidget);
    expect(find.byKey(const Key('talk_to_text_button')), findsOneWidget);
    expect(find.byKey(const Key('voice_bullet_line-1')), findsOneWidget);
    expect(find.byKey(const Key('edit_line_line-1')), findsOneWidget);
    expect(find.text('Taylor'), findsNothing);

    await tester.tap(find.byKey(const Key('insert_line_1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('song_line_composer')), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('edit_line_line-1')),
      'Streetlights blur softly in the rain',
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
    expect(find.byKey(const Key('workspace_lyric_book')), findsOneWidget);
    expect(find.byKey(const Key('workspace_book_left')), findsOneWidget);
    expect(find.byKey(const Key('workspace_book_right')), findsOneWidget);
    expect(find.byKey(const Key('workspace_auto_scroll')), findsOneWidget);
    expect(find.byKey(const Key('workspace_import_lyrics')), findsOneWidget);
    expect(find.byKey(const Key('talk_to_text_button')), findsOneWidget);
  });
}
