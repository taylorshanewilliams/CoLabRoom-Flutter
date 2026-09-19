import 'dart:io';

import 'package:colabroom/app/beta_scope.dart';
import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/app/music_beta_controller.dart';
import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/rooms/setlist_detail_screen.dart';
import 'package:colabroom/services/kept_songs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Leaving a room takes its songs out of your sets.
///
/// A `setlist_projects` row used to outlive its owner's membership: 0005
/// asks that the set's owner be in the song's room as the row goes in and
/// never asks again. So somebody left a band, or was removed from one, and
/// their own sets went on holding that band's songs -- with the key, the
/// tempo and the line for the stand-in 0157 writes on each row. The songs
/// could not be opened and 0164 refused to hand the set to anybody, but the
/// record of the room stayed in the person's list.
///
/// The rule, decided 19 September 2026: stop being a member, and that
/// room's songs leave your sets at that moment. 0166's trigger does it in
/// the database; the in-memory repository does the same here so a test
/// tells the truth about what a phone would see.

/// Jess, who plays in both of Taylor's bands. Neither room is theirs, so
/// they can leave either one -- an owner cannot leave their own (0062).
const RoomMember _jess = RoomMember(
  userId: 'preview-jess',
  displayName: 'Jess',
  role: RoomRole.editor,
  colorValue: 0xFF3AD3FF,
);

const SongAnalysisBundle _nothingRecorded = SongAnalysisBundle(
  reference: null,
  lyricCues: <LyricSyncCue>[],
  chordCues: <ChordCue>[],
);

/// Two bands, one set with a song from each, and the phone in Jess's hand.
///
/// The set carries what 0157 writes on the weekday song, so that "the row
/// went" is also "the key and the line for the stand-in went".
Future<(InMemoryMusicRepository, Setlist, SongProject)> _twoBands() async {
  final repository = InMemoryMusicRepository.seeded();
  repository.addToRoom('room-2', _jess);
  final acoustic =
      (await repository.loadRooms()).firstWhere((room) => room.id == 'room-2');
  final second =
      await repository.createSong(room: acoustic, title: 'Acoustic Idea');

  repository.currentUserId = _jess.userId;
  var set = await repository.createSetlist('Everything I play');
  await repository.addProjectsToSetlist(set, <String>['song-1', second.id]);
  set = (await repository.loadSetlists()).single;
  await repository.saveSetlistSong(
    set,
    const SetlistSong(
      projectId: 'song-1',
      key: 'A',
      note: 'Straight into the next one',
    ),
  );
  set = (await repository.loadSetlists()).single;
  return (repository, set, second);
}

/// Whatever [repository] holds for [userId], read in their shoes.
Future<List<Setlist>> _setsOf(
  InMemoryMusicRepository repository,
  String userId,
) async {
  final was = repository.currentUserId;
  repository.currentUserId = userId;
  try {
    return await repository.loadSetlists();
  } finally {
    repository.currentUserId = was;
  }
}

/// The library as a phone gets it: a room you are not in is not in it.
///
/// The in-memory repository hands back every room it holds, membership or
/// not, which is right for a preview where one account is in everything and
/// wrong for the question below. `rooms_read_members` and
/// `projects_read_members` (0001) are the rule on a phone, so they are the
/// rule here, and the kept copy is dropped for the reason it is dropped in
/// the van rather than because the fixture forgot the song.
class _OnlyWhatImIn extends InMemoryMusicRepository {
  _OnlyWhatImIn(super.source) : super.from();

  @override
  Future<List<MusicRoom>> loadRooms() async {
    final rooms = await super.loadRooms();
    return List<MusicRoom>.unmodifiable(rooms.where(
        (room) => room.members.any((who) => who.userId == currentUserId)));
  }

  @override
  Future<SongProject?> loadProject(String projectId) async {
    for (final room in await loadRooms()) {
      for (final project in room.projects) {
        if (project.id == projectId) return project;
      }
    }
    return null;
  }
}

void main() {
  test('leaving a band takes its songs out of your sets, and only its songs',
      () async {
    final (repository, set, second) = await _twoBands();
    expect(set.projectIds, <String>['song-1', second.id]);

    await repository.leaveRoom('room-1');

    final after = (await repository.loadSetlists()).single;
    expect(after.projectIds, <String>[second.id],
        reason: 'the band they left kept a song in their set');
    expect(after.songFor('song-1'), isNull,
        reason: 'the key and the note on that row went with it');
    expect(after.songFor(second.id), isNotNull);
  });

  test('the set itself stays, with its name and its day on it', () async {
    final (repository, set, _) = await _twoBands();
    final day = DateTime(2026, 10, 4);
    await repository.setSetlistDay(set, day);

    await repository.leaveRoom('room-1');

    final after = (await repository.loadSetlists()).single;
    expect(after.id, set.id);
    expect(after.name, 'Everything I play');
    expect(after.forDay, day,
        reason: 'the day is a fact about the set, not about the room');
  });

  test('being removed takes them too, and nobody else\'s set is touched',
      () async {
    final (repository, _, second) = await _twoBands();

    // Taylor's own set of the same song, which has nothing to do with it.
    repository.currentUserId = 'preview-user';
    final mine = await repository.createSetlist('Ours');
    await repository.addProjectsToSetlist(mine, <String>['song-1']);

    await repository.removeRoomMember(roomId: 'room-1', userId: _jess.userId);

    expect((await _setsOf(repository, _jess.userId)).single.projectIds,
        <String>[second.id]);
    expect((await _setsOf(repository, 'preview-user')).single.projectIds,
        <String>['song-1'],
        reason: 'one person being removed emptied another member\'s set');
  });

  test('rejoining brings nothing back', () async {
    final (repository, _, second) = await _twoBands();
    await repository.leaveRoom('room-1');

    repository.addToRoom('room-1', _jess);

    expect((await repository.loadSetlists()).single.projectIds,
        <String>[second.id],
        reason: 'rejoining the band put the song back in the set');
  });

  test('a song that moves rooms leaves the sets of people who did not follow',
      () async {
    final (repository, _, second) = await _twoBands();

    // Taylor's own set of the song that is about to move.
    repository.currentUserId = 'preview-user';
    final mine = await repository.createSetlist('Ours');
    await repository.addProjectsToSetlist(mine, <String>[second.id]);
    final side = await repository.createRoom(name: 'Side Project', icon: '♪');

    await repository.moveProjects(<SongProject>[second], side);

    expect((await _setsOf(repository, 'preview-user')).single.projectIds,
        <String>[second.id],
        reason: 'Taylor is in the room it moved to, so the song stays');
    expect((await _setsOf(repository, _jess.userId)).single.projectIds,
        <String>['song-1'],
        reason: 'Jess is not, so a song they cannot open is not in their set');
  });

  testWidgets('the set on screen shows what is left of it', (tester) async {
    final (repository, set, _) = await _twoBands();
    final controller = MusicBetaController(repository);
    await controller.load();
    addTearDown(controller.dispose);

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(BetaScope(
      controller: controller,
      child: MaterialApp(
        theme: CoLabRoomTheme.dark(),
        home: SetlistDetailScreen(
          setlistId: set.id,
          loadAnalysis: (_) async => null,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Midnight Signal'), findsOneWidget);
    expect(find.text('Acoustic Idea'), findsOneWidget);

    await controller.leaveRoom('room-1');
    await tester.pumpAndSettle();

    // The screen holds an order of its own so a drag is not clobbered
    // mid-flight; it has to let go of a song the set no longer has.
    expect(find.text('Midnight Signal'), findsNothing);
    expect(find.text('Acoustic Idea'), findsOneWidget);
  });

  group('the copy kept on this phone', () {
    late Directory temporary;

    setUp(() async {
      temporary = await Directory.systemTemp.createTemp('leaving_sets');
    });

    tearDown(() async {
      if (await temporary.exists()) await temporary.delete(recursive: true);
    });

    test('a kept set drops the room you left and keeps the rest', () async {
      final (base, set, second) = await _twoBands();
      final repository = _OnlyWhatImIn(base)..currentUserId = _jess.userId;
      final kept = KeptSongs(
        root: () async => temporary,
        download: (_) async => throw StateError('No network in this test.'),
        owner: () => _jess.userId,
      );
      for (final project in <String>['song-1', second.id]) {
        await kept.keep(
            (await repository.loadProject(project))!, _nothingRecorded);
      }
      expect(await kept.keptIds(), <String>{'song-1', second.id});

      final controller = MusicBetaController(
        repository,
        kept: kept,
        loadSheet: (_) async => _nothingRecorded,
      );
      addTearDown(controller.dispose);
      await controller.load();
      await controller.keptSongsFollowed;
      expect(await kept.keptIds(), <String>{'song-1', second.id},
          reason: 'a library that lists the song does not drop it');

      await controller.leaveRoom('room-1');
      await controller.keptSongsFollowed;

      expect(await kept.keptIds(), <String>{second.id},
          reason: 'the song of a room they left stayed on the phone');
      expect(controller.setlistById(set.id)!.projectIds, <String>[second.id],
          reason: 'the kept copy put the song back in the set');
    });
  });
}
