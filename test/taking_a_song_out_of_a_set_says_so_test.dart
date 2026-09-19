import 'dart:async';

import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/rooms/setlist_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Taking a song out of a set that did not go says so.
///
/// The remove-circle handed its Future straight to a VoidCallback, so the
/// write was discarded exactly the way a drag's write used to be. With no
/// signal the throw went into the zone, nothing was said, and the song was
/// still in the set at the next load with no explanation. Nothing moves
/// locally here, so unlike a drag the screen was never lying about the order
/// — only silent, which is the same silence.
class _RemoveCanFail extends InMemoryMusicRepository {
  _RemoveCanFail() : super.from(InMemoryMusicRepository.seeded());

  /// True to refuse the next removal. What no signal looks like from here.
  bool refuse = false;

  @override
  Future<void> removeProjectFromSetlist(Setlist setlist, String projectId) async {
    if (refuse) throw TimeoutException('The van is in a dip.');
    return super.removeProjectFromSetlist(setlist, projectId);
  }
}

/// A set of two songs, open on its own screen.
Future<(MusicBetaController, String, List<String>)> _open(
  WidgetTester tester,
  _RemoveCanFail repository,
) async {
  final controller = MusicBetaController(repository);
  await controller.load();
  addTearDown(controller.dispose);
  final second = await controller.createSong(controller.rooms.first, 'Harbour Lights');
  final songs = <String>['song-1', second.id];
  final set = await controller.createSetlist('Friday practice');
  await controller.addProjectsToSetlist(set, songs);
  tester.view.physicalSize = const Size(390, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(BetaScope(
    controller: controller,
    child: MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: SetlistDetailScreen(setlistId: set.id, loadAnalysis: (_) async => null),
    ),
  ));
  await tester.pumpAndSettle();
  return (controller, set.id, songs);
}

/// The songs the set holds, which is also what a set kept on this phone
/// (#378) and the set-for-a-day card (#396) read.
List<String> _inTheSet(MusicBetaController controller, String id) =>
    controller.setlistById(id)!.projectIds.toList(growable: false);

void main() {
  testWidgets('a song that would not come out of the set says so', (tester) async {
    final repository = _RemoveCanFail();
    final (controller, id, songs) = await _open(tester, repository);
    repository.refuse = true;

    await tester.tap(find.byKey(Key('remove_from_set_${songs.first}')));
    await tester.pumpAndSettle();

    expect(find.textContaining('That took too long'), findsOneWidget,
        reason: 'the same sentence the rest of this screen says');
    expect(_inTheSet(controller, id), songs,
        reason: 'the song is still in the set, which is the truth');
    expect(tester.takeException(), isNull,
        reason: 'the throw is caught rather than going into the zone');
  });

  testWidgets('a song that came out of the set goes quietly', (tester) async {
    final repository = _RemoveCanFail();
    final (controller, id, songs) = await _open(tester, repository);

    await tester.tap(find.byKey(Key('remove_from_set_${songs.first}')));
    await tester.pumpAndSettle();

    expect(_inTheSet(controller, id), <String>[songs[1]]);
    expect(find.textContaining('That took too long'), findsNothing,
        reason: 'nothing to say when nothing went wrong');
    expect(tester.takeException(), isNull);
  });
}
