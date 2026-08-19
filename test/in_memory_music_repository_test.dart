import 'dart:typed_data';

import 'package:colabroom/data/in_memory_music_repository.dart';
import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/name_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('room names keep user capitalization', () async {
    final repository = InMemoryMusicRepository.seeded();
    final room = await repository.createRoom(name: 'My LIVE Room', icon: '🎤');
    expect(room.name, 'My LIVE Room');
  });

  test('duplicate room names are blocked case-insensitively', () async {
    final repository = InMemoryMusicRepository.seeded();
    await expectLater(
      repository.createRoom(name: 'after hours studio', icon: '♪'),
      throwsA(isA<NameConflict>()),
    );
  });

  test('duplicate project names are blocked across different Rooms', () async {
    final repository = InMemoryMusicRepository.seeded();
    final rooms = await repository.loadRooms();
    await expectLater(
      repository.createSong(room: rooms.last, title: 'MIDNIGHT signal'),
      throwsA(isA<NameConflict>()),
    );
  });

  test('accepting an invitation adds the shared Room', () async {
    final repository = InMemoryMusicRepository.seeded();
    final invite = (await repository.loadInvites()).single;

    await repository.acceptInvite(invite: invite);

    final rooms = await repository.loadRooms();
    expect(rooms.any((room) => room.id == invite.roomId), isTrue);
    expect(await repository.loadInvites(), isEmpty);
  });

  test('selected author color is retained on a contribution', () async {
    final repository = InMemoryMusicRepository.seeded();
    final project = (await repository.loadRooms()).first.projects.single;

    final contribution = await repository.addContribution(
      project: project,
      body: 'Blue line',
      colorValue: 0xFF32D4FF,
    );

    expect(contribution.colorValue, 0xFF32D4FF);
  });

  test('lyric imports retain line order and section markers', () async {
    final repository = InMemoryMusicRepository.seeded();
    final project = (await repository.loadRooms()).first.projects.single;

    final imported = await repository.importContributions(
      project: project,
      drafts: const <ContributionDraft>[
        ContributionDraft(body: '[Verse 1]', kind: ContributionKind.section),
        ContributionDraft(body: 'First imported line'),
        ContributionDraft(body: 'Second imported line'),
      ],
    );

    expect(imported.map((line) => line.body), <String>[
      '[Verse 1]',
      'First imported line',
      'Second imported line',
    ]);
    expect(imported.first.kind, ContributionKind.section);
  });

  test('a voice note attaches to one line and can be loaded', () async {
    final repository = InMemoryMusicRepository.seeded();
    final project = (await repository.loadRooms()).first.projects.single;
    final contribution = project.contributions.first;
    final bytes = Uint8List.fromList(<int>[82, 73, 70, 70, 1, 2, 3]);

    final note = await repository.attachVoiceNote(
      project: project,
      contribution: contribution,
      bytes: bytes,
      durationMs: 1250,
    );

    expect(note.contributionId, contribution.id);
    expect(note.durationMs, 1250);
    expect(await repository.loadVoiceNote(note), bytes);
    final updated = (await repository.loadRooms()).first.projects.single;
    expect(updated.contributions.first.voiceNote?.id, note.id);
  });

  test('lines can be inserted in order, edited, and deleted', () async {
    final repository = InMemoryMusicRepository.seeded();
    final project = (await repository.loadRooms()).first.projects.single;

    final inserted = await repository.addContribution(
      project: project,
      body: 'A line between two ideas',
      position: 1536,
    );
    var updated = (await repository.loadRooms()).first.projects.single;
    expect(updated.contributions.map((line) => line.id), <String>['line-1', inserted.id, 'line-2']);

    await repository.updateContribution(contribution: inserted, body: 'An edited middle line');
    updated = (await repository.loadRooms()).first.projects.single;
    expect(updated.contributions[1].body, 'An edited middle line');
    expect(updated.contributions[1].revision, 2);

    await repository.deleteContribution(updated.contributions[1]);
    updated = (await repository.loadRooms()).first.projects.single;
    expect(updated.contributions.map((line) => line.id), <String>['line-1', 'line-2']);
  });

  test('voice notes can be replaced and deleted', () async {
    final repository = InMemoryMusicRepository.seeded();
    var project = (await repository.loadRooms()).first.projects.single;
    var contribution = project.contributions.first;
    final first = await repository.attachVoiceNote(
      project: project,
      contribution: contribution,
      bytes: Uint8List.fromList(<int>[1, 2, 3]),
      durationMs: 400,
    );

    project = (await repository.loadRooms()).first.projects.single;
    contribution = project.contributions.first;
    final replacement = await repository.attachVoiceNote(
      project: project,
      contribution: contribution,
      bytes: Uint8List.fromList(<int>[4, 5, 6]),
      durationMs: 900,
    );
    expect(replacement.id, isNot(first.id));
    expect(await repository.loadVoiceNote(replacement), <int>[4, 5, 6]);

    await repository.deleteVoiceNote(replacement);
    project = (await repository.loadRooms()).first.projects.single;
    expect(project.contributions.first.voiceNote, isNull);
  });

  test('setlists accept batches and projects can move between Rooms', () async {
    final repository = InMemoryMusicRepository.seeded();
    final rooms = await repository.loadRooms();
    final project = rooms.first.projects.single;
    final setlist = await repository.createSetlist('Friday Set');

    await repository.addProjectsToSetlist(setlist, <String>[project.id]);
    expect((await repository.loadSetlists()).single.projectIds, <String>[project.id]);

    await repository.moveProjects(<SongProject>[project], rooms.last);
    final movedRooms = await repository.loadRooms();
    expect(movedRooms.first.projects, isEmpty);
    expect(movedRooms.last.projects.single.id, project.id);
  });
}
