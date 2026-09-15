import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/domain/tonight_models.dart';
import 'package:colabroom/features/songs/firsts.dart';
import 'package:colabroom/features/songs/tonight.dart';
import 'package:flutter_test/flutter_test.dart';

/// The seven firsts.
///
/// Something you can now do, unlocked by use rather than by time, shown
/// once. These pin which first each state unlocks and that a first comes
/// before a chord move and after a release.
void main() {
  const me = 'me';
  final t = DateTime(2026, 1, 1);
  SongProject song({
    required String id,
    String room = 'r1',
    bool audio = false,
    SongAnalysisState? state,
    List<Contribution> lines = const <Contribution>[],
  }) =>
      SongProject(
        id: id,
        roomId: room,
        accountId: me,
        title: 'Song $id',
        createdAt: t,
        updatedAt: t,
        hasAudioReference: audio,
        analysisState: state,
        contributions: lines,
      );
  MusicRoom room(String id, List<RoomMember> members, List<SongProject> songs) => MusicRoom(
        id: id,
        accountId: me,
        name: 'Room $id',
        icon: '♪',
        createdAt: t,
        updatedAt: t,
        members: members,
        projects: songs,
      );
  const you = RoomMember(userId: me, displayName: 'Me', role: RoomRole.owner, colorValue: 1);
  const jess = RoomMember(userId: 'jess', displayName: 'Jess', role: RoomRole.editor, colorValue: 2);
  final line = Contribution(
    id: 'c1', projectId: 's1', authorId: me, authorName: 'Me', body: 'a line',
    colorValue: 1, position: 1, createdAt: t,
  );

  test('a sheet unlocks asking the app and practising to it', () {
    final firsts = firstsFor(
      me: me,
      rooms: <MusicRoom>[room('r1', const <RoomMember>[you], <SongProject>[song(id: 's1', audio: true, state: SongAnalysisState.ready)])],
      threads: const <ThreadSummary>[],
    );
    expect(firsts.map((f) => f.id), containsAll(<String>['first-ask-app', 'first-practise']));
    expect(firsts.firstWhere((f) => f.id == 'first-ask-app').projectId, 's1');
  });

  test('words without a recording unlock singing it', () {
    final firsts = firstsFor(
      me: me,
      rooms: <MusicRoom>[room('r1', const <RoomMember>[you], <SongProject>[song(id: 's1', lines: <Contribution>[line])])],
      threads: const <ThreadSummary>[],
    );
    expect(firsts.map((f) => f.id), contains('first-sing-it'));
    expect(firsts.map((f) => f.id), isNot(contains('first-ask-app')));
  });

  test('a room of one unlocks inviting; a band unlocks asking it and talking', () {
    final alone = firstsFor(
      me: me,
      rooms: <MusicRoom>[room('r1', const <RoomMember>[you], const <SongProject>[])],
      threads: const <ThreadSummary>[],
    );
    expect(alone.map((f) => f.id), contains('first-invite'));
    expect(alone.map((f) => f.id), isNot(contains('first-ask-room')));

    final band = firstsFor(
      me: me,
      rooms: <MusicRoom>[room('r1', const <RoomMember>[you, jess], <SongProject>[song(id: 's1', audio: true)])],
      threads: const <ThreadSummary>[ThreadSummary(kind: ThreadKind.room, targetId: 'r1', name: 'Room r1')],
    );
    expect(band.map((f) => f.id), containsAll(<String>['first-ask-room', 'first-say-something']));
    expect(band.map((f) => f.id), isNot(contains('first-invite')));

    final talked = firstsFor(
      me: me,
      rooms: <MusicRoom>[room('r1', const <RoomMember>[you, jess], const <SongProject>[])],
      threads: <ThreadSummary>[ThreadSummary(kind: ThreadKind.room, targetId: 'r1', name: 'Room r1', lastAt: t)],
    );
    expect(talked.map((f) => f.id), isNot(contains('first-say-something')));
  });

  test('a first comes after a release and before a chord move, once', () {
    final firsts = <First>[
      const First(id: 'first-ask-app', title: 'Ask it anything', body: 'x', cta: 'Open', go: FirstGo.openSong, projectId: 's1'),
    ];
    const songForMove = TonightSong(projectId: 's1', title: 'Song', key: 'D major', chords: <String>['D']);
    final even = DateTime(2026, 9, 16);
    final card = composeTonight(today: even, releases: const <ReleaseNote>[], song: songForMove, prompt: null, firsts: firsts, seen: (_) => false);
    expect(card!.kind, TonightKind.firstStep);
    expect(card.id, 'first-ask-app');
    final after = composeTonight(today: even, releases: const <ReleaseNote>[], song: songForMove, prompt: null, firsts: firsts, seen: (id) => id == 'first-ask-app');
    expect(after!.kind, TonightKind.chordMove);
  });
}
