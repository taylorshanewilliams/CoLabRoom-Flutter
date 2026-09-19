import 'dart:async';

import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/features/rooms/setlist_detail_screen.dart';
import 'package:colabroom/features/songs/a_set_for_a_day.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A set's new order that did not save says so.
///
/// Dragging a song moves the row at once, which is right — a list that waits
/// on the network before it moves feels broken. The write behind it was fired
/// and forgotten, so no signal in the van left the screen showing an order the
/// server never got, the throw going nowhere, and the set quietly back in its
/// old order at the next load. Reported by the agent that shipped #413.
///
/// Things that have to hold: a lost write puts the row back and says so; a
/// write that lands changes nothing about how it looked; two quick drags end
/// on the second one's order, whatever became of the first; a drag that saved
/// is not undone by a later one that failed, even when the reload after it
/// never arrived; a drag another drag overtook is never sent at all; and a
/// write that fails after the screen is closed says nothing to nobody.
class _ReorderCanFail extends InMemoryMusicRepository {
  _ReorderCanFail() : super.from(InMemoryMusicRepository.seeded());

  /// One entry per reorder, in the order they are sent: true refuses.
  final List<bool> refuses = <bool>[];

  /// Held open to keep the next write in flight while a test does something
  /// else. Cleared as soon as one write has taken it.
  Completer<void>? gate;

  /// The orders that actually reached the repository.
  final List<List<String>> sent = <List<String>>[];

  /// True to refuse the next library reload.
  ///
  /// The ordinary shape of a bad line: the write is one request and the
  /// reload behind it is about twenty, so the reload is the likelier of the
  /// two to fail. Cleared once it has refused one.
  bool refuseNextLoad = false;

  @override
  Future<void> reorderSetlistProjects(
      Setlist setlist, List<String> orderedProjectIds) async {
    final turn = sent.length;
    sent.add(List<String>.from(orderedProjectIds));
    final waiting = gate;
    if (waiting != null) {
      gate = null;
      await waiting.future;
    }
    if (turn < refuses.length && refuses[turn]) {
      // What no signal looks like from here.
      throw TimeoutException('The van is in a dip.');
    }
    return super.reorderSetlistProjects(setlist, orderedProjectIds);
  }

  @override
  Future<List<Setlist>> loadSetlists() async {
    if (refuseNextLoad) {
      refuseNextLoad = false;
      // Deliberately not a timeout: worthRetrying says no to this, so the
      // load gives up at once instead of pausing two seconds and four.
      throw Exception('The library did not load.');
    }
    return super.loadSetlists();
  }

  /// The order the repository itself holds, whatever the controller's copy
  /// says. Goes straight to the parent, so a refused reload does not hide it.
  Future<List<String>> orderHeld(String id) async {
    final sets = await super.loadSetlists();
    return sets.firstWhere((set) => set.id == id).projectIds.toList(growable: false);
  }
}

/// A set of three songs, open on its own screen.
Future<(MusicBetaController, String, List<String>)> _open(
  WidgetTester tester,
  _ReorderCanFail repository,
) async {
  final controller = MusicBetaController(repository);
  await controller.load();
  addTearDown(controller.dispose);
  // Both songs are added to the one room snapshot on purpose. The fake used
  // to rebuild the room from whatever snapshot it was handed, so the second
  // call dropped the first song; it looks the room up by id now, the way
  // Postgres does, and this is what would notice if that came back.
  final room = controller.rooms.first;
  final second = await controller.createSong(room, 'Harbour Lights');
  final third = await controller.createSong(room, 'Slow Train');
  final songs = <String>['song-1', second.id, third.id];
  final set = await controller.createSetlist('Friday practice');
  await controller.addProjectsToSetlist(set, songs);
  tester.view.physicalSize = const Size(390, 900);
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
              builder: (_) => SetlistDetailScreen(
                setlistId: set.id,
                loadAnalysis: (_) async => null,
              ),
            )),
            child: const Text('Open set'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('Open set'));
  await tester.pumpAndSettle();
  return (controller, set.id, songs);
}

/// Drags the song at [from] to [to], exactly as the list's own handle does.
void _drag(WidgetTester tester, int from, int to) {
  tester
      .widget<ReorderableListView>(find.byType(ReorderableListView))
      .onReorderItem!(from, to);
}

/// The songs in the order the screen is drawing them, top to bottom.
List<String> _onScreen(WidgetTester tester, List<String> songs) {
  final rows = <MapEntry<double, String>>[
    for (final id in songs)
      MapEntry<double, String>(
        tester.getTopLeft(find.byKey(Key('set_song_$id'))).dy,
        id,
      ),
  ]..sort((a, b) => a.key.compareTo(b.key));
  return <String>[for (final row in rows) row.value];
}

/// The order the set holds on the server, which is what a set kept on this
/// phone (#378) and the set-for-a-day card (#396) both read.
List<String> _onTheServer(MusicBetaController controller, String id) =>
    controller.setlistById(id)!.projectIds.toList(growable: false);

void main() {
  testWidgets('an order that did not save goes back, and says so', (tester) async {
    final repository = _ReorderCanFail()..refuses.add(true);
    // Held open so the write is still out while the moved row is looked at.
    final held = Completer<void>();
    repository.gate = held;
    final (controller, id, songs) = await _open(tester, repository);
    final before = _onTheServer(controller, id);
    expect(before, songs);

    // The first song to the end.
    _drag(tester, 0, 2);
    await tester.pump();
    expect(_onScreen(tester, songs), <String>[songs[1], songs[2], songs[0]],
        reason: 'the drag moves the row at once, without waiting on the write');

    held.complete();
    await tester.pumpAndSettle();
    expect(_onScreen(tester, songs), before,
        reason: 'and the row goes back when the write did not land');
    expect(find.textContaining('The new order did not save'), findsOneWidget);
    expect(_onTheServer(controller, id), before);
  });

  testWidgets('an order that saved is left exactly as it was dragged', (tester) async {
    final repository = _ReorderCanFail();
    final (controller, id, songs) = await _open(tester, repository);

    _drag(tester, 0, 2);
    await tester.pumpAndSettle();

    final moved = <String>[songs[1], songs[2], songs[0]];
    expect(_onScreen(tester, songs), moved);
    expect(_onTheServer(controller, id), moved);
    expect(find.textContaining('did not save'), findsNothing,
        reason: 'nothing to say when nothing went wrong');
    expect(tester.takeException(), isNull);
  });

  testWidgets('two quick drags end on the second one, though the first was lost',
      (tester) async {
    // The write behind the first drag is still out when the second is made,
    // and then it fails. It must not put back an order the second one saved,
    // and must not say a word about an order that is fine.
    final repository = _ReorderCanFail()..refuses.addAll(<bool>[true, false]);
    final held = Completer<void>();
    repository.gate = held;
    final (controller, id, songs) = await _open(tester, repository);

    _drag(tester, 0, 2);
    await tester.pump();
    _drag(tester, 0, 1);
    await tester.pump();
    held.complete();
    await tester.pumpAndSettle();

    final second = <String>[songs[2], songs[1], songs[0]];
    expect(_onScreen(tester, songs), second);
    expect(_onTheServer(controller, id), second,
        reason: 'the second drag is the newest word on the order');
    expect(find.textContaining('did not save'), findsNothing);
    expect(repository.sent.length, 2,
        reason: 'one at a time, so the last one sent is the last one written');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a drag that saved is not undone by a later one that did not',
      (tester) async {
    // The other half of the race, and the likelier half. A drag's write gets
    // through and the library reload behind it does not, which is the
    // ordinary shape of a bad line: one request against about twenty. The
    // controller's copy of the set is then still the order from before that
    // drag, so putting a later failed drag back to it would set the songs to
    // an order the server has not held since — while saying the set is back
    // as it was (review, 19 September 2026).
    final repository = _ReorderCanFail()..refuses.addAll(<bool>[false, true]);
    final (controller, id, songs) = await _open(tester, repository);

    repository.refuseNextLoad = true;
    _drag(tester, 0, 2);
    await tester.pumpAndSettle();
    final first = <String>[songs[1], songs[2], songs[0]];
    expect(await repository.orderHeld(id), first, reason: 'the write landed');
    expect(_onTheServer(controller, id), songs,
        reason: 'and the reload behind it did not, so the cache is behind');

    _drag(tester, 0, 1);
    await tester.pumpAndSettle();

    expect(_onScreen(tester, songs), first,
        reason: 'back to the order that saved, not the one the cache kept');
    expect(await repository.orderHeld(id), first);
    expect(find.textContaining('The new order did not save'), findsOneWidget);
  });

  testWidgets('a drag another drag overtook is never sent', (tester) async {
    // Three drags while the first write is still out. Every write carries the
    // whole running order, so the middle one says nothing the last one does
    // not — and sending it would make the order that matters wait out another
    // round trip, and its timeout and retries on a bad line.
    final repository = _ReorderCanFail();
    final held = Completer<void>();
    repository.gate = held;
    final (controller, id, songs) = await _open(tester, repository);

    _drag(tester, 0, 2);
    await tester.pump();
    _drag(tester, 0, 1);
    await tester.pump();
    _drag(tester, 2, 0);
    await tester.pump();
    held.complete();
    await tester.pumpAndSettle();

    final last = <String>[songs[0], songs[2], songs[1]];
    expect(repository.sent.length, 2,
        reason: 'the middle drag was overtaken before it ever left');
    expect(repository.sent.last, last);
    expect(_onTheServer(controller, id), last);
    expect(_onScreen(tester, songs), last);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a write that fails after the screen is closed says nothing',
      (tester) async {
    final repository = _ReorderCanFail()..refuses.add(true);
    final held = Completer<void>();
    repository.gate = held;
    final (controller, id, songs) = await _open(tester, repository);
    final before = _onTheServer(controller, id);

    _drag(tester, 0, 2);
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();

    held.complete();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: 'the throw is caught rather than going into the zone');
    expect(find.textContaining('did not save'), findsNothing);
    expect(_onTheServer(controller, id), before);
  });

  testWidgets('a failed order never reaches the card for the day', (tester) async {
    // A set kept on this phone and the set-for-a-day card both read the
    // order the server holds, so a drag that did not save must leave that
    // order alone.
    final repository = _ReorderCanFail()..refuses.add(true);
    final (controller, id, songs) = await _open(tester, repository);
    final today = DateTime.now();
    await controller.setSetlistDay(controller.setlistById(id)!, today);
    await tester.pumpAndSettle();

    _drag(tester, 0, 2);
    await tester.pumpAndSettle();

    final card = setsForTheWeek(controller.setsForTheDay, today)
        .singleWhere((set) => set.id == id);
    expect(card.projectIds, songs,
        reason: "Sunday's card opens the songs in the order that saved");
    expect(_onScreen(tester, songs), songs);
  });
}
