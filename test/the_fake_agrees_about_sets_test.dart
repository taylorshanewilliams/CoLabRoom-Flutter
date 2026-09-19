import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/data/music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/name_policy.dart';
import 'package:flutter_test/flutter_test.dart';

/// The test double agrees with the database about sets.
///
/// Nothing here can make a phone misbehave: the in-memory repository only
/// ever stands in for Supabase in tests. What it can do is make a test lie.
/// It refused a set name that any other person already used, where 0005's
/// `setlists_owner_name_unique` is per owner; and it let anybody rename,
/// delete, add to, take from and reorder anybody's set, where 0005's
/// policies would touch no row. A test written against either of those
/// asserts something that never happens on a phone.
///
/// Holding somebody else's set is not far-fetched, which is why this
/// matters: 0005's read policy is owner-only, but the set for Sunday comes
/// through 0164's security-definer function, so for the week before the day
/// everybody playing has the leader's set object in hand.
///
/// Where the database refuses quietly the fake now does nothing, and where
/// it raises the fake says so. Which is which is not a choice made here: an
/// update or a delete that a policy narrows away matches no row and is no
/// error, while an insert or an upsert that fails a policy raises.
void main() {
  /// Who leads, and who is only playing on Sunday.
  const String leader = 'the-leader';
  const String player = 'preview-user';

  /// A library with two songs and the leader's set of both, with the phone
  /// handed back to whoever is only playing.
  Future<(InMemoryMusicRepository, Setlist)> aSetOfTheLeaders() async {
    final repository = InMemoryMusicRepository.seeded();
    final room = (await repository.loadRooms()).first;
    final second = await repository.createSong(room: room, title: 'Cornerstone');
    repository.currentUserId = leader;
    final made = await repository.createSetlist('Morning service');
    await repository.addProjectsToSetlist(made, <String>['song-1', second.id]);
    final set = (await repository.loadSetlists()).single;
    repository.currentUserId = player;
    return (repository, set);
  }

  /// The leader's row as the table holds it.
  ///
  /// A set is only in its owner's list, so reading it means standing in the
  /// leader's shoes for the length of the read and then giving the phone
  /// back to whoever was holding it.
  Future<List<Setlist>> asTheLeaderHasThem(
      InMemoryMusicRepository repository) async {
    final was = repository.currentUserId;
    repository.currentUserId = leader;
    try {
      return await repository.loadSetlists();
    } finally {
      repository.currentUserId = was;
    }
  }

  group('two people can call a set the same thing', () {
    test('each of them has their own Friday practice', () async {
      final repository = InMemoryMusicRepository.seeded();
      repository.currentUserId = leader;
      await repository.createSetlist('Friday practice');

      repository.currentUserId = player;
      // The index is on (owner_id, the lowered name), so this is a row the
      // database takes.
      final mine = await repository.createSetlist('Friday practice');

      expect(mine.ownerId, player);
      expect(
        (await repository.loadSetlists()).map((set) => set.name),
        <String>['Friday practice'],
      );
      expect(
        (await asTheLeaderHasThem(repository)).map((set) => set.name),
        <String>['Friday practice'],
      );
    });

    test('and one person still cannot have it twice', () async {
      final repository = InMemoryMusicRepository.seeded();
      await repository.createSetlist('Friday practice');

      // Squeezed and lowered the way the index's expression is, so this is
      // the same name to the database.
      expect(
        () => repository.createSetlist('  friday   PRACTICE '),
        throwsA(isA<NameConflict>()),
      );
      expect((await repository.loadSetlists()).length, 1);
    });

    test('a rename can take a name somebody else is using', () async {
      final repository = InMemoryMusicRepository.seeded();
      repository.currentUserId = leader;
      await repository.createSetlist('Morning service');

      repository.currentUserId = player;
      final mine = await repository.createSetlist('Thursday');
      await repository.renameSetlist(mine, 'Morning service');

      expect(
        (await repository.loadSetlists()).single.name,
        'Morning service',
      );
    });

    test('but not one of your own', () async {
      final repository = InMemoryMusicRepository.seeded();
      await repository.createSetlist('Morning service');
      final other = await repository.createSetlist('Thursday');

      expect(
        () => repository.renameSetlist(other, 'Morning service'),
        throwsA(isA<NameConflict>()),
      );
      expect(
        (await repository.loadSetlists()).map((set) => set.name),
        containsAll(<String>['Morning service', 'Thursday']),
      );
    });
  });

  group('a set is its owner\'s to change', () {
    test('somebody else renaming it changes nothing', () async {
      final (repository, set) = await aSetOfTheLeaders();

      await repository.renameSetlist(set, 'Whatever I like');

      expect((await asTheLeaderHasThem(repository)).single.name,
          'Morning service');
    });

    test('and deleting it deletes nothing', () async {
      final (repository, set) = await aSetOfTheLeaders();

      await repository.deleteSetlist(set);

      expect((await asTheLeaderHasThem(repository)).length, 1);
    });

    test('and taking a song out takes nothing out', () async {
      final (repository, set) = await aSetOfTheLeaders();

      await repository.removeProjectFromSetlist(set, 'song-1');

      expect((await asTheLeaderHasThem(repository)).single.projectIds,
          set.projectIds);
    });

    test('adding songs is refused, because an insert cannot go quiet',
        () async {
      final (repository, set) = await aSetOfTheLeaders();
      final third = await repository.createSong(
        room: (await repository.loadRooms()).first,
        title: 'Be thou my vision',
      );

      await expectLater(
        repository.addProjectsToSetlist(set, <String>[third.id]),
        throwsA(isA<StateError>().having(
            (error) => error.message, 'message', MusicRepository.notYourSet)),
      );
      expect((await asTheLeaderHasThem(repository)).single.projectIds,
          set.projectIds);
    });

    test('and so is a reorder, for the same reason', () async {
      final (repository, set) = await aSetOfTheLeaders();

      await expectLater(
        repository.reorderSetlistProjects(
            set, set.projectIds.reversed.toList(growable: false)),
        throwsA(isA<StateError>().having(
            (error) => error.message, 'message', MusicRepository.notYourSet)),
      );
      expect((await asTheLeaderHasThem(repository)).single.projectIds,
          set.projectIds);
    });

    test('but neither of those two speaks when there is nothing to write',
        () async {
      // Both loud refusals sit behind a write the Supabase repository
      // decides not to send at all: it builds its insert rows first and
      // returns when every song asked for is already in the set, and it
      // returns on an empty order before the upsert. No statement reaches
      // Postgres, so no policy refuses, so nobody hears anything -- and the
      // fake has to be just as quiet, or a test asserts a refusal that never
      // happens. Nothing offers either of these in the app; this is here so
      // that the next test written against the fake is not told a story.
      final (repository, set) = await aSetOfTheLeaders();

      await repository.addProjectsToSetlist(set, set.projectIds);
      await repository.reorderSetlistProjects(set, const <String>[]);

      expect((await asTheLeaderHasThem(repository)).single.projectIds,
          set.projectIds);
    });

    test('while the owner can still do all five', () async {
      final (repository, set) = await aSetOfTheLeaders();
      repository.currentUserId = leader;
      final third = await repository.createSong(
        room: (await repository.loadRooms()).first,
        title: 'Be thou my vision',
      );

      await repository.renameSetlist(set, 'Sunday morning');
      var held = (await repository.loadSetlists()).single;
      expect(held.name, 'Sunday morning');

      await repository.addProjectsToSetlist(held, <String>[third.id]);
      held = (await repository.loadSetlists()).single;
      expect(held.projectIds, hasLength(3));

      await repository.reorderSetlistProjects(
          held, held.projectIds.reversed.toList(growable: false));
      held = (await repository.loadSetlists()).single;
      expect(held.projectIds.first, third.id);

      await repository.removeProjectFromSetlist(held, third.id);
      held = (await repository.loadSetlists()).single;
      expect(held.projectIds, hasLength(2));

      await repository.deleteSetlist(held);
      expect(await repository.loadSetlists(), isEmpty);
    });
  });

  group('a room keeps every song added to it', () {
    test('two songs added from the one room snapshot are both there', () async {
      // The same family of drift as the rest of this file, one table over.
      // createSong rebuilt the whole room from the snapshot it was handed, so
      // a second song added to the room as it was before the first did not
      // have the first in it, and a test setting up two songs was quietly
      // left with one. Postgres inserts one row and cannot do that.
      final repository = InMemoryMusicRepository.seeded();
      final room = (await repository.loadRooms()).first;
      final before = room.projects.length;

      final first = await repository.createSong(room: room, title: 'Harbour Lights');
      // The same snapshot again, which is the whole point: a caller holding a
      // room from a moment ago is the ordinary case.
      final second = await repository.createSong(room: room, title: 'Slow Train');

      final held = (await repository.loadRooms()).first;
      expect(held.projects, hasLength(before + 2));
      expect(
        held.projects.map((project) => project.id),
        containsAll(<String>[first.id, second.id]),
      );
      // And the second sits after the first rather than on top of it.
      expect(
        held.projects.firstWhere((project) => project.id == second.id).sortOrder,
        greaterThan(
          held.projects.firstWhere((project) => project.id == first.id).sortOrder,
        ),
      );
    });
  });
}
