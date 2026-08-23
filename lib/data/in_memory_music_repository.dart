import 'dart:typed_data';

import '../domain/music_models.dart';
import '../domain/name_policy.dart';
import 'music_repository.dart';

class InMemoryMusicRepository implements MusicRepository {
  InMemoryMusicRepository._(this._rooms, this._invites, this._setlists);

  final List<AppNotification> _notifications = <AppNotification>[
    AppNotification(
      id: 'notif-1',
      type: NotificationType.projectUpdate,
      title: 'Jess added to Midnight Signal',
      body: 'Your frequency keeps calling out my name',
      createdAt: DateTime.now().subtract(const Duration(hours: 2)),
    ),
  ];
  NotificationPreferences _preferences = const NotificationPreferences();

  factory InMemoryMusicRepository.seeded() {
    final now = DateTime.now();
    const owner = RoomMember(
      userId: 'preview-user',
      displayName: 'Taylor',
      role: RoomRole.owner,
      colorValue: 0xFFFF8A4C,
    );
    const collaborator = RoomMember(
      userId: 'preview-jess',
      displayName: 'Jess',
      role: RoomRole.editor,
      colorValue: 0xFF3AD3FF,
    );
    final project = SongProject(
      id: 'song-1',
      roomId: 'room-1',
      accountId: 'preview-user',
      title: 'Midnight Signal',
      description: 'A late-night idea becoming a complete song.',
      createdAt: now.subtract(const Duration(days: 3)),
      updatedAt: now.subtract(const Duration(minutes: 18)),
      contributions: <Contribution>[
        Contribution(
          id: 'line-1',
          projectId: 'song-1',
          authorId: owner.userId,
          authorName: owner.displayName,
          body: 'Streetlights blur like a warning in the rain',
          colorValue: owner.colorValue,
          createdAt: now.subtract(const Duration(hours: 4)),
          position: 1024,
        ),
        Contribution(
          id: 'line-2',
          projectId: 'song-1',
          authorId: collaborator.userId,
          authorName: collaborator.displayName,
          body: 'Your frequency keeps calling out my name',
          colorValue: collaborator.colorValue,
          createdAt: now.subtract(const Duration(hours: 2)),
          position: 2048,
        ),
      ],
    );
    return InMemoryMusicRepository._(<MusicRoom>[
      MusicRoom(
        id: 'room-1',
        accountId: 'preview-user',
        name: 'After Hours Studio',
        icon: '♪',
        createdAt: now.subtract(const Duration(days: 8)),
        updatedAt: now.subtract(const Duration(minutes: 18)),
        members: const <RoomMember>[owner, collaborator],
        projects: <SongProject>[project],
        sortOrder: 1024,
      ),
      MusicRoom(
        id: 'room-2',
        accountId: 'preview-user',
        name: 'Acoustic Ideas',
        icon: '♬',
        createdAt: now.subtract(const Duration(days: 2)),
        updatedAt: now.subtract(const Duration(hours: 5)),
        members: const <RoomMember>[owner],
        sortOrder: 2048,
      ),
    ], <BetaInvite>[
      const BetaInvite(
        id: 'invite-1',
        roomId: 'invited-room-1',
        roomName: 'Studio Session',
        inviterName: 'Jess',
        email: 'taylor@example.com',
      ),
    ], <Setlist>[]);
  }

  final List<MusicRoom> _rooms;
  final List<BetaInvite> _invites;
  final List<Setlist> _setlists;
  final Map<String, Uint8List> _voiceNoteBytes = <String, Uint8List>{};
  final List<FeedbackDraft> submittedFeedback = <FeedbackDraft>[];
  int _idSequence = 0;

  @override
  Stream<void> get changes => const Stream<void>.empty();

  @override
  Future<List<MusicRoom>> loadRooms() async {
    final ordered = List<MusicRoom>.from(_rooms)
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return List<MusicRoom>.unmodifiable(ordered);
  }

  @override
  Future<List<BetaInvite>> loadInvites() async => List<BetaInvite>.unmodifiable(_invites);

  @override
  Future<List<AppNotification>> loadNotifications() async =>
      List<AppNotification>.unmodifiable(_notifications);

  @override
  Future<NotificationPreferences> loadNotificationPreferences() async => _preferences;

  @override
  Future<void> setNotificationPreferences(NotificationPreferences preferences) async {
    _preferences = preferences;
  }

  @override
  Future<void> markNotificationRead(AppNotification notification) async {
    final index = _notifications.indexWhere((candidate) => candidate.id == notification.id);
    if (index >= 0) _notifications[index] = _notifications[index].copyWith(readAt: DateTime.now());
  }

  @override
  Future<void> markAllNotificationsRead() async {
    final now = DateTime.now();
    for (var index = 0; index < _notifications.length; index += 1) {
      if (!_notifications[index].isRead) {
        _notifications[index] = _notifications[index].copyWith(readAt: now);
      }
    }
  }

  @override
  Future<List<Setlist>> loadSetlists() async => List<Setlist>.unmodifiable(_setlists);

  @override
  Future<MusicRoom> createRoom({required String name, required String icon}) async {
    final cleaned = NamePolicy.clean(name);
    NamePolicy.requireUsable(cleaned, label: 'Room name');
    if (_rooms.any((room) => NamePolicy.same(room.name, cleaned))) {
      throw const NameConflict('A Room with that name already exists.');
    }
    final now = DateTime.now();
    final room = MusicRoom(
      id: _id('room'),
      accountId: 'preview-user',
      name: cleaned,
      icon: icon,
      createdAt: now,
      updatedAt: now,
      sortOrder: _nextRoomSortOrder(),
      members: const <RoomMember>[
        RoomMember(
          userId: 'preview-user',
          displayName: 'Taylor',
          role: RoomRole.owner,
          colorValue: 0xFFFF8A4C,
        ),
      ],
    );
    _rooms.add(room);
    return room;
  }

  @override
  Future<void> reorderRooms(List<MusicRoom> orderedRooms) async {
    for (var index = 0; index < orderedRooms.length; index += 1) {
      final room = _rooms.firstWhere((candidate) => candidate.id == orderedRooms[index].id);
      _replaceRoom(room.copyWith(sortOrder: (index + 1) * 1024.0));
    }
  }

  final Map<String, Uint8List> _imageBytesByPath = <String, Uint8List>{};

  @override
  Future<MusicRoom> setRoomLogo({required MusicRoom room, required Uint8List bytes}) async {
    final path = 'local/${room.id}/room-logo';
    _imageBytesByPath[path] = bytes;
    final updated = room.copyWith(logoPath: path);
    _replaceRoom(updated);
    return updated;
  }

  @override
  Future<MusicRoom> clearRoomLogo(MusicRoom room) async {
    if (room.logoPath != null) _imageBytesByPath.remove(room.logoPath);
    final updated = room.copyWith(logoPath: null);
    _replaceRoom(updated);
    return updated;
  }

  @override
  Future<Uint8List> loadRoomLogo(MusicRoom room) async => _imageBytesByPath[room.logoPath]!;

  @override
  Future<MusicRoom> renameRoom({required MusicRoom room, required String name}) async {
    final cleaned = NamePolicy.clean(name);
    NamePolicy.requireUsable(cleaned, label: 'Room name');
    if (_rooms.any(
      (candidate) => candidate.id != room.id && NamePolicy.same(candidate.name, cleaned),
    )) {
      throw const NameConflict('A Room with that name already exists.');
    }
    final renamed = room.copyWith(name: cleaned, updatedAt: DateTime.now());
    _replaceRoom(renamed);
    return renamed;
  }

  @override
  Future<void> deleteRoom(MusicRoom room) async {
    _rooms.removeWhere((candidate) => candidate.id == room.id);
  }

  @override
  Future<SongProject> createSong({
    required MusicRoom room,
    required String title,
  }) async {
    final cleaned = NamePolicy.clean(title);
    NamePolicy.requireUsable(cleaned, label: 'Project name');
    if (_allProjects.any((project) => NamePolicy.same(project.title, cleaned))) {
      throw const NameConflict('A project with that name already exists in your account.');
    }
    final now = DateTime.now();
    final maxSort = room.projects.isEmpty
        ? 0.0
        : room.projects.map((project) => project.sortOrder).reduce((a, b) => a > b ? a : b);
    final project = SongProject(
      id: _id('song'),
      roomId: room.id,
      accountId: room.accountId,
      title: cleaned,
      createdAt: now,
      updatedAt: now,
      sortOrder: maxSort + 1024,
    );
    _replaceRoom(
      room.copyWith(
        projects: <SongProject>[...room.projects, project],
        updatedAt: now,
      ),
    );
    return project;
  }

  @override
  Future<void> reorderRoomProjects(MusicRoom room, List<String> orderedProjectIds) async {
    final current = _rooms.firstWhere((candidate) => candidate.id == room.id);
    for (var index = 0; index < orderedProjectIds.length; index += 1) {
      final projectId = orderedProjectIds[index];
      final projectIndex = current.projects.indexWhere((candidate) => candidate.id == projectId);
      if (projectIndex == -1) continue;
      _replaceProject(current.projects[projectIndex].copyWith(sortOrder: (index + 1) * 1024.0));
    }
  }

  @override
  Future<SongProject> setProjectCover({required SongProject project, required Uint8List bytes}) async {
    final path = 'local/${project.roomId}/${project.id}-cover';
    _imageBytesByPath[path] = bytes;
    final updated = project.copyWith(coverImagePath: path);
    _replaceProject(updated);
    return updated;
  }

  @override
  Future<SongProject> clearProjectCover(SongProject project) async {
    if (project.coverImagePath != null) _imageBytesByPath.remove(project.coverImagePath);
    final updated = project.copyWith(coverImagePath: null);
    _replaceProject(updated);
    return updated;
  }

  @override
  Future<Uint8List> loadProjectCover(SongProject project) async =>
      _imageBytesByPath[project.coverImagePath]!;

  @override
  Future<void> deleteSong(SongProject project) async {
    final room = _rooms.firstWhere((candidate) => candidate.id == project.roomId);
    _replaceRoom(room.copyWith(
      projects: room.projects.where((candidate) => candidate.id != project.id).toList(),
      updatedAt: DateTime.now(),
    ));
    for (final setlist in List<Setlist>.from(_setlists)) {
      if (setlist.projectIds.contains(project.id)) {
        _replaceSetlist(setlist.copyWith(
          projectIds: setlist.projectIds.where((id) => id != project.id).toList(growable: false),
          updatedAt: DateTime.now(),
        ));
      }
    }
  }

  @override
  Future<SongProject> renameSong({
    required SongProject project,
    required String title,
  }) async {
    final cleaned = NamePolicy.clean(title);
    NamePolicy.requireUsable(cleaned, label: 'Project name');
    if (_allProjects.any(
      (candidate) => candidate.id != project.id && NamePolicy.same(candidate.title, cleaned),
    )) {
      throw const NameConflict('A project with that name already exists in your account.');
    }
    final renamed = project.copyWith(title: cleaned, updatedAt: DateTime.now());
    _replaceProject(renamed);
    return renamed;
  }

  @override
  Future<SongProject> setSongStatus({required SongProject project, required SongStatus status}) async {
    final updated = project.copyWith(status: status, updatedAt: DateTime.now());
    _replaceProject(updated);
    return updated;
  }

  @override
  Future<Contribution> addContribution({
    required SongProject project,
    required String body,
    int colorValue = 0xFFFF8A4C,
    double? position,
  }) async {
    final cleaned = body.trim();
    if (cleaned.isEmpty) throw const NameConflict('Write something before adding it.');
    final contribution = Contribution(
      id: _id('line'),
      projectId: project.id,
      authorId: 'preview-user',
      authorName: 'Taylor',
      body: cleaned,
      colorValue: colorValue,
      createdAt: DateTime.now(),
      position: position ?? _nextPosition(project),
    );
    _replaceProject(
      project.copyWith(
        contributions: <Contribution>[...project.contributions, contribution],
        updatedAt: contribution.createdAt,
      ),
    );
    return contribution;
  }

  @override
  Future<Contribution> updateContribution({
    required Contribution contribution,
    required String body,
  }) async {
    final cleaned = body.trim();
    if (cleaned.isEmpty) throw const NameConflict('A lyric line cannot be empty.');
    final project = _allProjects.firstWhere((value) => value.id == contribution.projectId);
    final updated = contribution.copyWith(body: cleaned, revision: contribution.revision + 1);
    _replaceProject(
      project.copyWith(
        contributions: project.contributions
            .map((value) => value.id == updated.id ? updated : value)
            .toList(growable: false),
        updatedAt: DateTime.now(),
      ),
    );
    return updated;
  }

  @override
  Future<void> deleteContribution(Contribution contribution) async {
    final project = _allProjects.firstWhere((value) => value.id == contribution.projectId);
    if (contribution.voiceNote != null) {
      _voiceNoteBytes.remove(contribution.voiceNote!.storagePath);
    }
    _replaceProject(
      project.copyWith(
        contributions: project.contributions
            .where((value) => value.id != contribution.id)
            .toList(growable: false),
        updatedAt: DateTime.now(),
      ),
    );
  }

  @override
  Future<List<Contribution>> importContributions({
    required SongProject project,
    required List<ContributionDraft> drafts,
    int colorValue = 0xFFFF8A4C,
  }) async {
    if (drafts.isEmpty) throw const NameConflict('There are no lyric lines to import.');
    final imported = <Contribution>[];
    var stamp = DateTime.now();
    var position = _nextPosition(project);
    for (final draft in drafts) {
      final cleaned = draft.body.trim();
      if (cleaned.isEmpty) continue;
      final contribution = Contribution(
        id: _id('line'),
        projectId: project.id,
        authorId: 'preview-user',
        authorName: 'Taylor',
        body: cleaned,
        colorValue: colorValue,
        createdAt: stamp,
        position: position,
        kind: draft.kind,
      );
      imported.add(contribution);
      stamp = stamp.add(const Duration(microseconds: 1));
      position += 1024;
    }
    if (imported.isEmpty) throw const NameConflict('There are no lyric lines to import.');
    _replaceProject(
      project.copyWith(
        contributions: <Contribution>[...project.contributions, ...imported],
        updatedAt: imported.last.createdAt,
      ),
    );
    return imported;
  }

  @override
  Future<VoiceNote> attachVoiceNote({
    required SongProject project,
    required Contribution contribution,
    required Uint8List bytes,
    required int durationMs,
  }) async {
    final now = DateTime.now();
    final path = '${project.roomId}/${project.id}/voice/${contribution.id}/${now.microsecondsSinceEpoch}.wav';
    final note = VoiceNote(
      id: _id('voice'),
      projectId: project.id,
      contributionId: contribution.id,
      storagePath: path,
      durationMs: durationMs,
      byteSize: bytes.length,
      createdAt: now,
    );
    _voiceNoteBytes[path] = Uint8List.fromList(bytes);
    final previous = contribution.voiceNote;
    if (previous != null) _voiceNoteBytes.remove(previous.storagePath);
    final contributions = project.contributions
        .map((candidate) => candidate.id == contribution.id
            ? candidate.copyWith(voiceNote: note)
            : candidate)
        .toList(growable: false);
    _replaceProject(project.copyWith(contributions: contributions, updatedAt: now));
    return note;
  }

  @override
  Future<Uint8List> loadVoiceNote(VoiceNote note) async {
    final bytes = _voiceNoteBytes[note.storagePath];
    if (bytes == null) throw StateError('That voice note is no longer available.');
    return Uint8List.fromList(bytes);
  }

  @override
  Future<void> deleteVoiceNote(VoiceNote note) async {
    _voiceNoteBytes.remove(note.storagePath);
    final project = _allProjects.firstWhere((value) => value.id == note.projectId);
    final contributions = project.contributions
        .map((value) => value.id == note.contributionId
            ? value.copyWith(clearVoiceNote: true)
            : value)
        .toList(growable: false);
    _replaceProject(project.copyWith(contributions: contributions, updatedAt: DateTime.now()));
  }

  @override
  Future<Setlist> createSetlist(String name) async {
    final cleaned = NamePolicy.clean(name);
    NamePolicy.requireUsable(cleaned, label: 'Setlist name');
    if (_setlists.any((value) => NamePolicy.same(value.name, cleaned))) {
      throw const NameConflict('A setlist with that name already exists.');
    }
    final now = DateTime.now();
    final setlist = Setlist(
      id: _id('setlist'),
      ownerId: 'preview-user',
      name: cleaned,
      createdAt: now,
      updatedAt: now,
    );
    _setlists.add(setlist);
    return setlist;
  }

  @override
  Future<void> addProjectsToSetlist(Setlist setlist, Iterable<String> projectIds) async {
    final knownIds = _allProjects.map((project) => project.id).toSet();
    final merged = <String>{...setlist.projectIds};
    merged.addAll(projectIds.where(knownIds.contains));
    _replaceSetlist(setlist.copyWith(
      projectIds: merged.toList(growable: false),
      updatedAt: DateTime.now(),
    ));
  }

  @override
  Future<void> removeProjectFromSetlist(Setlist setlist, String projectId) async {
    _replaceSetlist(setlist.copyWith(
      projectIds: setlist.projectIds.where((id) => id != projectId).toList(growable: false),
      updatedAt: DateTime.now(),
    ));
  }

  @override
  Future<void> reorderSetlistProjects(Setlist setlist, List<String> orderedProjectIds) async {
    final current = setlist.projectIds.toSet();
    if (orderedProjectIds.toSet().difference(current).isNotEmpty) {
      throw StateError('That song list is out of date. Reopen the setlist and try again.');
    }
    _replaceSetlist(setlist.copyWith(
      projectIds: List<String>.from(orderedProjectIds),
      updatedAt: DateTime.now(),
    ));
  }

  @override
  Future<void> moveProjects(Iterable<SongProject> projects, MusicRoom targetRoom) async {
    final selected = projects.toList(growable: false);
    if (selected.isEmpty) return;
    final selectedIds = selected.map((project) => project.id).toSet();
    for (var index = 0; index < _rooms.length; index += 1) {
      final room = _rooms[index];
      _rooms[index] = room.copyWith(
        projects: room.projects.where((project) => !selectedIds.contains(project.id)).toList(),
        updatedAt: DateTime.now(),
      );
    }
    final currentTarget = _rooms.firstWhere((room) => room.id == targetRoom.id);
    final moved = selected.map((project) => project.copyWith(
          roomId: targetRoom.id,
          updatedAt: DateTime.now(),
        ));
    _replaceRoom(currentTarget.copyWith(
      projects: <SongProject>[...currentTarget.projects, ...moved],
      updatedAt: DateTime.now(),
    ));
  }

  @override
  Future<void> submitFeedback(FeedbackDraft feedback) async {
    submittedFeedback.add(feedback);
  }

  @override
  Future<InviteResult> createInvite({
    required MusicRoom room,
    required String email,
    RoomRole role = RoomRole.editor,
  }) async {
    final cleaned = email.trim().toLowerCase();
    if (!cleaned.contains('@')) throw const NameConflict('Enter a valid email address.');
    // Preview convention: "jess@..." simulates an email that already has an
    // account (so the code dialog is skipped), anything else simulates one
    // that doesn't.
    return InviteResult(
      code: 'MUSIC-${room.id.toUpperCase()}',
      matchedAccount: cleaned.startsWith('jess'),
    );
  }

  @override
  Future<InviteResult> createProjectInvite({
    required SongProject project,
    required String email,
    RoomRole role = RoomRole.editor,
  }) async {
    final cleaned = email.trim().toLowerCase();
    if (!cleaned.contains('@')) throw const NameConflict('Enter a valid email address.');
    return InviteResult(
      code: 'SONG-${project.id.toUpperCase()}',
      matchedAccount: cleaned.startsWith('jess'),
    );
  }

  @override
  Future<void> acceptInvite({String? code, BetaInvite? invite}) async {
    final selected = invite ??
        (code?.trim().toUpperCase() == 'STUDIO-JOIN'
            ? (_invites.isEmpty ? null : _invites.first)
            : null);
    if (selected == null) throw const NameConflict('That invite code is not valid.');
    if (!_rooms.any((room) => room.id == selected.roomId)) {
      final now = DateTime.now();
      _rooms.add(
        MusicRoom(
          id: selected.roomId,
          accountId: 'preview-jess',
          name: selected.roomName,
          icon: '🎙️',
          createdAt: now,
          updatedAt: now,
          sortOrder: _nextRoomSortOrder(),
          members: const <RoomMember>[
            RoomMember(
              userId: 'preview-jess',
              displayName: 'Jess',
              role: RoomRole.owner,
              colorValue: 0xFF3AD3FF,
            ),
            RoomMember(
              userId: 'preview-user',
              displayName: 'Taylor',
              role: RoomRole.editor,
              colorValue: 0xFFFF8A4C,
            ),
          ],
        ),
      );
    }
    _invites.removeWhere((candidate) => candidate.id == selected.id);
  }

  @override
  Future<void> declineInvite(BetaInvite invite) async {
    _invites.removeWhere((candidate) => candidate.id == invite.id);
  }

  @override
  Future<void> setMemberColor({required String roomId, required int colorValue}) async {
    const currentUserId = 'preview-user';
    final room = _rooms.firstWhere((candidate) => candidate.id == roomId);
    if (room.members.any(
      (member) => member.userId != currentUserId && member.colorValue == colorValue,
    )) {
      throw const NameConflict('That color is already being used in this Room.');
    }
    final updatedMembers = room.members
        .map(
          (member) => member.userId == currentUserId
              ? RoomMember(
                  userId: member.userId,
                  displayName: member.displayName,
                  role: member.role,
                  colorValue: colorValue,
                )
              : member,
        )
        .toList(growable: false);
    _replaceRoom(room.copyWith(members: updatedMembers));
  }

  @override
  void dispose() {}

  Iterable<SongProject> get _allProjects => _rooms.expand((room) => room.projects);

  double _nextPosition(SongProject project) {
    if (project.contributions.isEmpty) return 1024;
    return project.contributions
            .map((contribution) => contribution.position)
            .reduce((left, right) => left > right ? left : right) +
        1024;
  }

  double _nextRoomSortOrder() {
    if (_rooms.isEmpty) return 1024;
    return _rooms.map((room) => room.sortOrder).reduce((a, b) => a > b ? a : b) + 1024;
  }

  void _replaceSetlist(Setlist setlist) {
    final index = _setlists.indexWhere((value) => value.id == setlist.id);
    if (index >= 0) _setlists[index] = setlist;
  }

  void _replaceProject(SongProject project) {
    final room = _rooms.firstWhere((candidate) => candidate.id == project.roomId);
    final ordered = project.contributions.toList(growable: false)
      ..sort((left, right) {
        final position = left.position.compareTo(right.position);
        return position == 0 ? left.createdAt.compareTo(right.createdAt) : position;
      });
    final sortedProject = project.copyWith(contributions: ordered);
    final projects = room.projects
        .map((candidate) => candidate.id == project.id ? sortedProject : candidate)
        .toList(growable: false);
    _replaceRoom(room.copyWith(projects: projects, updatedAt: DateTime.now()));
  }

  void _replaceRoom(MusicRoom room) {
    final index = _rooms.indexWhere((candidate) => candidate.id == room.id);
    if (index >= 0) _rooms[index] = room;
  }

  String _id(String prefix) {
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    return '$prefix-$timestamp-${_idSequence++}';
  }
}
