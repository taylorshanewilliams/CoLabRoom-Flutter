import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/features/rooms/setlist_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A set can be renamed, and thrown away.
///
/// From the audit of 17 September 2026: a set could be made, filled,
/// printed and shared, and never renamed or deleted — not in the app, not in
/// the repository. Last month's gig stayed in the list for good.
Future<(MusicBetaController, String)> _open(WidgetTester tester) async {
  final controller = MusicBetaController(InMemoryMusicRepository.seeded());
  await controller.load();
  addTearDown(controller.dispose);
  final set = await controller.createSetlist('Friday practice');
  await controller.addProjectsToSetlist(set, <String>[controller.rooms.first.projects.first.id]);
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => SetlistDetailScreen(setlistId: set.id),
            )),
            child: const Text('Open set'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('Open set'));
  await tester.pumpAndSettle();
  return (controller, set.id);
}

Future<void> _menu(WidgetTester tester, String key) async {
  await tester.tap(find.byTooltip('Setlist options'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renaming a set', (tester) async {
    final (controller, id) = await _open(tester);

    await _menu(tester, 'rename_set');
    await tester.enterText(find.byKey(const Key('rename_set_field')), 'Saturday show');
    await tester.pump();
    await tester.tap(find.byKey(const Key('rename_set_save')));
    await tester.pumpAndSettle();

    expect(controller.setlistById(id)?.name, 'Saturday show');
    expect(find.text('Saturday show'), findsOneWidget);
  });

  testWidgets('a set cannot be renamed to nothing', (tester) async {
    await _open(tester);

    await _menu(tester, 'rename_set');
    await tester.enterText(find.byKey(const Key('rename_set_field')), '  ');
    await tester.pump();

    expect(tester.widget<FilledButton>(find.byKey(const Key('rename_set_save'))).onPressed, isNull);
  });

  testWidgets('deleting a set, and only the set', (tester) async {
    final (controller, id) = await _open(tester);
    final songs = controller.rooms.expand((room) => room.projects).length;

    await _menu(tester, 'delete_set');
    await tester.tap(find.byKey(const Key('delete_set_confirm')));
    await tester.pumpAndSettle();

    expect(controller.setlistById(id), isNull);
    expect(find.byType(SetlistDetailScreen), findsNothing, reason: 'the page for a set that is gone closes');
    expect(controller.rooms.expand((room) => room.projects).length, songs, reason: 'its songs stay');
  });
}
