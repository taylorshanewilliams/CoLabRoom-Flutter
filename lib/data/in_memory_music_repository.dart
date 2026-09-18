import 'dart:typed_data';

// Only for PostgrestException: where this fake stands in for a refusal the
// database makes by error code rather than by message, it has to raise the
// same kind of thing, or the screen reading the code sees something else.
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../domain/activity.dart';
import '../domain/calls.dart';
import '../domain/lesson_link.dart';
import '../domain/loop_round.dart';
import '../domain/moment_note.dart';
import '../domain/music_models.dart';
import '../domain/practice_mark.dart';
import '../domain/sealed_take.dart';
import '../domain/song_brief.dart';
import '../domain/sung_in.dart';
import '../domain/song_analysis_models.dart';
import '../domain/tonight_models.dart';
import '../domain/name_policy.dart';
import 'music_repository.dart';
import '../services/invite_link.dart';

class InMemoryMusicRepository implements MusicRepository {
  InMemoryMusicRepository._(this._rooms, this._invites, this._setlists);

  /// The same fixture, reachable by a subclass.
  ///
  /// The generative constructor is private and the entry point is a factory,
  /// which a test double cannot extend — and counting how often a repository
  /// is asked for something is exactly the kind of test worth writing against
  /// this fake. Redirects rather than copies, so a double and the thing it
  /// doubles cannot start from different data.
  InMemoryMusicRepository.from(InMemoryMusicRepository source)
      : this._(source._rooms, source._invites, source._setlists);

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
  Future<void> deleteNotification(AppNotification notification) async {
    _notifications.removeWhere((item) => item.id == notification.id);
  }

  @override
  Future<void> deleteReadNotifications() async {
    _notifications.removeWhere((item) => item.isRead);
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
      throw const NameConflict('A room with that name already exists.');
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
      throw const NameConflict('A room with that name already exists.');
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
    NamePolicy.requireUsable(cleaned, label: 'Song name');
    if (_allProjects.any((project) => NamePolicy.same(project.title, cleaned))) {
      throw const NameConflict('A song with that name already exists in your account.');
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
  Future<bool> discardIfUntouched(String projectId) async {
    for (final room in _rooms) {
      for (final project in room.projects) {
        if (project.id != projectId) continue;
        final empty = !project.hasAudioReference &&
            project.contributions.every((c) => c.body.trim().isEmpty);
        if (!empty) return false;
        await deleteSong(project);
        return true;
      }
    }
    return false;
  }

  @override
  Future<void> deleteSong(SongProject project) async {
    final room = _rooms.firstWhere((candidate) => candidate.id == project.roomId);
    _replaceRoom(room.copyWith(
      projects: room.projects.where((candidate) => candidate.id != project.id).toList(),
      updatedAt: DateTime.now(),
    ));
    for (final setlist in List<Setlist>.from(_setlists)) {
      if (setlist.projectIds.contains(project.id)) {
        _replaceSetlist(setlist.withOrder(
          setlist.projectIds.where((id) => id != project.id),
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
    NamePolicy.requireUsable(cleaned, label: 'Song name');
    if (_allProjects.any(
      (candidate) => candidate.id != project.id && NamePolicy.same(candidate.title, cleaned),
    )) {
      throw const NameConflict('A song with that name already exists in your account.');
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
    // The song as it is stored now, not as the caller last saw it. A save
    // that writes several lines passes the same project to every call, and
    // appending to that copy threw away each line written before this one.
    // The Supabase repository only ever used the id.
    final stored = _allProjects.firstWhere(
      (value) => value.id == project.id,
      orElse: () => project,
    );
    final contribution = Contribution(
      id: _id('line'),
      projectId: project.id,
      authorId: 'preview-user',
      authorName: 'Taylor',
      body: cleaned,
      colorValue: colorValue,
      createdAt: DateTime.now(),
      position: position ?? _nextPosition(stored),
    );
    _replaceProject(
      stored.copyWith(
        contributions: <Contribution>[...stored.contributions, contribution],
        updatedAt: contribution.createdAt,
      ),
    );
    return contribution;
  }

  @override
  Future<Contribution> moveContribution({
    required Contribution contribution,
    required double position,
  }) async {
    final project = _allProjects.firstWhere((value) => value.id == contribution.projectId);
    final stored = project.contributions.firstWhere((value) => value.id == contribution.id);
    final moved = stored.copyWith(position: position);
    _replaceProject(
      project.copyWith(
        contributions: project.contributions
            .map((value) => value.id == moved.id ? moved : value)
            .toList(growable: false),
        updatedAt: DateTime.now(),
      ),
    );
    return moved;
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

  /// Lines cut from each song, newest cut first, every writer's. The real
  /// table keeps them in place with deleted_at set; here they leave the song
  /// and wait, so nothing that reads a song can see one.
  final Map<String, List<Contribution>> _cutLines = <String, List<Contribution>>{};

  @override
  Future<void> cutLine(Contribution line) async {
    final project = _allProjects.firstWhere((value) => value.id == line.projectId);
    final stored = project.contributions.where((value) => value.id == line.id).toList(growable: false);
    // Already cut, or never there: not an error, the same as cut_line.
    if (stored.isEmpty) return;
    // The voice note stays with the line. It is the line's, not the song's.
    _cutLines.putIfAbsent(line.projectId, () => <Contribution>[]).insert(0, stored.single);
    _replaceProject(
      project.copyWith(
        contributions: project.contributions
            .where((value) => value.id != line.id)
            .toList(growable: false),
        updatedAt: DateTime.now(),
      ),
    );
  }

  @override
  Future<List<Contribution>> linesYouCut(SongProject project) async {
    // The signed-in person's own, as lines_you_cut answers for auth.uid().
    return List<Contribution>.unmodifiable(
      (_cutLines[project.id] ?? const <Contribution>[])
          .where((line) => line.authorId == currentUserId),
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
    // The file is named for the note, not for the clock. DateTime.now() only
    // ticks every millisecond or so on some platforms, so a replacement
    // attached straight after the note it replaced used to be handed the same
    // path — and then delete its own bytes while clearing the old ones away.
    final id = _id('voice');
    final path = '${project.roomId}/${project.id}/voice/${contribution.id}/$id.wav';
    final note = VoiceNote(
      id: id,
      projectId: project.id,
      contributionId: contribution.id,
      storagePath: path,
      durationMs: durationMs,
      byteSize: bytes.length,
      createdAt: now,
    );
    final previous = contribution.voiceNote;
    if (previous != null) _voiceNoteBytes.remove(previous.storagePath);
    _voiceNoteBytes[path] = Uint8List.fromList(bytes);
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
    _replaceSetlist(setlist.withOrder(merged, updatedAt: DateTime.now()));
  }

  @override
  Future<void> renameSetlist(Setlist setlist, String name) async {
    final cleaned = NamePolicy.clean(name);
    NamePolicy.requireUsable(cleaned, label: 'Set name');
    if (_setlists.any((value) => value.id != setlist.id && NamePolicy.same(value.name, cleaned))) {
      throw const NameConflict('A setlist with that name already exists.');
    }
    _replaceSetlist(setlist.copyWith(name: cleaned, updatedAt: DateTime.now()));
  }

  @override
  Future<void> deleteSetlist(Setlist setlist) async {
    _setlists.removeWhere((value) => value.id == setlist.id);
  }

  @override
  Future<void> removeProjectFromSetlist(Setlist setlist, String projectId) async {
    _replaceSetlist(setlist.withOrder(
      setlist.projectIds.where((id) => id != projectId),
      updatedAt: DateTime.now(),
    ));
  }

  @override
  Future<void> reorderSetlistProjects(Setlist setlist, List<String> orderedProjectIds) async {
    final current = setlist.projectIds.toSet();
    if (orderedProjectIds.toSet().difference(current).isNotEmpty) {
      throw StateError('That song list is out of date. Reopen the setlist and try again.');
    }
    _replaceSetlist(setlist.withOrder(orderedProjectIds, updatedAt: DateTime.now()));
  }

  @override
  Future<void> saveSetlistSong(Setlist setlist, SetlistSong song) async {
    final cleaned = song.cleaned();
    // The same refusal 0005's update policy makes in the database: a set is
    // its owner's, and an update from anybody else lands on no row.
    if (setlist.ownerId != 'preview-user') {
      throw StateError(MusicRepository.notYourSet);
    }
    // And the other silence: the set is theirs, but the song is not in it
    // any more. Said as that, not as "not yours".
    final held = _setlists.where((value) => value.id == setlist.id).firstOrNull;
    if (held == null || !held.projectIds.contains(song.projectId)) {
      throw StateError(MusicRepository.songNotInSet);
    }
    _replaceSetlist(held.copyWith(
      songs: held.songs
          .map((entry) => entry.projectId == song.projectId ? cleaned : entry)
          .toList(growable: false),
    ));
  }

  /// Unheard counts the fake simply holds, so a badge can be exercised in a
  /// test without a database behind it.
  ///
  /// This repository has no concept of a layer — takes live in Supabase and
  /// in song_layer_service, not here — so there is nothing to derive a count
  /// from. Seeding it directly keeps the fake honest about that rather than
  /// inventing a second, disagreeing model of what a take is.
  final Map<String, int> unheardTakes = <String, int>{};

  /// Nothing arrives here: the fake has no second device writing to it.
  @override
  Stream<String> get projectChanges => const Stream<String>.empty();

  @override
  Future<SongProject?> loadProject(String projectId) async {
    for (final room in _rooms) {
      for (final project in room.projects) {
        if (project.id == projectId) return project;
      }
    }
    return null;
  }

  @override
  Future<Map<String, int>> loadUnheardTakeCounts() async =>
      Map<String, int>.from(unheardTakes);

  /// Seeded by tests; the fake has no second person doing anything.
  final List<ActivityItem> activity = <ActivityItem>[];

  @override
  Future<List<ActivityItem>> loadActivity({int limit = 20}) async => activity
      .where((item) => !_dismissed.contains(item.id))
      .take(limit)
      .toList(growable: false);

  final Set<String> _dismissed = <String>{};

  @override
  Future<void> dismissActivity(String eventId) async => _dismissed.add(eventId);

  @override
  Future<void> restoreActivity(String eventId) async =>
      _dismissed.remove(eventId);

  @override
  Future<void> markProjectSeen(String projectId) async {
    unheardTakes.remove(projectId);
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
  Future<void> askForHelp({
    required String question,
    String? matchedAnswer,
    String? route,
  }) async {
    // Nowhere to send it in the preview, and nothing depends on it having
    // gone anywhere.
  }

  @override
  Future<void> submitFeedback(FeedbackDraft feedback) async {
    submittedFeedback.add(feedback);
  }

  /// Asks and nods, kept in memory so the preview repository behaves like the
  /// real one rather than throwing at the first tap.
  final Map<String, List<SongAsk>> _asks = <String, List<SongAsk>>{};
  final Map<String, List<AskReply>> _replies = <String, List<AskReply>>{};
  int _repliesMade = 0;
  final Map<String, List<DirectMessage>> _messages =
      <String, List<DirectMessage>>{};

  /// What each room has said, and when you last looked at each thread.
  /// Seeded with one line from Jess so the Messages screen has something
  /// unread to show in the preview.
  final Map<String, List<RoomMessage>> _roomMessages =
      <String, List<RoomMessage>>{
    'room-1': <RoomMessage>[
      RoomMessage(
        id: 'room-message-1',
        roomId: 'room-1',
        authorId: 'preview-jess',
        authorName: 'Jess',
        body: 'Got a bass idea for the chorus. Thursday?',
        createdAt: DateTime.now().subtract(const Duration(minutes: 40)),
      ),
    ],
  };
  final Map<String, DateTime> _threadReads = <String, DateTime>{};
  final List<StandingWant> _wants = <StandingWant>[];
  final List<PracticeMark> _practiceMarks = <PracticeMark>[];
  final List<LessonLink> _lessonLinks = <LessonLink>[];
  int _lessonCodesMade = 0;
  final Map<String, ({String title, String teacherName, String? classTitle})> _lessonsOffered =
      <String, ({String title, String teacherName, String? classTitle})>{};
  final Map<String, String> _lessonRooms = <String, String>{};

  /// The class room each class link opened into, by code, so that opening
  /// the link again finds the same room rather than making a second.
  final Map<String, String> _classRoomsJoined = <String, String>{};

  /// The class room each of this person's own links has, by link id, kept
  /// while the class is turned off so that on again is the same room (0148).
  final Map<String, String> _classRoomOfLink = <String, String>{};

  /// Somebody else's lesson link this repository will open. There is only
  /// one person in an in-memory world, so the teacher on the other end of a
  /// lesson has to be put there by hand, for tests and previews. With
  /// [classTitle], the link is a class (0148): opening it also lands in a
  /// room of that name with the whole class.
  void offerLesson({
    required String code,
    required String title,
    required String teacherName,
    String? classTitle,
  }) {
    _lessonsOffered[code] = (title: title, teacherName: teacherName, classTitle: classTitle);
  }

  String _myMeetingCode = 'k7m29xqp';
  final Map<String, ({String personId, String displayName, List<String> plays})> _meetingCodes =
      <String, ({String personId, String displayName, List<String> plays})>{};

  /// Somebody else's meeting code this repository will open, for the same
  /// reason as [offerLesson]: the person on the other end is put there by
  /// hand.
  void offerMeetingCode({
    required String code,
    required String personId,
    required String displayName,
    List<String> plays = const <String>[],
  }) {
    _meetingCodes[code] = (personId: personId, displayName: displayName, plays: plays);
  }

  CallStanding _callStanding = CallStanding.unknown;
  final Map<String, List<InCallPerson>> _calls = <String, List<InCallPerson>>{};

  /// What the preview says after a birth month, for tests that need an adult
  /// or a minor without asking.
  set callStanding(CallStanding standing) => _callStanding = standing;

  /// Somebody else in a room's call, as their phone's heartbeat would say.
  void somebodyInCall({required String roomId, required String userId, required String displayName}) {
    (_calls[roomId] ??= <InCallPerson>[]).add(InCallPerson(userId: userId, displayName: displayName));
  }

  /// Somebody asks to connect, the way scanning your code does on their
  /// phone.
  void somebodyAsks({required String personId, required String displayName, List<String> plays = const <String>[]}) {
    _connections.removeWhere((c) => c.personId == personId);
    _connections.add(Connection(
      personId: personId,
      displayName: displayName,
      plays: plays,
      accepted: false,
      incoming: true,
      since: DateTime.now(),
    ));
  }
  final Map<String, Set<String>> _nods = <String, Set<String>>{};
  final Map<String, String> _nodNotes = <String, String>{};

  /// Who is signed in. A field rather than a constant so a test can be each
  /// end of a question in turn: the owner who asks, then the bandmate who
  /// answers, in one repository that remembers both (0155). Every other
  /// path reads it the way it always did.
  @override
  String currentUserId = 'preview-user';

  final List<ShowcaseLink> _showcase = <ShowcaseLink>[
    ShowcaseLink(
      id: 'preview-link-1',
      url: 'https://open.spotify.com/track/preview',
      platform: 'Spotify',
      title: 'Ladder Of Life',
    ),
    ShowcaseLink(
      id: 'preview-link-2',
      url: 'https://soundcloud.com/preview/demo',
      platform: 'SoundCloud',
      title: 'Kitchen demo, 2024',
    ),
  ];

  @override
  Future<List<ShowcaseLink>> loadShowcase(String profileId) async =>
      List<ShowcaseLink>.unmodifiable(_showcase);

  @override
  Future<void> addShowcaseLink({required String url, String title = ''}) async {
    // The preview refuses what the server refuses, with the same words. A
    // debug build that quietly accepted a link production rejects would send
    // somebody to test a message they never see.
    final platform = _platformOf(url);
    if (platform == null) {
      throw StateError(
        'Links can point to SoundCloud, Spotify, YouTube, Bandcamp, '
        'Apple Music, Vimeo or Audiomack.',
      );
    }
    // The cap from migration 0059's profile_links_capped trigger, raised the
    // same way the server raises it — 54000 with the server's own wording —
    // so the sentence the sheet shows for a full showcase can be seen by
    // hand in a preview build rather than only against real Supabase.
    if (_showcase.length >= 8) {
      throw PostgrestException(
        message: 'A profile can show up to eight links.',
        code: '54000',
      );
    }
    _showcase.add(ShowcaseLink(
      id: 'preview-link-${_showcase.length + 1}',
      url: url.trim(),
      platform: platform,
      title: title.trim(),
    ));
  }

  /// The client-side twin of `private.link_platform` in migration 0059.
  ///
  /// Matched on the host, never on the URL as a whole. `contains('spotify')`
  /// would happily accept `https://evil.example/open.spotify.com`, and a
  /// preview that is more permissive than the server is a preview that teaches
  /// the wrong lesson about the one surface where user-supplied URLs are shown
  /// under somebody's name.
  static String? _platformOf(String url) {
    final trimmed = url.trim();
    if (!trimmed.toLowerCase().startsWith('https://')) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.userInfo.isNotEmpty) return null;
    final host = uri.host.toLowerCase();
    switch (host) {
      case 'soundcloud.com':
      case 'www.soundcloud.com':
      case 'on.soundcloud.com':
        return 'SoundCloud';
      case 'open.spotify.com':
      case 'spotify.link':
        return 'Spotify';
      case 'youtube.com':
      case 'www.youtube.com':
      case 'm.youtube.com':
      case 'youtu.be':
        return 'YouTube';
      case 'music.apple.com':
      case 'embed.music.apple.com':
        return 'Apple Music';
      case 'vimeo.com':
      case 'player.vimeo.com':
        return 'Vimeo';
      case 'audiomack.com':
      case 'www.audiomack.com':
        return 'Audiomack';
    }
    if (host == 'bandcamp.com' || host.endsWith('.bandcamp.com')) {
      return 'Bandcamp';
    }
    return null;
  }

  @override
  Future<void> removeShowcaseLink(String linkId) async {
    _showcase.removeWhere((link) => link.id == linkId);
  }

  @override
  Future<String?> sharedCityWith(String profileId) async => 'Glasgow';

  /// The preview's own profile, mutable so the settings actually do
  /// something when somebody is looking at the app without a server.
  Musician _me = const Musician(
    id: 'preview-user',
    displayName: 'You',
    city: 'Glasgow',
    plays: <String>['rhythm', 'vocal'],
    // Bass is deliberately recorded and unclaimed: it is the state the app
    // is full of and the one the profile can fill in for somebody, rather
    // than a tidy preview where everything has already been declared.
    partsRecorded: <String, int>{'rhythm': 3, 'vocal': 1, 'bass': 2},
    songsPlayedOn: 3,
    peopleWorkedWith: 2,
    discoverable: false,
    locationVisibility: 'collaborators',
    // D3 – G4 across two demos: what the analyser would have heard.
    vocalLowMidi: 50,
    vocalHighMidi: 67,
    vocalRangeSongs: 2,
  );

  final List<AskForMe> _asksForMe = <AskForMe>[
    AskForMe(
      id: 'preview-ask-1',
      projectId: 'preview-project-1',
      songTitle: 'Ladder Of Life',
      askedByName: 'Mara Ellison',
      askedById: 'preview-mara',
      part: 'bass',
      note: 'Something simple under the chorus — you would nail it.',
      createdAt: DateTime(2026, 9, 5, 19, 40),
      // The brief, so the preview shows the card somebody actually gets
      // rather than the bare one it replaced.
      storagePath: 'preview/ladder-of-life.m4a',
      durationMs: 134000,
      musicalKey: 'G',
      bpm: 96,
      partsOnIt: const <String>['vocal', 'lead'],
      hasSongSheet: true,
    ),
  ];

  final List<RoomInviteForMe> _roomInvitesForMe = <RoomInviteForMe>[
    RoomInviteForMe(
      id: 'preview-room-invite-1',
      roomId: 'preview-room-2',
      roomName: 'South Dean',
      invitedByName: 'Dev Okonjo',
      note: 'Come see what we have been working on.',
      createdAt: DateTime(2026, 9, 5, 20, 10),
    ),
  ];

  @override
  Future<void> removeRoomMember({
    required String roomId,
    required String userId,
  }) async {
    final room = _rooms.firstWhere((r) => r.id == roomId);
    if (room.accountId == userId) {
      // The preview refuses what the server refuses, and with the same
      // sentence — a debug build that allowed it would be somebody testing a
      // message they never see.
      throw StateError(
        'The owner cannot leave their own room. Hand it over or delete it.',
      );
    }
    _replaceRoom(room.copyWith(
      members: room.members
          .where((m) => m.userId != userId)
          .toList(growable: false),
    ));
  }

  @override
  Future<void> leaveRoom(String roomId) =>
      removeRoomMember(roomId: roomId, userId: currentUserId);

  @override
  Future<List<InvitableRoom>> roomsICanInviteTo(String profileId) async {
    return <InvitableRoom>[
      for (final room in _rooms)
        InvitableRoom(
          id: room.id,
          name: room.name,
          songCount: room.projects.length,
          alreadyIn: room.members.any((m) => m.userId == profileId),
        ),
    ];
  }

  @override
  Future<void> inviteMusicianToRoom({
    required String roomId,
    required String profileId,
    String note = '',
  }) async {}

  @override
  Future<List<RoomInviteForMe>> roomInvitesForMe() async =>
      List<RoomInviteForMe>.unmodifiable(_roomInvitesForMe);

  @override
  Future<void> answerRoomInvite(String inviteId, {required bool accept}) async {
    _roomInvitesForMe.removeWhere((invite) => invite.id == inviteId);
  }

  final List<BlockedPerson> _blocked = <BlockedPerson>[];

  final Set<String> _onOpenMic = <String>{};

  /// The takes on the preview's songs: who played what, and whether the
  /// room has heard it. Enough of `song_layers` for the one question this
  /// repository has to answer about them -- whose parts a song would carry
  /// in front of strangers (0155). Jess has a bass part on Midnight Signal,
  /// which is the whole reason the seeded song cannot go up on Taylor's
  /// say-so alone.
  final List<_TakeOnSong> _takes = <_TakeOnSong>[
    const _TakeOnSong(
      id: 'take-taylor-vocal',
      projectId: 'song-1',
      recordedBy: 'preview-user',
      part: 'vocal',
    ),
    const _TakeOnSong(
      id: 'take-jess-bass',
      projectId: 'song-1',
      recordedBy: 'preview-jess',
      part: 'bass',
    ),
  ];

  /// One row per take, as 0155's `take_consents`: who was asked, and what
  /// they said. Null is waiting.
  final Map<String, _Consent> _consents = <String, _Consent>{};

  /// Every notification this repository would have sent, to whoever. The
  /// inbox only ever holds the signed-in person's, so a test that wants to
  /// know what a bandmate was told reads it here.
  final List<({String to, AppNotification notification})> told =
      <({String to, AppNotification notification})>[];

  /// Puts somebody else in a room. For a test that needs more people than
  /// the seed has: an order of two cannot show that a skip passes to the
  /// next person rather than back to the first, and nobody seeded is a
  /// viewer.
  void addToRoom(String roomId, RoomMember member) {
    final room = _rooms.firstWhere((room) => room.id == roomId);
    _replaceRoom(room.copyWith(
      members: <RoomMember>[...room.members, member],
    ));
  }

  /// Adds a take to a song. For a test that needs a shape the seed does not
  /// have -- a song whose only part is somebody else's, say. Shared unless
  /// said otherwise, because a draft is never anybody's business.
  String recordTake(
    String projectId, {
    required String part,
    String? by,
    bool shared = true,
    int startMs = 0,
  }) {
    final id = _id('take');
    final who = by ?? currentUserId;
    _takes.add(_TakeOnSong(
      id: id,
      projectId: projectId,
      recordedBy: who,
      part: part,
      shared: shared,
      startMs: startMs,
    ));
    // A take shared onto a song that is already out there asks its own
    // player, whoever they are, the way the trigger in 0155 does.
    if (shared && _onOpenMic.contains(projectId)) {
      _consents[id] = _Consent(userId: who, agreed: null);
      final title = _projectTitle(projectId);
      _tell(
        who,
        type: NotificationType.partQuestion,
        title: 'Your ${PartQuestion.partsInWords(<String>[part])} on $title',
        body: '$title is out there already. Your part goes out with it when '
            'you say yes, and stays with the room until then.',
        projectId: projectId,
      );
    }
    return id;
  }

  void _tell(
    String to, {
    required NotificationType type,
    required String title,
    required String body,
    required String projectId,
    String? actorId,
  }) {
    if (to == actorId) return;
    final notification = AppNotification(
      id: _id('notif'),
      type: type,
      title: title,
      body: body,
      createdAt: DateTime.now(),
      roomId: _roomOf(projectId)?.id,
      projectId: projectId,
      actorId: actorId,
    );
    told.add((to: to, notification: notification));
    if (to == currentUserId) _notifications.insert(0, notification);
  }

  // ---------------------------------------------------------------------
  // Take turns on the loop (0159)
  // ---------------------------------------------------------------------

  /// The rounds, as 0159's `loop_rounds` and `loop_seats`. The rules below
  /// are the functions in that migration, sentence for sentence, so a screen
  /// tested against this fake is tested against the refusals it will meet.
  final List<_Round> _rounds = <_Round>[];

  /// How long a turn sits before it passes on its own. Never shown to
  /// anybody, here or in the app.
  static const Duration _turnPatience = Duration(days: 3);

  /// Lets [howLong] go by with nobody taking the turn. For a test of the
  /// quiet pass, which otherwise needs three days.
  void letTheTurnSit(String roundId, Duration howLong) {
    final round = _rounds.firstWhere((round) => round.id == roundId);
    round.turnSince = round.turnSince.subtract(howLong);
  }

  RoomMember? _memberOf(MusicRoom? room, String userId) {
    for (final member in room?.members ?? const <RoomMember>[]) {
      if (member.userId == userId) return member;
    }
    return null;
  }

  static bool _canRecord(RoomMember? member) =>
      member != null &&
      (member.role == RoomRole.owner || member.role == RoomRole.editor);

  /// `private.loop_seat_state`: played means the room can hear the turn.
  String _seatReadsAs(_Seat seat) {
    if (seat.state == 'waiting') return 'waiting';
    if (seat.state == 'played' &&
        _takes.any((take) => take.id == seat.layerId && take.shared)) {
      return 'played';
    }
    return 'out';
  }

  /// `private.loop_round_up`: the first person still waiting who can still
  /// record in the room.
  String? _upOn(_Round round) {
    if (round.ended) return null;
    final room = _roomOf(round.projectId);
    final waiting = round.seats.where((seat) => seat.state == 'waiting').toList()
      ..sort((a, b) => a.place.compareTo(b.place));
    for (final seat in waiting) {
      if (_canRecord(_memberOf(room, seat.userId))) return seat.userId;
    }
    return null;
  }

  /// `private.tell_whose_turn`: the same two lines however the turn got
  /// there, with no actor on them, and never to the person looking.
  void _tellWhoseTurn(_Round round) {
    final up = _upOn(round);
    if (up == null || up == currentUserId) return;
    _tell(
      up,
      type: NotificationType.projectUpdate,
      title: 'Your turn on ${_projectTitle(round.projectId)}',
      body: 'The loop has come round to you. Skipping is free, and nobody is '
          'told.',
      projectId: round.projectId,
    );
  }

  /// `private.settle_loop_round`: one turn at most, and never the caller's.
  void _settle(_Round round) {
    if (round.ended) return;
    if (DateTime.now().difference(round.turnSince) < _turnPatience) return;
    final holding = _upOn(round);
    if (holding == null || holding == currentUserId) return;
    round.seats.firstWhere((seat) => seat.userId == holding).state = 'out';
    round.turnSince = DateTime.now();
    _tellWhoseTurn(round);
  }

  /// The round, for somebody in its room; the refusal a stranger gets is the
  /// one they would get for a round that does not exist.
  _Round _roundForMember(String roundId) {
    final round = _rounds.where((round) => round.id == roundId).firstOrNull;
    if (round == null ||
        _memberOf(_roomOf(round.projectId), currentUserId) == null) {
      throw PostgrestException(message: 'No such round.', code: '22023');
    }
    return round;
  }

  @override
  Future<List<LoopRound>> loadLoopRounds(String projectId) async {
    final room = _roomOf(projectId);
    if (_memberOf(room, currentUserId) == null) return const <LoopRound>[];
    final rounds = _rounds.where((round) => round.projectId == projectId).toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    for (final round in rounds) {
      _settle(round);
    }
    return <LoopRound>[
      for (final round in rounds)
        LoopRound(
          id: round.id,
          projectId: round.projectId,
          startMs: round.startMs,
          endMs: round.endMs,
          startedAt: round.startedAt,
          startedBy: round.startedBy,
          startedByName: _nameOf(round.startedBy),
          ended: round.ended,
          upId: _upOn(round),
          seats: <LoopSeat>[
            for (final seat in round.seats.toList()
              ..sort((a, b) => a.place.compareTo(b.place)))
              if (seat.userId == currentUserId || _seatReadsAs(seat) != 'out')
                LoopSeat(
                  userId: seat.userId,
                  name: _nameOf(seat.userId),
                  state: SeatState.parse(_seatReadsAs(seat)),
                  layerId: _seatReadsAs(seat) == 'played' ? seat.layerId : null,
                ),
          ],
        ),
    ];
  }

  @override
  Future<String> startLoopRound({
    required String projectId,
    required int startMs,
    required int endMs,
    List<String> order = const <String>[],
  }) async {
    final room = _roomOf(projectId);
    final me = _memberOf(room, currentUserId);
    if (room == null || me == null) {
      throw PostgrestException(message: 'No such song.', code: '22023');
    }
    if (!_canRecord(me)) {
      throw PostgrestException(
        message: 'Only somebody who can record here can start a round.',
        code: '42501',
      );
    }
    if (startMs < 0 || endMs <= startMs) {
      throw PostgrestException(message: 'Choose the bars first.', code: '22023');
    }
    final going = _rounds
        .where((round) => round.projectId == projectId && !round.ended)
        .firstOrNull;
    if (going != null) {
      if (_upOn(going) != null) {
        throw PostgrestException(
          message: 'This song already has a round going.',
          code: '22023',
        );
      }
      going.ended = true;
    }
    // Each person once, the first time they are named.
    final wanted = <String>[];
    for (final id in order) {
      if (!wanted.contains(id)) wanted.add(id);
    }
    if (wanted.isEmpty) wanted.add(currentUserId);
    if (wanted.any((id) => !_canRecord(_memberOf(room, id)))) {
      throw PostgrestException(
        message: 'Everybody in the order has to be able to record in this '
            'room.',
        code: '22023',
      );
    }
    final now = DateTime.now();
    final round = _Round(
      id: _id('round'),
      projectId: projectId,
      startMs: startMs,
      endMs: endMs,
      startedBy: currentUserId,
      startedAt: now,
      turnSince: now,
      seats: <_Seat>[
        for (var i = 0; i < wanted.length; i += 1)
          _Seat(userId: wanted[i], place: i + 1),
      ],
    );
    _rounds.add(round);

    final firstUp = _upOn(round);
    final title = _projectTitle(projectId);
    for (final id in wanted) {
      if (id == firstUp) continue;
      _tell(
        id,
        type: NotificationType.projectUpdate,
        title: '${_nameOf(currentUserId)} started taking turns on $title',
        body: 'You are in the order. Skipping is free, and nobody is told.',
        projectId: projectId,
        actorId: currentUserId,
      );
    }
    _tellWhoseTurn(round);
    return round.id;
  }

  @override
  Future<void> joinLoopRound(String roundId) async {
    final round = _roundForMember(roundId);
    if (!_canRecord(_memberOf(_roomOf(round.projectId), currentUserId))) {
      throw PostgrestException(
        message: 'Only somebody who can record here can take a turn.',
        code: '42501',
      );
    }
    if (round.ended) {
      throw PostgrestException(message: 'That round is over.', code: '22023');
    }
    _settle(round);
    final wasUp = _upOn(round);
    final mine =
        round.seats.where((seat) => seat.userId == currentUserId).firstOrNull;
    if (mine != null && _seatReadsAs(mine) != 'out') return;
    // The end of the order, whether this is a first seat or a way back in.
    var last = 0;
    for (final seat in round.seats) {
      if (seat.place > last) last = seat.place;
    }
    if (mine == null) {
      round.seats.add(_Seat(userId: currentUserId, place: last + 1));
    } else {
      mine
        ..place = last + 1
        ..state = 'waiting'
        ..layerId = null;
    }
    if (wasUp == null) round.turnSince = DateTime.now();
  }

  @override
  Future<void> skipMyTurn(String roundId) async {
    final round = _roundForMember(roundId);
    if (round.ended) return;
    _settle(round);
    final wasUp = _upOn(round);
    final mine = round.seats
        .where((seat) => seat.userId == currentUserId && seat.state == 'waiting')
        .firstOrNull;
    if (mine == null) return;
    mine.state = 'out';
    if (wasUp == currentUserId) {
      round.turnSince = DateTime.now();
      _tellWhoseTurn(round);
    }
  }

  @override
  Future<void> handInMyTurn({
    required String roundId,
    required String layerId,
  }) async {
    final round = _roundForMember(roundId);
    if (round.ended) {
      throw PostgrestException(message: 'That round is over.', code: '22023');
    }
    _settle(round);
    if (_upOn(round) != currentUserId) {
      // 22023, as 0159 raises it: the one refusal here somebody can walk
      // into honestly, so the one whose sentence the app reads out.
      throw PostgrestException(
        message: 'It is not your turn yet.',
        code: '22023',
      );
    }
    final at = _takes.indexWhere((take) =>
        take.id == layerId &&
        take.projectId == round.projectId &&
        take.recordedBy == currentUserId);
    if (at < 0) {
      throw PostgrestException(
        message: 'That take is not yours to hand in.',
        code: '42501',
      );
    }
    final take = _takes[at];
    if (take.startMs < round.startMs || take.startMs >= round.endMs) {
      throw PostgrestException(
        message: 'That take is not on these bars.',
        code: '22023',
      );
    }
    if (_rounds.any(
        (other) => other.seats.any((seat) => seat.layerId == layerId))) {
      throw PostgrestException(
        message: 'That take has already been a turn.',
        code: '22023',
      );
    }
    // Handing it in shares it (0057), which is what lets the next person
    // hear it and what makes 0155's gate count it.
    _takes[at] = take.sharedNow();
    round.seats.firstWhere((seat) => seat.userId == currentUserId)
      ..state = 'played'
      ..layerId = layerId;
    round.turnSince = DateTime.now();
    _tellWhoseTurn(round);
  }

  @override
  Future<void> endLoopRound(String roundId) async {
    final round = _roundForMember(roundId);
    final me = _memberOf(_roomOf(round.projectId), currentUserId);
    if (round.startedBy != currentUserId && me?.role != RoomRole.owner) {
      throw PostgrestException(
        message: "Only whoever started the round, or the room's owner, can "
            'end it.',
        code: '42501',
      );
    }
    round.ended = true;
  }

  MusicRoom? _roomOf(String projectId) {
    for (final room in _rooms) {
      if (room.projects.any((project) => project.id == projectId)) return room;
    }
    return null;
  }

  String _nameOf(String userId) {
    if (userId == currentUserId && userId == 'preview-user') return 'Taylor';
    for (final room in _rooms) {
      for (final member in room.members) {
        if (member.userId == userId) return member.displayName;
      }
    }
    return 'Somebody';
  }

  /// Whether a take may be heard by strangers: shared, and its player said
  /// yes. The one predicate 0155's policies, storage rule and lists share.
  bool _takeIsPublic(_TakeOnSong take) =>
      take.shared && _consents[take.id]?.agreed == true;

  /// Enough on the preview's Open Mic to show the two states that matter: a
  /// song asking for something, and one simply out there to be heard.
  List<OpenMicSong> get _previewOpenMic => <OpenMicSong>[
        OpenMicSong(
          id: 'preview-open-1',
          title: 'Ladder Of Life',
          ownerName: 'Mara Ellison',
          putUpAt: DateTime.now().subtract(const Duration(hours: 5)),
          takeCount: 3,
          askingFor: const <String>['bass'],
          musicalKey: 'G',
          bpm: 96,
          askNote: 'Needs something simple under the chorus.',
          storagePath: 'preview/ladder.m4a',
          durationMs: 184000,
        ),
        OpenMicSong(
          id: 'preview-open-2',
          title: 'Kitchen Window',
          ownerName: 'Dev Okonjo',
          putUpAt: DateTime.now().subtract(const Duration(days: 2)),
          takeCount: 1,
          musicalKey: 'D',
          storagePath: 'preview/kitchen.m4a',
          durationMs: 142000,
        ),
      ];

  @override
  Future<List<OpenMicSong>> openMicSongs({
    String? part,
    int limit = 30,
    bool includeNotAsking = false,
  }) async {
    return <OpenMicSong>[
      for (final song in _previewOpenMic)
        if ((part == null || song.askingFor.contains(part)) &&
            (includeNotAsking || song.isAsking))
          song,
    ];
  }

  @override
  Future<List<OpenMicSong>> songsBy(String profileId) async {
    // Mara owns one and played on the other, which is the pair worth
    // previewing: the section has to read correctly both ways.
    if (profileId != 'preview-mara') return const <OpenMicSong>[];
    return <OpenMicSong>[
      _previewOpenMic.first,
      OpenMicSong(
        id: 'preview-open-2',
        title: 'Kitchen Window',
        ownerName: 'Dev Okonjo',
        putUpAt: DateTime.now().subtract(const Duration(days: 2)),
        takeCount: 1,
        theirParts: const <String>['harmony'],
      ),
    ];
  }

  @override
  Future<List<FeedTrack>> openMicFeed({int limit = 12, String? part}) async {
    final now = DateTime.now();
    final all = <FeedTrack>[
      FeedTrack(
        id: 'preview-open-1',
        title: 'Ladder Of Life',
        ownerId: 'preview-mara',
        ownerName: 'Mara Ellison',
        storagePath: 'preview/ladder.m4a',
        putUpAt: now.subtract(const Duration(hours: 5)),
        askingFor: const <String>['bass'],
        askNote: 'Something simple under the chorus.',
        musicalKey: 'G',
        bpm: 96,
        durationMs: 184000,
        reason: 'Needs a bass',
      ),
      FeedTrack(
        id: 'preview-open-2',
        title: 'Kitchen Window',
        ownerId: 'preview-dev',
        ownerName: 'Dev Okonjo',
        storagePath: 'preview/kitchen.m4a',
        putUpAt: now.subtract(const Duration(days: 2)),
        askingFor: const <String>['harmony'],
        musicalKey: 'D',
        durationMs: 142000,
        // A word you both sing in is said on the card, the way open_mic_feed
        // says it (0156): in place of the stranger's line, and after every
        // reason that placed a card. With nothing declared this is the line
        // it always was, and either way the song stays where it was in the
        // list: the word is a sentence, never a filter and never an order.
        reason: _alsoSingsIn('preview-dev') ?? 'Nothing like what you play',
      ),
    ];
    return <FeedTrack>[
      for (final track in all)
        if (part == null || track.askingFor.contains(part)) track,
    ];
  }

  /// The feed's line for the first word you and [ownerId] both sing in, or
  /// null when there is none.
  ///
  /// Both sides declared it (Every Musician, Same Song, 17 September 2026):
  /// nothing here reads a name, a city or a recording. Whole words, as the
  /// server matches them, after the same folding.
  String? _alsoSingsIn(String ownerId) {
    final mine = _me.singsIn.map(sungInWord).toSet();
    if (mine.isEmpty) return null;
    for (final musician in _everyone) {
      if (musician.id != ownerId) continue;
      for (final word in musician.singsIn) {
        if (mine.contains(sungInWord(word))) return alsoSingsIn(word);
      }
    }
    return null;
  }

  @override
  Future<OpenMicSong?> openMicSong(String projectId) async {
    for (final song in _previewOpenMic) {
      if (song.id != projectId) continue;
      final who = _nods[projectId] ?? const <String>{};
      return OpenMicSong(
        id: song.id,
        title: song.title,
        ownerName: song.ownerName,
        putUpAt: song.putUpAt,
        ownerId: song.ownerId,
        takeCount: song.takeCount,
        askingFor: song.askingFor,
        musicalKey: song.musicalKey,
        bpm: song.bpm,
        askNote: song.askNote,
        theirParts: song.theirParts,
        storagePath: song.storagePath,
        durationMs: song.durationMs,
        ownerAvatarPath: song.ownerAvatarPath,
        heard: who.length,
        heardByMe: who.contains(currentUserId),
      );
    }
    return null;
  }

  @override
  Future<SongAudience?> songAudience(String projectId) async {
    for (final room in _rooms) {
      for (final project in room.projects) {
        if (project.id != projectId) continue;
        final others = <SongListener>[
          for (final member in room.members)
            if (member.userId != currentUserId)
              SongListener(id: member.userId, name: member.displayName),
        ];
        final up = _onOpenMic.contains(projectId);
        // One line per person with a shared take that has been asked
        // about, in the words the sheet shows -- and never a count.
        final byPerson = <String, List<_Consent>>{};
        for (final take in _takes) {
          final consent = _consents[take.id];
          if (take.projectId != projectId || !take.shared || consent == null) {
            continue;
          }
          byPerson.putIfAbsent(consent.userId, () => <_Consent>[]).add(consent);
        }
        PartAnswer answerOf(List<_Consent> rows) {
          if (rows.any((row) => row.agreed == null)) return PartAnswer.waiting;
          if (rows.any((row) => row.agreed == true)) return PartAnswer.yes;
          return PartAnswer.no;
        }
        final answers = <PersonsAnswer>[
          for (final entry in byPerson.entries)
            if (entry.key != currentUserId)
              PersonsAnswer(
                id: entry.key,
                name: _nameOf(entry.key),
                answer: answerOf(entry.value),
              ),
        ]..sort((a, b) => a.name.compareTo(b.name));
        final mine = byPerson[currentUserId];
        return SongAudience(
          reach: up
              ? SongReach.anyone
              : others.isEmpty
                  ? SongReach.justYou
                  : SongReach.room,
          roomName: room.name,
          roomIcon: room.icon,
          onOpenMic: up,
          listeners: others,
          answers: answers,
          myAnswer: mine == null ? null : answerOf(mine),
        );
      }
    }
    return null;
  }

  @override
  Future<void> putOnOpenMic(String projectId) async {
    final room = _roomOf(projectId);
    final me = room?.members
        .where((member) => member.userId == currentUserId)
        .firstOrNull;
    // The same refusal, in the same words, as 0067's function. The seeded
    // song has an editor on it, and a fake that let the editor publish would
    // be testing a screen that never exists.
    if (me == null || me.role != RoomRole.owner) {
      throw PostgrestException(
        message: 'Only the catalog owner can put a song on the Open Mic.',
        code: '42501',
      );
    }
    if (!_askEveryoneOn(projectId)) return;
    _onOpenMic.add(projectId);
  }

  /// 0155's `ask_everyone_on`: your own shared parts are answered yes by the
  /// act of publishing, everybody else with a shared part is asked once,
  /// and the answer is whether the song may go out now.
  bool _askEveryoneOn(String projectId) {
    final asked = <String, List<String>>{};
    for (final take in _takes) {
      if (take.projectId != projectId || !take.shared) continue;
      if (take.recordedBy == currentUserId) {
        final existing = _consents[take.id];
        if (existing == null || existing.agreed == null) {
          _consents[take.id] = _Consent(userId: currentUserId, agreed: true);
        }
        continue;
      }
      if (_consents.containsKey(take.id)) continue;
      _consents[take.id] = _Consent(userId: take.recordedBy, agreed: null);
      asked.putIfAbsent(take.recordedBy, () => <String>[]).add(take.part);
    }
    final title = _projectTitle(projectId);
    for (final entry in asked.entries) {
      final parts = entry.value.toSet().toList()..sort();
      _tell(
        entry.key,
        type: NotificationType.partQuestion,
        title: '${_nameOf(currentUserId)} wants to put $title in front of '
            'everybody',
        body: 'With your ${PartQuestion.partsInWords(parts)} on it. It waits '
            'until you answer, and you can take your part back off it later.',
        projectId: projectId,
        actorId: currentUserId,
      );
    }
    return !_takes.any((take) =>
        take.projectId == projectId &&
        take.shared &&
        (_consents[take.id]?.agreed == null));
  }

  String _projectTitle(String projectId) {
    for (final room in _rooms) {
      for (final project in room.projects) {
        if (project.id == projectId) return project.title;
      }
    }
    return 'A song';
  }

  @override
  Future<List<PartQuestion>> partQuestionsForMe() async {
    final bySong = <String, List<String>>{};
    for (final take in _takes) {
      final consent = _consents[take.id];
      if (consent == null || consent.userId != currentUserId) continue;
      if (consent.agreed != null || !take.shared) continue;
      bySong.putIfAbsent(take.projectId, () => <String>[]).add(take.part);
    }
    return <PartQuestion>[
      for (final entry in bySong.entries)
        PartQuestion(
          projectId: entry.key,
          songTitle: _projectTitle(entry.key),
          askedById: _roomOf(entry.key)?.accountId,
          askedByName: _nameOf(_roomOf(entry.key)?.accountId ?? ''),
          parts: entry.value.toSet().toList()..sort(),
          askedAt: DateTime.now(),
        ),
    ];
  }

  @override
  Future<void> answerForMyPart(String projectId, {required bool yes}) async {
    var touched = 0;
    for (final take in _takes) {
      final consent = _consents[take.id];
      if (take.projectId != projectId || consent?.userId != currentUserId) {
        continue;
      }
      _consents[take.id] = _Consent(userId: currentUserId, agreed: yes);
      touched += 1;
    }
    if (touched == 0) {
      throw PostgrestException(
        message: 'Nobody has asked about your part on this song.',
        code: '22023',
      );
    }
    final title = _projectTitle(projectId);
    final up = _onOpenMic.contains(projectId);
    var cameDown = false;
    if (!yes && up) {
      final hasReference = _rooms
          .expand((room) => room.projects)
          .any((project) => project.id == projectId && project.hasAudioReference);
      final anythingLeft = _takes.any(
          (take) => take.projectId == projectId && _takeIsPublic(take));
      if (!hasReference && !anythingLeft) {
        _onOpenMic.remove(projectId);
        cameDown = true;
      }
    }
    final parts = PartQuestion.partsInWords(<String>{
      for (final take in _takes)
        if (take.projectId == projectId &&
            take.shared &&
            _consents[take.id]?.userId == currentUserId)
          take.part,
    }.toList()..sort());
    final who = _nameOf(currentUserId);
    final String said;
    final String body;
    if (yes) {
      said = '$who said yes';
      body = up
          ? 'Their $parts is on $title for everybody now.'
          : '$title can go out with their $parts on it.';
    } else {
      said = '$who is leaving their part out';
      body = cameDown
          ? 'Nothing was left to hear on $title, so it came down.'
          : up
              ? '$title is still up, without their $parts.'
              : '$title can still go out without it.';
    }
    for (final member in _roomOf(projectId)?.members ?? const <RoomMember>[]) {
      if (member.role != RoomRole.owner) continue;
      _tell(
        member.userId,
        type: NotificationType.projectUpdate,
        title: said,
        body: body,
        projectId: projectId,
        actorId: currentUserId,
      );
    }
  }

  @override
  Future<void> takeOffOpenMic(String projectId) async {
    _onOpenMic.remove(projectId);
  }

  @override
  Future<void> setSongOrigin(String projectId, SongOrigin origin) async {
    for (final room in _rooms) {
      for (final project in room.projects) {
        if (project.id != projectId) continue;
        _replaceProject(project.copyWith(songOrigin: origin));
        // The same thing 0142's RPC does in the same statement: somebody
        // else's song comes off the Open Mic when it is named as one. It
        // clears `showcased_at` too, which has no counterpart here — this
        // repository has never modelled the showcase at all (`showSong` is
        // a no-op and `songAudience` always reports `onShowcase` false).
        if (origin == SongOrigin.cover) _onOpenMic.remove(projectId);
        return;
      }
    }
  }

  @override
  Future<void> setSongKey(String projectId, String? key) async {
    final said = key?.trim();
    for (final room in _rooms) {
      for (final project in room.projects) {
        if (project.id != projectId) continue;
        // Null and empty both clear it, the way 0144's `nullif(btrim(...))`
        // does, so "Use the detected key" reaches the same state whichever
        // way a caller spells nothing.
        _replaceProject(project.copyWith(
          keyOverride: said == null || said.isEmpty ? null : said,
        ));
        return;
      }
    }
  }

  @override
  Future<void> setBarOne(String projectId, int? downbeat) async {
    // Anything below the first downbeat is nothing rather than an error here:
    // 0161 refuses it with a sentence, and this repository is what tests and
    // the offline copy run on, where a refusal has nowhere to be said.
    final said = downbeat == null || downbeat < 1 ? null : downbeat;
    for (final room in _rooms) {
      for (final project in room.projects) {
        if (project.id != projectId) continue;
        _replaceProject(project.copyWith(barOneDownbeat: said));
        return;
      }
    }
  }

  @override
  Future<MusicRoom> ideasRoom() async {
    for (final room in _rooms) {
      if (room.name.trim().toLowerCase() == 'ideas') return room;
    }
    return createRoom(name: 'Ideas', icon: '💡');
  }

  @override
  Future<SongProject> startIdea({String? title}) async {
    final room = await ideasRoom();
    final wanted = (title ?? '').trim();
    return createSong(
      room: room,
      title: wanted.isEmpty
          ? 'Idea ${_rooms.expand((r) => r.projects).length + 1}'
          : wanted,
    );
  }

  @override
  Future<void> blockUser(String profileId) async {
    if (_blocked.any((b) => b.id == profileId)) return;
    _blocked.add(BlockedPerson(
      id: profileId,
      displayName: _everyone
              .where((m) => m.id == profileId)
              .map((m) => m.displayName)
              .firstOrNull ??
          'Someone',
      blockedAt: DateTime.now(),
    ));
  }

  @override
  Future<void> unblockUser(String profileId) async {
    _blocked.removeWhere((b) => b.id == profileId);
  }

  @override
  Future<List<BlockedPerson>> peopleIBlocked() async =>
      List<BlockedPerson>.unmodifiable(_blocked);

  @override
  Future<void> reportContent({
    required String kind,
    required String reason,
    String detail = '',
    String? profileId,
    String? projectId,
    String? layerId,
    String? linkId,
    String? roomId,
  }) async {}

  @override
  Future<List<OfferableSong>> songsICanOffer(String profileId) async {
    final now = DateTime.now();
    return <OfferableSong>[
      OfferableSong(
        id: 'preview-project-1',
        title: 'Midnight Signal',
        updatedAt: now.subtract(const Duration(hours: 3)),
        // A guitar and a voice on it and nothing underneath, so the preview
        // shows the suggestion doing its job.
        partsOnIt: const <String>['vocal', 'rhythm'],
      ),
      OfferableSong(
        id: 'preview-project-2',
        title: 'Paper Moon',
        updatedAt: now.subtract(const Duration(days: 2)),
        // The preview shows this state on purpose: it is the one a picker
        // usually gets wrong by hiding the row and letting somebody wonder
        // where their song went.
        alreadyAsked: true,
      ),
    ];
  }

  @override
  Future<void> askMusician({
    required String projectId,
    required String profileId,
    String? part,
    String note = '',
    AskTerms terms = AskTerms.play,
    String sungIn = '',
  }) async {}

  @override
  Future<List<AskForMe>> asksForMe() async =>
      List<AskForMe>.unmodifiable(_asksForMe);

  @override
  Future<void> answerAsk(String askId, {required bool accept}) async {
    _asksForMe.removeWhere((ask) => ask.id == askId);
  }

  @override
  Future<List<Noticed>> thingsWeNoticed() async {
    // One, so the preview draws the card rather than the empty state — the
    // card is the thing worth looking at.
    if (_me.plays.contains('bass')) return const <Noticed>[];
    return const <Noticed>[
      Noticed(
        kind: NoticedKind.plays,
        subject: 'bass',
        detail: 'You have recorded bass on 3 songs.',
        amount: 3,
      ),
    ];
  }

  @override
  Future<void> checkPicture({
    required String bucket,
    required String path,
    required String kind,
    required String subject,
  }) async {
    // Nothing to call in the preview.
  }

  @override
  Future<({String roomId, String projectId})> startSomethingWith(
    String profileId, {
    String note = '',
  }) async {
    final room = await createRoom(name: 'Something new', icon: '✨');
    final song = await createSong(room: room, title: 'Something with them');
    return (roomId: room.id, projectId: song.id);
  }

  @override
  Future<void> recordPlay(String projectId) async {}

  @override
  Future<List<OpenMicStatus>> myOpenMic() async => <OpenMicStatus>[
        OpenMicStatus(
          id: 'preview-open-1',
          title: 'Ladder Of Life',
          putUpAt: DateTime.now().subtract(const Duration(days: 3)),
          listeners: 12,
          listenersThisWeek: 4,
          offers: 1,
          askingFor: const <String>['bass'],
          storagePath: 'preview/ladder.m4a',
        ),
      ];

  @override
  Future<List<HelpRequest>> myHelpRequests() async => const <HelpRequest>[];

  @override
  Future<MyPlan> myPlan() async =>
      const MyPlan(member: false, sheetsThisMonth: 3, sheetsAllowed: 20);

  @override
  Future<List<ShowcaseSong>> showcase({int limit = 24}) async => <ShowcaseSong>[
        ShowcaseSong(
          id: 'preview-done-1',
          title: 'Long Way Down',
          ownerName: 'Mara Ellison',
          shownAt: DateTime.now().subtract(const Duration(days: 2)),
          storagePath: 'preview/ladder.m4a',
          durationMs: 184000,
          musicalKey: 'G',
          players: const <SongListener>[
            SongListener(id: 'preview-dev', name: 'Dev Okonjo'),
          ],
          madeHere: true,
          metHere: true,
        ),
      ];

  @override
  Future<void> finishSong(String projectId) async {}

  @override
  Future<void> showSong(String projectId) async {}

  @override
  Future<void> unshowSong(String projectId) async {}

  @override
  Future<void> claimPart(String part) async {
    if (_me.plays.contains(part)) return;
    _me = Musician(
      id: _me.id,
      displayName: _me.displayName,
      avatarPath: _me.avatarPath,
      city: _me.city,
      plays: <String>[..._me.plays, part],
      soundsLike: _me.soundsLike,
      singsIn: _me.singsIn,
      partsRecorded: _me.partsRecorded,
      songsPlayedOn: _me.songsPlayedOn,
      peopleWorkedWith: _me.peopleWorkedWith,
      discoverable: _me.discoverable,
      locationVisibility: _me.locationVisibility,
      vocalLowMidi: _me.vocalLowMidi,
      vocalHighMidi: _me.vocalHighMidi,
      vocalRangeSongs: _me.vocalRangeSongs,
    );
  }

  @override
  Future<Musician?> loadMusician(String profileId) async {
    if (profileId == currentUserId) return _me;
    for (final m in _everyone) {
      if (m.id == profileId) return m;
    }
    return null;
  }

  @override
  Future<void> setBio(String bio) async {
    final cleaned = bio.trim();
    _me = Musician(
      id: _me.id,
      displayName: _me.displayName,
      avatarPath: _me.avatarPath,
      city: _me.city,
      // Empty clears it, the same as set_bio does. A field you can fill in
      // and not empty is not a field.
      bio: cleaned.isEmpty
          ? null
          : (cleaned.length > 300 ? cleaned.substring(0, 300) : cleaned),
      plays: _me.plays,
      soundsLike: _me.soundsLike,
      singsIn: _me.singsIn,
      partsRecorded: _me.partsRecorded,
      songsPlayedOn: _me.songsPlayedOn,
      peopleWorkedWith: _me.peopleWorkedWith,
      discoverable: _me.discoverable,
      locationVisibility: _me.locationVisibility,
      vocalLowMidi: _me.vocalLowMidi,
      vocalHighMidi: _me.vocalHighMidi,
      vocalRangeSongs: _me.vocalRangeSongs,
    );
  }

  @override
  Future<void> setOpenMicPresence({
    required bool discoverable,
    String? city,
    String? locationVisibility,
    List<String>? plays,
    List<String>? soundsLike,
    List<String>? singsIn,
  }) async {
    _me = Musician(
      id: _me.id,
      displayName: _me.displayName,
      avatarPath: _me.avatarPath,
      city: city == null ? _me.city : (city.trim().isEmpty ? null : city.trim()),
      bio: _me.bio,
      plays: plays ?? _me.plays,
      // Five, deduplicated, the way tidy_sounds_like does it on the server —
      // so the preview cannot show a profile the database would not accept.
      soundsLike: soundsLike == null
          ? _me.soundsLike
          : <String>{
              for (final t in soundsLike)
                if (t.trim().isNotEmpty) t.trim().toLowerCase(),
            }.take(5).toList(growable: false),
      // The same again for tidy_sings_in (0156): folded to one spelling,
      // in the order chosen, five at most, nothing over forty characters.
      // The length is read off the folded word, as it is there, so white
      // space alone is dropped. Null leaves what was declared alone.
      singsIn: singsIn == null
          ? _me.singsIn
          : <String>{
              for (final word in singsIn.map(sungInWord))
                if (word.isNotEmpty && word.length <= 40) word,
            }.take(5).toList(growable: false),
      partsRecorded: _me.partsRecorded,
      songsPlayedOn: _me.songsPlayedOn,
      peopleWorkedWith: _me.peopleWorkedWith,
      discoverable: discoverable,
      locationVisibility: locationVisibility ?? _me.locationVisibility,
      vocalLowMidi: _me.vocalLowMidi,
      vocalHighMidi: _me.vocalHighMidi,
      vocalRangeSongs: _me.vocalRangeSongs,
    );
  }

  // Enough people, with enough of a record, that the preview shows the
  // difference the design turns on: somebody who has played the thing ranks
  // above somebody who has only said they do.
  static const List<Musician> _everyone = <Musician>[
    Musician(
      id: 'preview-mara',
      displayName: 'Mara Ellison',
      city: 'Glasgow',
      bio: 'Sing mostly, write when nobody is listening. Twelve years in '
          'bands and none of them lasted. Happiest singing on a song that '
          'somebody else started.',
      soundsLike: <String>['indie', 'folk', 'alt-country'],
      plays: <String>['vocal', 'harmony'],
      partsRecorded: <String, int>{'vocal': 9, 'harmony': 4},
      songsPlayedOn: 7,
      peopleWorkedWith: 5,
      // E3 – C5 over five of her own demos. She sings; the page can say
      // how far, because it heard her.
      vocalLowMidi: 52,
      vocalHighMidi: 72,
      vocalRangeSongs: 5,
    ),
    Musician(
      id: 'preview-dev',
      displayName: 'Dev Okonjo',
      // Written down by him, which is the only way the app knows it. The
      // feed says "Also sings in Portuguese" on his song once you have
      // declared it too, and not before.
      singsIn: <String>['portuguese', 'english'],
      plays: <String>['drums', 'percussion'],
      partsRecorded: <String, int>{'drums': 12},
      songsPlayedOn: 11,
      peopleWorkedWith: 6,
    ),
    Musician(
      id: 'preview-sam',
      displayName: 'Sam Reyes',
      city: 'Glasgow',
      plays: <String>['lead', 'rhythm'],
      partsRecorded: <String, int>{},
      songsPlayedOn: 0,
      peopleWorkedWith: 0,
    ),
  ];

  /// The preview's connection graph, in memory.
  ///
  /// Seeded with one of each state so the People screen has all three of its
  /// rows to draw without anybody having to arrange them: a connection, a
  /// request waiting on you, and a request you are waiting on.
  final List<Connection> _connections = <Connection>[
    Connection(
      personId: 'preview-jess',
      displayName: 'Jess',
      accepted: true,
      incoming: false,
      plays: const <String>['Bass'],
      availability: Availability.open,
      availabilityNote: 'around most evenings',
      since: DateTime.now().subtract(const Duration(days: 6)),
    ),
    Connection(
      personId: 'preview-mara',
      displayName: 'Mara',
      accepted: false,
      incoming: true,
      plays: const <String>['Drums'],
      since: DateTime.now().subtract(const Duration(hours: 5)),
    ),
    Connection(
      personId: 'preview-sam',
      displayName: 'Sam',
      accepted: false,
      incoming: false,
      plays: const <String>['Keys'],
      since: DateTime.now().subtract(const Duration(days: 1)),
    ),
  ];

  Availability _myAvailability = Availability.unset;
  String? _myAvailabilityNote;

  /// What the preview would have sent, so a test can read it back.
  final List<({String projectId, String? note, List<String>? personIds, int told})>
      toldAbout =
      <({String projectId, String? note, List<String>? personIds, int told})>[];

  @override
  Future<List<FoundPerson>> searchPeople(String query) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const <FoundPerson>[];
    final hidden = _blocked.map((b) => b.id).toSet();
    return <FoundPerson>[
      for (final m in _everyone)
        if (!hidden.contains(m.id) &&
            m.displayName.toLowerCase().contains(needle))
          FoundPerson(
            personId: m.id,
            displayName: m.displayName,
            avatarPath: m.avatarPath,
            plays: m.plays,
            city: m.city,
            already: standingFrom(
              _connections
                  .where((c) => c.personId == m.id)
                  .map((c) => c.accepted ? 'accepted' : 'pending')
                  .firstOrNull,
            ),
          ),
    ];
  }

  @override
  Future<List<SuggestedPerson>> peopleToTell(String projectId) async {
    final hidden = _blocked.map((b) => b.id).toSet();
    final room = _rooms.firstWhere(
      (r) => r.projects.any((p) => p.id == projectId),
      orElse: () => _rooms.first,
    );
    return <SuggestedPerson>[
      for (final member in room.members)
        if (member.userId != 'preview-user' && !hidden.contains(member.userId))
          SuggestedPerson(
            personId: member.userId,
            displayName: member.displayName,
            because: 'In this room',
          ),
      for (final c in _connections)
        if (c.accepted &&
            !hidden.contains(c.personId) &&
            !room.members.any((m) => m.userId == c.personId))
          SuggestedPerson(
            personId: c.personId,
            displayName: c.displayName,
            because: 'One of your people',
          ),
    ];
  }

  @override
  Future<int> tellAboutSong(
    String projectId, {
    String? note,
    List<String>? personIds,
  }) async {
    final room = _rooms.firstWhere(
      (r) => r.projects.any((p) => p.id == projectId),
      orElse: () => _rooms.first,
    );
    final told = (personIds == null || personIds.isEmpty)
        ? room.members.where((m) => m.userId != 'preview-user').length
        : personIds.length;
    toldAbout.add((
      projectId: projectId,
      note: note,
      personIds: personIds,
      told: told,
    ));
    return told;
  }

  @override
  Future<List<Connection>> listConnections() async {
    final hidden = _blocked.map((b) => b.id).toSet();
    final visible = _connections
        .where((c) => !hidden.contains(c.personId))
        .toList(growable: false);
    return <Connection>[
      ...visible.where((c) => !c.accepted),
      ...visible.where((c) => c.accepted),
    ];
  }

  @override
  Future<bool> requestConnection(String personId) async {
    final at = _connections.indexWhere((c) => c.personId == personId);
    // Asking again while waiting changes nothing, as on the server; only a
    // request from them turns into a connection.
    if (at >= 0 && !_connections[at].accepted && !_connections[at].incoming) return false;
    if (at >= 0) {
      // They had already asked. Two people who have each pressed the button
      // are connected, the same as on the server.
      final held = _connections[at];
      _connections[at] = Connection(
        personId: held.personId,
        displayName: held.displayName,
        avatarPath: held.avatarPath,
        plays: held.plays,
        accepted: true,
        incoming: held.incoming,
        availability: held.availability,
        availabilityNote: held.availabilityNote,
        since: DateTime.now(),
      );
      return true;
    }
    final person = _everyone.where((m) => m.id == personId).firstOrNull;
    _connections.add(Connection(
      personId: personId,
      displayName: person?.displayName ?? 'Someone',
      avatarPath: person?.avatarPath,
      plays: person?.plays ?? const <String>[],
      accepted: false,
      incoming: false,
      since: DateTime.now(),
    ));
    return false;
  }

  @override
  Future<void> respondToConnection(String personId, {required bool accept}) async {
    final at = _connections.indexWhere((c) => c.personId == personId);
    if (at < 0) return;
    if (!accept) {
      _connections.removeAt(at);
      return;
    }
    final held = _connections[at];
    _connections[at] = Connection(
      personId: held.personId,
      displayName: held.displayName,
      avatarPath: held.avatarPath,
      plays: held.plays,
      accepted: true,
      incoming: held.incoming,
      availability: held.availability,
      availabilityNote: held.availabilityNote,
      since: DateTime.now(),
    );
  }

  @override
  Future<void> removeConnection(String personId) async {
    _connections.removeWhere((c) => c.personId == personId);
  }

  @override
  Future<List<SuggestedPerson>> peopleYouMightAdd() async {
    final known = _connections.map((c) => c.personId).toSet();
    final hidden = _blocked.map((b) => b.id).toSet();
    return <SuggestedPerson>[
      for (final room in _rooms)
        for (final member in room.members)
          if (member.userId != 'preview-user' &&
              !known.contains(member.userId) &&
              !hidden.contains(member.userId))
            SuggestedPerson(
              personId: member.userId,
              displayName: member.displayName,
              because: 'In ${room.name} with you',
              canMessage: true,
            ),
    ];
  }

  @override
  Future<void> setAvailability(
    Availability state, {
    String? note,
    DateTime? until,
  }) async {
    _myAvailability = state;
    _myAvailabilityNote = note;
  }

  /// What the preview would show for the signed-in person.
  Availability get myAvailability => _myAvailability;
  String? get myAvailabilityNote => _myAvailabilityNote;

  @override
  Future<List<Musician>> findMusicians({
    List<String>? parts,
    String? city,
    int limit = 30,
    String? soundsLike,
  }) async {
    final hidden = _blocked.map((b) => b.id).toSet();
    final wanted = soundsLike?.trim().toLowerCase();
    return <Musician>[
      // The preview hides blocked people the way the server does. A debug
      // build where blocking visibly did nothing would be somebody testing a
      // feature that looks broken.
      for (final m in _everyone.where((m) => !hidden.contains(m.id)))
        if ((parts == null ||
                parts.isEmpty ||
                parts.any((p) =>
                    m.plays.contains(p) || m.partsRecorded.containsKey(p))) &&
            (city == null ||
                city.trim().isEmpty ||
                (m.city ?? '').toLowerCase() == city.trim().toLowerCase()) &&
            (wanted == null ||
                wanted.isEmpty ||
                m.soundsLike.contains(wanted)))
          m,
    ];
  }

  @override
  Future<List<ProvenanceEvent>> loadProvenance(String projectId) async {
    // Enough of a record for the preview to draw a real page rather than an
    // empty state that teaches nobody anything.
    final now = DateTime.now();
    return <ProvenanceEvent>[
      ProvenanceEvent(
        at: now.subtract(const Duration(days: 9, hours: 3)),
        event: 'song created',
        whoName: 'You',
        detail: 'Midnight Signal',
      ),
      ProvenanceEvent(
        at: now.subtract(const Duration(days: 9, hours: 2)),
        event: 'recording uploaded',
        whoName: 'You',
        detail: 'midnight-signal.m4a',
      ),
      ProvenanceEvent(
        at: now.subtract(const Duration(days: 8)),
        event: 'lyric written',
        whoName: 'You',
        detail: 'the streetlight holds its breath',
      ),
      ProvenanceEvent(
        at: now.subtract(const Duration(days: 2)),
        event: 'take recorded',
        whoName: 'Mara',
        detail: 'Lead vocal · Mara',
      ),
    ];
  }

  @override
  Future<List<SongAsk>> loadAsks(String projectId) async {
    return <SongAsk>[
      for (final ask in _asks[projectId] ?? const <SongAsk>[])
        if (!ask.closed) ask,
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// The ask by id, whichever song it is on, or null for one this
  /// repository never made (the inbox's seeded asks are somebody else's).
  SongAsk? _askById(String askId) {
    for (final asks in _asks.values) {
      for (final ask in asks) {
        if (ask.id == askId) return ask;
      }
    }
    return null;
  }

  /// The same rule as the read policy in 0154: an opinion is read by its
  /// writer, and by the person who asked once they have said they are
  /// ready. Everything else is read by everyone who can see the ask.
  @override
  Future<List<AskReply>> loadAskReplies(String askId) async {
    final ask = _askById(askId);
    final ready = ask != null &&
        ask.askedBy == currentUserId &&
        ask.opinionsOpened;
    return List<AskReply>.unmodifiable(<AskReply>[
      for (final reply in _replies[askId] ?? const <AskReply>[])
        if (reply.door != ReplyDoor.opinion ||
            reply.authorId == currentUserId ||
            ready)
          reply,
    ]);
  }

  @override
  Future<AskReply> replyToAsk({
    required String askId,
    required String body,
    ReplyDoor? door,
  }) async =>
      replyArrivesFrom(
        askId: askId,
        personId: currentUserId,
        personName: 'You',
        body: body,
        door: door,
      );

  /// Somebody else says something on an ask.
  ///
  /// This repository has one signed-in person and no network, so the other
  /// side of a conversation has to be played by the test driving it. It
  /// exists for tests that need an opinion written by somebody other than
  /// the person reading it; nothing in the app calls it.
  Future<AskReply> replyArrivesFrom({
    required String askId,
    required String personId,
    required String personName,
    required String body,
    ReplyDoor? door,
  }) async {
    // A counter beside the clock: two lines said in the same microsecond,
    // which a test does, must not share an id.
    final reply = AskReply(
      id: 'reply-${DateTime.now().microsecondsSinceEpoch}-${_repliesMade++}',
      askId: askId,
      authorId: personId,
      authorName: personName,
      body: body.trim(),
      createdAt: DateTime.now(),
      door: door,
    );
    _replies.putIfAbsent(askId, () => <AskReply>[]).add(reply);
    return reply;
  }

  @override
  Future<void> openOpinions(String askId) async {
    for (final asks in _asks.values) {
      final index = asks.indexWhere((ask) => ask.id == askId);
      if (index < 0) continue;
      if (asks[index].askedBy != currentUserId) {
        throw StateError(
            'Only the person who asked decides when to read opinions.');
      }
      asks[index] = asks[index].copyWith(opinionsOpened: true);
      return;
    }
  }

  @override
  Future<void> deleteAskReply(AskReply reply) async {
    _replies[reply.askId]?.removeWhere((existing) => existing.id == reply.id);
  }

  @override
  Future<bool> canMessage(String personId) async =>
      personId != currentUserId &&
      _connections.any((c) => c.personId == personId && c.accepted);

  @override
  Future<List<DirectMessage>> loadMessagesWith(String personId) async =>
      List<DirectMessage>.unmodifiable(
          _messages[personId] ?? const <DirectMessage>[]);

  @override
  Future<DirectMessage> sendMessageTo(
      {required String personId, required String body}) async {
    final message = DirectMessage(
      id: 'message-${DateTime.now().microsecondsSinceEpoch}',
      personId: personId,
      authorId: currentUserId,
      authorName: 'You',
      body: body.trim(),
      createdAt: DateTime.now(),
    );
    _messages.putIfAbsent(personId, () => <DirectMessage>[]).add(message);
    return message;
  }

  @override
  Future<void> deleteMessage(DirectMessage message) async {
    _messages[message.personId]
        ?.removeWhere((existing) => existing.id == message.id);
  }

  int _unreadSince(String key, Iterable<({String authorId, DateTime at})> lines) {
    final since = _threadReads[key];
    return lines
        .where((line) =>
            line.authorId != currentUserId &&
            (since == null || line.at.isAfter(since)))
        .length;
  }

  @override
  Future<List<ThreadSummary>> myThreads() async {
    final threads = <ThreadSummary>[];
    for (final room in _rooms) {
      final lines = _roomMessages[room.id] ?? const <RoomMessage>[];
      final last = lines.isEmpty ? null : lines.last;
      threads.add(ThreadSummary(
        kind: ThreadKind.room,
        targetId: room.id,
        name: room.name,
        icon: room.icon,
        memberCount: room.members.length,
        lastBody: last?.body,
        lastAuthorId: last?.authorId,
        lastAuthorName: last?.authorName,
        lastAt: last?.createdAt,
        unread: _unreadSince('room:${room.id}',
            lines.map((l) => (authorId: l.authorId, at: l.createdAt))),
      ));
    }
    for (final entry in _messages.entries) {
      if (entry.value.isEmpty) continue;
      final last = entry.value.last;
      final person = _connections
          .where((c) => c.personId == entry.key)
          .map((c) => c.displayName)
          .firstOrNull;
      threads.add(ThreadSummary(
        kind: ThreadKind.person,
        targetId: entry.key,
        name: person ?? 'Somebody',
        lastBody: last.body,
        lastAuthorId: last.authorId,
        lastAuthorName: last.authorName,
        lastAt: last.createdAt,
        unread: _unreadSince('person:${entry.key}',
            entry.value.map((l) => (authorId: l.authorId, at: l.createdAt))),
      ));
    }
    threads.sort((a, b) {
      final at = a.lastAt;
      final bt = b.lastAt;
      if (at == null && bt == null) return a.name.compareTo(b.name);
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });
    return threads;
  }

  @override
  Future<void> markThreadRead(
          {required ThreadKind kind, required String targetId}) async =>
      _threadReads['${kind.name}:$targetId'] = DateTime.now();

  @override
  Future<List<RoomMessage>> loadRoomMessages(String roomId) async =>
      List<RoomMessage>.unmodifiable(
          _roomMessages[roomId] ?? const <RoomMessage>[]);

  @override
  Future<RoomMessage> sendRoomMessage(
      {required String roomId, required String body}) async {
    final message = RoomMessage(
      id: 'room-message-${DateTime.now().microsecondsSinceEpoch}',
      roomId: roomId,
      authorId: currentUserId,
      authorName: 'You',
      body: body.trim(),
      createdAt: DateTime.now(),
    );
    _roomMessages.putIfAbsent(roomId, () => <RoomMessage>[]).add(message);
    return message;
  }

  @override
  Future<void> deleteRoomMessage(RoomMessage message) async {
    _roomMessages[message.roomId]
        ?.removeWhere((existing) => existing.id == message.id);
  }

  @override
  Future<Tonight> tonight() async => const Tonight(
        prompt: TonightPrompt(
          id: 1,
          kind: 'first_line',
          title: 'Write the first line',
          body: 'The thing you should have said in the car. One breath, '
              'into the phone.',
          cta: 'Record',
        ),
      );

  @override
  Future<List<ReleaseNote>> releaseNotes() async => const <ReleaseNote>[];

  @override
  Future<List<StandingWant>> myWants() async => List<StandingWant>.unmodifiable(
      _wants.where((want) => want.expiresAt.isAfter(DateTime.now())));

  @override
  Future<StandingWant> leaveWant({
    required String part,
    required String label,
    String? note,
  }) async {
    final cleaned = part.trim().toLowerCase();
    final trimmed = note?.trim() ?? '';
    _wants.removeWhere((want) => want.part == cleaned);
    final want = StandingWant(
      id: 'want-$cleaned',
      part: cleaned,
      label: label,
      note: trimmed.isEmpty ? null : trimmed,
      expiresAt: DateTime.now().add(const Duration(days: 30)),
    );
    _wants.insert(0, want);
    return want;
  }

  @override
  Future<void> dropWant(String id) async {
    _wants.removeWhere((want) => want.id == id);
  }

  @override
  Future<List<LessonLink>> myLessonLinks() async => List<LessonLink>.unmodifiable(
        // A class whose room is gone reads as no class, as my_lesson_links
        // reports it (0148).
        _lessonLinks.map((link) => link.classRoomId != null && !_rooms.any((room) => room.id == link.classRoomId)
            ? _withoutClass(link)
            : link),
      );

  static LessonLink _withoutClass(LessonLink link) => LessonLink(
        id: link.id,
        code: link.code,
        title: link.title,
        createdAt: link.createdAt,
        students: link.students,
      );

  /// The age rule both ends of a lesson link meet, as 0139 applies it: an
  /// account that answered under 13 is closed to them, one that has never
  /// said is asked, and somebody under 18 is told. The sentences are the
  /// server's, kept in [lessonLinksAreForAdults] and its neighbour.
  void _lessonsNeedAnAdult() {
    switch (_callStanding) {
      case CallStanding.refused:
        throw const NameConflict(lessonLinksClosedOnThisAccount);
      case CallStanding.unknown:
        throw const LessonNeedsABirthMonth();
      case CallStanding.minor:
        throw const NameConflict(lessonLinksAreForAdults);
      case CallStanding.adult:
        return;
    }
  }

  @override
  Future<LessonLink> openLessonLink(String title, {bool asClass = false}) async {
    _lessonsNeedAnAdult();
    final cleaned = title.trim().isEmpty ? 'Lessons' : title.trim();
    // The cap, in the server's sentence (0148).
    if (_lessonLinks.length >= lessonLinksOpenAtOnce) {
      throw const NameConflict(lessonLinksAreCapped);
    }
    final named = cleaned.length > 60 ? cleaned.substring(0, 60) : cleaned;
    final classRoom = asClass ? _makeClassRoom(named) : null;
    // The first link's code is the one every test and preview knows; the
    // ones after it differ in their last two characters, and a code is never
    // handed out twice even after the link it belonged to was turned off.
    final code = 'a1b2c3d4e5${((0xf6 + _lessonCodesMade++) & 0xff).toRadixString(16).padLeft(2, '0')}';
    final link = LessonLink(
      id: _id('lesson'),
      code: code,
      title: named,
      createdAt: DateTime.now(),
      classRoomId: classRoom?.id,
      classRoomName: classRoom?.name,
    );
    _lessonLinks.add(link);
    if (classRoom != null) _classRoomOfLink[link.id] = classRoom.id;
    return link;
  }

  @override
  Future<void> setLessonLinkClass(String linkId, {required bool asClass}) async {
    final index = _lessonLinks.indexWhere((link) => link.id == linkId);
    if (index < 0) throw const NameConflict('That is not a lesson link of yours.');
    _lessonsNeedAnAdult();
    final link = _lessonLinks[index];
    if (!asClass) {
      // The room and everybody in it stay, and the link remembers it: a room
      // with people in it is theirs and not the link's, and on again must be
      // that room rather than an empty second one.
      _lessonLinks[index] = _withoutClass(link);
      return;
    }
    // The room the link had, if it is still there; a fresh one only if not.
    final kept = _classRoomOfLink[link.id];
    final classRoom = _rooms.where((room) => room.id == kept).firstOrNull ?? _makeClassRoom(link.title);
    _classRoomOfLink[link.id] = classRoom.id;
    _lessonLinks[index] = LessonLink(
      id: link.id,
      code: link.code,
      title: link.title,
      createdAt: link.createdAt,
      students: link.students,
      classRoomId: classRoom.id,
      classRoomName: classRoom.name,
    );
  }

  @override
  Future<void> closeLessonLink(String linkId) async {
    _lessonLinks.removeWhere((link) => link.id == linkId);
  }

  /// A room for a class, owned by this person and named for the link, as
  /// make_class_room builds one (0148). Never an existing room, even one
  /// called exactly this: a teacher with a band room named "Jazz studio" did
  /// not mean for every student who scans a poster to be added to the band.
  MusicRoom _makeClassRoom(String title) {
    final now = DateTime.now();
    final room = MusicRoom(
      id: _id('room'),
      accountId: currentUserId,
      name: _unusedRoomName(title, accountId: currentUserId),
      icon: '♪',
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

  /// "Jazz studio", or "Jazz studio 2" beside a room of that account already
  /// called that: room names are unique within an account.
  String _unusedRoomName(String base, {required String accountId}) {
    String squashed(String name) => name.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
    var candidate = base;
    var attempt = 1;
    while (_rooms.any((room) => room.accountId == accountId && squashed(room.name) == squashed(candidate))) {
      attempt += 1;
      candidate = '$base $attempt';
    }
    return candidate;
  }

  @override
  Future<CallStanding> myCallStanding() async => _callStanding;

  @override
  Future<CallStanding> setMyBirthMonth({required int year, required int month}) async {
    // As 0138: after an under-13 answer there is no second one.
    if (_callStanding == CallStanding.refused) {
      throw const NameConflict(callsClosedOnThisAccount);
    }
    if (_callStanding != CallStanding.unknown) {
      throw const NameConflict('Your birth month is already saved. To correct it, send feedback from Account.');
    }
    final now = DateTime.now();
    // The last day of the birth month, the careful side, as 0134 does.
    final monthEnd = DateTime(year, month + 1, 0);
    bool reached(int years) => !DateTime(monthEnd.year + years, monthEnd.month, monthEnd.day).isAfter(now);
    if (!reached(13)) return _callStanding = CallStanding.refused;
    _callStanding = reached(18) ? CallStanding.adult : CallStanding.minor;
    return _callStanding;
  }

  @override
  Future<CallTicket> callTicket({required String roomId, required String device}) async {
    if (!_rooms.any((room) => room.id == roomId)) {
      throw const CallRefused('Calls are for people in this room.');
    }
    return switch (_callStanding) {
      CallStanding.unknown => throw const CallRefused('Your birth month first.', birthMonthNeeded: true),
      CallStanding.minor => throw const CallRefused(
          'Calls are for people 18 and over for now. Calls with a parent or guardian are coming.'),
      CallStanding.refused => throw const CallRefused(callsClosedOnThisAccount),
      CallStanding.adult => CallTicket(
          url: 'wss://preview.invalid',
          token: 'preview',
          room: 'room-$roomId',
          identity: '$currentUserId:$device',
        ),
    };
  }

  @override
  Future<void> hearMeInCall({required String roomId, required String device}) async {
    final people = _calls[roomId] ??= <InCallPerson>[];
    if (!people.any((person) => person.userId == currentUserId)) {
      people.add(InCallPerson(userId: currentUserId, displayName: 'Taylor'));
    }
  }

  @override
  Future<void> leaveCall({required String roomId, required String device}) async {
    _calls[roomId]?.removeWhere((person) => person.userId == currentUserId);
  }

  @override
  Future<List<InCallPerson>> roomCall(String roomId) async =>
      List<InCallPerson>.of(_calls[roomId] ?? const <InCallPerson>[]);

  @override
  Future<String> myMeetingCode() async => _myMeetingCode;

  @override
  Future<String> changeMyMeetingCode() async {
    _myMeetingCode = _myMeetingCode == 'k7m29xqp' ? 'p4r8tv2w' : 'k7m29xqp';
    return _myMeetingCode;
  }

  @override
  Future<MetPerson> personWithMeetingCode(String code) async {
    final cleaned = meetingCodeFromText(code);
    if (cleaned != null && cleaned == _myMeetingCode) {
      throw const NameConflict('That is your own code. Show it to somebody.');
    }
    final offered = cleaned == null ? null : _meetingCodes[cleaned];
    if (offered == null) {
      throw const NameConflict('That code does not open anybody. They may have changed it.');
    }
    if (_blocked.any((b) => b.id == offered.personId)) {
      throw const NameConflict('That person cannot be added.');
    }
    final held = _connections.where((c) => c.personId == offered.personId).firstOrNull;
    return MetPerson(
      personId: offered.personId,
      displayName: offered.displayName,
      plays: offered.plays,
      standing: held == null
          ? ConnectionStanding.none
          : held.accepted
              ? ConnectionStanding.accepted
              : ConnectionStanding.pending,
      askedYou: held != null && !held.accepted && held.incoming,
    );
  }

  @override
  Future<String> joinLessonLink(String code) async {
    final cleaned = code.toLowerCase().replaceAll(RegExp(r'[^0-9a-f]'), '');
    if (_lessonLinks.any((link) => link.code == cleaned)) {
      throw const NameConflict('That is your own lesson link. Share it with a student.');
    }
    final offered = _lessonsOffered[cleaned];
    if (offered == null) {
      throw const NameConflict('That lesson link is turned off, or it is not one.');
    }
    // After the link itself, as 0139 does it: a link that was turned off says
    // so to everybody, and nobody is asked for a birth month to open
    // something that was never going to open.
    _lessonsNeedAnAdult();
    final teacherId = 'teacher-${offered.teacherName.toLowerCase()}';
    final now = DateTime.now();
    // The class, as a viewer: listening and talking, never a take in front
    // of everybody (0148). Before the room somebody already has, and every
    // time, as join_lesson_link does it.
    final classTitle = offered.classTitle;
    if (classTitle != null && !_rooms.any((room) => room.id == _classRoomsJoined[cleaned])) {
      final classRoom = MusicRoom(
        id: _id('room'),
        accountId: teacherId,
        name: classTitle,
        icon: '♪',
        createdAt: now,
        updatedAt: now,
        sortOrder: _nextRoomSortOrder(),
        members: <RoomMember>[
          RoomMember(
            userId: teacherId,
            displayName: offered.teacherName,
            role: RoomRole.owner,
            colorValue: 0xFFFF8A4C,
          ),
          const RoomMember(
            userId: 'preview-user',
            displayName: 'Taylor',
            role: RoomRole.viewer,
            colorValue: 0xFF4C8AFF,
          ),
        ],
      );
      _rooms.add(classRoom);
      _classRoomsJoined[cleaned] = classRoom.id;
    }
    final already = _lessonRooms[cleaned];
    if (already != null && _rooms.any((room) => room.id == already)) return already;
    final room = MusicRoom(
      id: _id('room'),
      accountId: teacherId,
      name: '${offered.title} · Taylor',
      icon: '♪',
      createdAt: now,
      updatedAt: now,
      sortOrder: _nextRoomSortOrder(),
      members: <RoomMember>[
        RoomMember(
          userId: 'teacher-${offered.teacherName.toLowerCase()}',
          displayName: offered.teacherName,
          role: RoomRole.owner,
          colorValue: 0xFFFF8A4C,
        ),
        const RoomMember(
          userId: 'preview-user',
          displayName: 'Taylor',
          role: RoomRole.editor,
          colorValue: 0xFF4C8AFF,
        ),
      ],
    );
    _rooms.add(room);
    _lessonRooms[cleaned] = room.id;
    return room.id;
  }

  @override
  Future<bool> isLessonRoom(String roomId) async =>
      _lessonRooms.containsValue(roomId);

  /// A lesson this person teaches: the two of them, this person owning it,
  /// as join_lesson_link builds one on the student's side (0129).
  ///
  /// [offerLesson] puts a teacher on the other end of a link; this puts a
  /// student on the other end of a room. There is one person in an in-memory
  /// world, so which end of a lesson they are standing on has to be said by
  /// hand either way.
  MusicRoom teachALesson({
    required String studentId,
    required String studentName,
    String title = 'Guitar lessons',
  }) {
    final now = DateTime.now();
    final room = MusicRoom(
      id: _id('room'),
      accountId: currentUserId,
      name: '$title · $studentName',
      icon: '♪',
      createdAt: now,
      updatedAt: now,
      sortOrder: _nextRoomSortOrder(),
      members: <RoomMember>[
        const RoomMember(
          userId: 'preview-user',
          displayName: 'Taylor',
          role: RoomRole.owner,
          colorValue: 0xFFFF8A4C,
        ),
        RoomMember(
          userId: studentId,
          displayName: studentName,
          role: RoomRole.editor,
          colorValue: 0xFF4C8AFF,
        ),
      ],
    );
    _rooms.add(room);
    // Keyed by the room, because there is no link on this side: a teacher's
    // own code never opened it. isLessonRoom asks by room either way.
    _lessonRooms['taught-${room.id}'] = room.id;
    return room;
  }

  /// A recording on a song, analysed and ready, for tests and previews of
  /// what travels with a song and what does not (0149). This repository has
  /// no analysis behind it, so a recording here is the fact of one and
  /// nothing that plays.
  void putARecordingOn(String projectId) {
    final project = _allProjects.firstWhere((candidate) => candidate.id == projectId);
    _replaceProject(project.copyWith(
      hasAudioReference: true,
      analysisState: SongAnalysisState.ready,
    ));
  }

  /// Which song each copy made by [sendSongToStudents] came from, so that
  /// sending again finds the copy rather than making a second (0149).
  final Map<String, String> _copiedFrom = <String, String>{};

  @override
  Future<List<String>> lessonRoomsTaught() async => <String>[
        for (final room in _rooms)
          if (_lessonRooms.containsValue(room.id) &&
              room.members.any((member) =>
                  member.userId == currentUserId && member.role == RoomRole.owner))
            room.id,
      ];

  @override
  Future<List<String>> sendSongToStudents({
    required String projectId,
    required List<String> roomIds,
  }) async {
    // The refusals in the server's words (0149), in the server's order.
    if (roomIds.isEmpty) throw const NameConflict('Pick a student first.');
    final song = _allProjects.where((candidate) => candidate.id == projectId).firstOrNull;
    if (song == null) throw const NameConflict('That song could not be found.');
    final sourceRoom = _rooms.firstWhere((room) => room.id == song.roomId);
    // The owner of the room the song lives in, and nobody else: a song
    // leaving its room is the room owner's decision, as putting it on the
    // Open Mic is (0142).
    if (!sourceRoom.members
        .any((member) => member.userId == currentUserId && member.role == RoomRole.owner)) {
      throw const NameConflict('That song is not yours to send.');
    }
    // Every room is checked before anything is copied, because the server
    // rolls the whole statement back: one wrong room sends nothing.
    final taught = await lessonRoomsTaught();
    for (final roomId in roomIds) {
      if (!taught.contains(roomId)) {
        throw const NameConflict('That is not a lesson of yours.');
      }
    }
    // The recording goes only with a song that is ours or public domain
    // (0142), and only when there is one. An unanswered question is not an
    // answer. There is no storage here, so a recording is the fact of one
    // and is copied whole.
    final withAudio = song.hasAudioReference &&
        (song.songOrigin == SongOrigin.ours || song.songOrigin == SongOrigin.publicDomain);
    final sent = <String>[];
    for (final roomId in roomIds) {
      // Already there: the song's own room.
      if (roomId == song.roomId) continue;
      final room = _rooms.firstWhere((candidate) => candidate.id == roomId);
      // A lesson with nobody on the other end is skipped, not refused: it
      // is this person's room, there is just nobody in it to send to.
      if (!room.members.any((member) => member.userId != currentUserId)) continue;
      final already =
          room.projects.where((candidate) => _copiedFrom[candidate.id] == song.id).firstOrNull;
      if (already != null) {
        // A copy whose recording never arrived is finished by sending
        // again, the way the server hands such a copy back for the app to
        // finish; the student, who has the song, is not given a second,
        // and the room is not counted: the song did not arrive today.
        if (withAudio && !already.hasAudioReference) {
          _replaceProject(already.copyWith(
            hasAudioReference: true,
            analysisState: song.analysisState,
          ));
        }
        continue;
      }

      // Named for the student when the title is already taken in the
      // account, which it always is here: the original lives in it.
      final student = room.members.where((member) => member.userId != currentUserId).firstOrNull;
      final studentName =
          (student?.displayName.trim().isEmpty ?? true) ? 'A student' : student!.displayName.trim();
      var title = song.title;
      var attempt = 1;
      while (_allProjects.any((candidate) =>
          candidate.accountId == room.accountId && NamePolicy.same(candidate.title, title))) {
        attempt += 1;
        title = '${song.title} · $studentName${attempt > 2 ? ' ${attempt - 1}' : ''}';
      }

      final now = DateTime.now();
      final copyId = _id('song');
      final maxSort = room.projects.isEmpty
          ? 0.0
          : room.projects.map((project) => project.sortOrder).reduce((a, b) => a > b ? a : b);
      final copy = SongProject(
        id: copyId,
        roomId: room.id,
        accountId: room.accountId,
        title: title,
        description: song.description,
        createdAt: now,
        updatedAt: now,
        sortOrder: maxSort + 1024,
        // Each line with its writer and its colour, under an id of its own.
        // A voice note on a line is that person's and stays behind.
        contributions: <Contribution>[
          for (final line in song.contributions)
            Contribution(
              id: _id('line'),
              projectId: copyId,
              authorId: line.authorId,
              authorName: line.authorName,
              body: line.body,
              colorValue: line.colorValue,
              createdAt: now,
              position: line.position,
              kind: line.kind,
            ),
        ],
        hasAudioReference: withAudio,
        analysisState: withAudio ? song.analysisState : null,
        createdBy: currentUserId,
        songOrigin: song.songOrigin,
        keyOverride: song.keyOverride,
        barOneDownbeat: song.barOneDownbeat,
      );
      _copiedFrom[copyId] = song.id;
      _replaceRoom(room.copyWith(
        projects: <SongProject>[...room.projects, copy],
        updatedAt: now,
      ));
      sent.add(room.id);
    }
    return sent;
  }

  /// Every brief set here (0150), one a song, whoever it is between. Who
  /// reads which is decided on the way out, in [mySongBriefs].
  final List<SongBrief> _songBriefs = <SongBrief>[];

  @override
  Future<List<String>> briefStudents({
    required String projectId,
    required List<String> roomIds,
    required BriefToSend brief,
  }) async {
    // The copies, found by where they came from, as the real one asks the
    // server for them (0149): a send hands back only what it made just now,
    // and the second week of a piece is a brief for copies already there.
    final copies = <String>[
      for (final room in _rooms)
        if (roomIds.contains(room.id))
          for (final song in room.projects)
            if (_copiedFrom[song.id] == projectId) song.id,
    ];
    if (copies.isEmpty) return const <String>[];
    return setSongBriefs(copies, brief);
  }

  /// set_song_briefs (0150), with its refusals in its words and its order.
  ///
  /// Public so that a test can ask for it the way a student's phone could:
  /// through the front door, by the song's id, with nothing in the app
  /// offering it. Everything is checked before anything is written, because
  /// the server rolls the whole statement back.
  Future<List<String>> setSongBriefs(List<String> projectIds, BriefToSend brief) async {
    if (projectIds.isEmpty) throw const NameConflict('Pick a student first.');
    final passage = brief.passage.trim();
    if (passage.isEmpty) throw const NameConflict('Practice needs a part of the song.');
    if (brief.rate < 0.25 || brief.rate > 2) {
      throw const NameConflict('That is not a speed to practise at.');
    }
    final taught = await lessonRoomsTaught();
    final songs = <SongProject>[];
    for (final projectId in projectIds) {
      final song = _allProjects.where((candidate) => candidate.id == projectId).firstOrNull;
      if (song == null) throw const NameConflict('That song could not be found.');
      // The teacher of the lesson the song lives in, still owning the room.
      // The student edits that room, and this is the line that refuses them.
      if (!taught.contains(song.roomId)) {
        throw const NameConflict('That is not a lesson of yours.');
      }
      songs.add(song);
    }

    // Trimmed, with runs of white space folded to one, as the server does it.
    String folded(String words) => NamePolicy.clean(words);
    final phrases = <String>[
      for (final phrase in brief.listeningFor)
        if (folded(phrase).isNotEmpty)
          folded(phrase).length > briefPhraseLength
              ? folded(phrase).substring(0, briefPhraseLength)
              : folded(phrase),
    ].take(briefPhrasesKept).toList(growable: false);
    final due = folded(brief.dueWords ?? '');
    final loop = brief.startMs != null &&
        brief.endMs != null &&
        brief.startMs! >= 0 &&
        brief.endMs! > brief.startMs!;

    final took = <String>[];
    for (final song in songs) {
      final room = _rooms.firstWhere((candidate) => candidate.id == song.roomId);
      // Nobody on the other end: skipped, not refused.
      final student = room.members.where((member) => member.userId != currentUserId).firstOrNull;
      if (student == null) continue;
      _songBriefs.removeWhere((kept) => kept.projectId == song.id);
      _songBriefs.insert(
        0,
        SongBrief(
          // New each time, so a card closed last week comes back this week.
          id: _id('brief'),
          projectId: song.id,
          teacherId: currentUserId,
          studentId: student.userId,
          teacherName: _nameOf(currentUserId),
          passage: passage.length > 40 ? passage.substring(0, 40) : passage,
          startMs: loop ? brief.startMs : null,
          endMs: loop ? brief.endMs : null,
          rate: brief.rate,
          listeningFor: phrases,
          dueWords: due.isEmpty
              ? null
              : (due.length > briefDueLength ? due.substring(0, briefDueLength) : due),
          setAt: DateTime.now(),
        ),
      );
      took.add(song.id);
    }
    return took;
  }

  @override
  Future<List<SongBrief>> mySongBriefs() async => List<SongBrief>.unmodifiable(
        // The two people a brief is between, and nobody else (0150).
        _songBriefs.where((brief) =>
            brief.teacherId == currentUserId || brief.studentId == currentUserId),
      );

  @override
  Future<List<PracticeMark>> myPracticeMarks() async {
    final since = DateTime.now().subtract(const Duration(days: 14));
    return List<PracticeMark>.unmodifiable(
      _practiceMarks.where((mark) => mark.updatedAt.isAfter(since)),
    );
  }

  @override
  Future<void> keepPracticeMark(PracticeMark mark) async {
    final index = _practiceMarks.indexWhere((kept) => kept.id == mark.id);
    final note = (mark.note ?? '').trim().isNotEmpty
        ? mark.note
        : (index >= 0 ? _practiceMarks[index].note : null);
    final kept = PracticeMark(
      id: mark.id,
      projectId: mark.projectId,
      ledBy: mark.ledBy,
      ledByName: mark.ledByName,
      note: note,
      parts: mark.parts,
      updatedAt: DateTime.now(),
    );
    if (index >= 0) _practiceMarks.removeAt(index);
    _practiceMarks.insert(0, kept);
  }

  /// What this person has left students to practise (0143), newest first.
  ///
  /// Kept here and nowhere else, because there is nowhere else it could go:
  /// a mark belongs to the student it is left for, and nothing in the app
  /// ever reads a teacher's back. The server's copy lands on somebody else's
  /// account; this one exists so a test can see that the teacher's action
  /// arrived, and so a preview does not silently do nothing.
  final List<LeftPractice> practiceLeft = <LeftPractice>[];

  @override
  Future<void> leavePracticeForStudent({
    required String projectId,
    required String studentId,
    required String label,
    required double rate,
    int? startMs,
    int? endMs,
    String? note,
  }) async {
    final cleaned = (note ?? '').trim();
    // One per teacher per song, brought up to date, as 0143 does it: the
    // student's Home shows one card a song, and two rows would leave last
    // week's words on it.
    practiceLeft.removeWhere(
      (left) => left.projectId == projectId && left.studentId == studentId,
    );
    practiceLeft.insert(
      0,
      LeftPractice(
        projectId: projectId,
        studentId: studentId,
        label: label,
        rate: rate,
        startMs: startMs,
        endMs: endMs,
        note: cleaned.isEmpty ? null : cleaned,
      ),
    );
  }

  /// Notes pinned to a moment, newest write last and read back in moment
  /// order.
  ///
  /// Nothing here models who can hear what: the real rule is three RLS
  /// policies (0141) and a fake that re-implemented it would be asserting
  /// its own opinion. Whether a note may be pinned at all is decided above
  /// this, by whether the recording is one you can hear.
  final List<MomentNote> _momentNotes = <MomentNote>[];

  /// Takes nobody has been shared with, so a note pinned on one comes back
  /// marked the way 0141's before-insert trigger marks it.
  ///
  /// The one piece of the rule worth modelling here, because it is the piece
  /// the screen shows: a note on your own draft reads "only you". The layers
  /// come from the layer service rather than from this repository, so
  /// whoever sets them up says which ids are drafts.
  final Set<String> draftLayerIds = <String>{};

  @override
  Future<List<MomentNote>> loadMomentNotes(String projectId) async {
    final mine = <MomentNote>[
      for (final note in _momentNotes)
        if (note.projectId == projectId) note,
    ]..sort((a, b) => a.atMs.compareTo(b.atMs));
    return List<MomentNote>.unmodifiable(mine);
  }

  @override
  Future<MomentNote> addMomentNote({
    required String projectId,
    required int atMs,
    required String body,
    String? layerId,
    int? endMs,
  }) async {
    final note = MomentNote(
      id: 'moment-${_momentNotes.length + 1}',
      projectId: projectId,
      layerId: layerId,
      atMs: atMs < 0 ? 0 : atMs,
      endMs: endMs,
      body: body.trim(),
      authorId: currentUserId,
      authorName: 'Taylor',
      // As the trigger does it: the song's own recording is always the
      // room's, and a take is only the room's once it has been shared.
      onSharedTake: layerId == null || !draftLayerIds.contains(layerId),
      createdAt: DateTime.now(),
    );
    _momentNotes.add(note);
    return note;
  }

  /// What was said, by storage path, the way [_voiceNoteBytes] keeps a line's
  /// voice note.
  final Map<String, Uint8List> _spokenNoteBytes = <String, Uint8List>{};

  @override
  Future<MomentNote> addSpokenMomentNote({
    required String roomId,
    required String projectId,
    required int atMs,
    required Uint8List bytes,
    String? layerId,
  }) async {
    final id = 'moment-${_momentNotes.length + 1}';
    final path = '$roomId/$projectId/moments/$id.wav';
    final note = MomentNote(
      id: id,
      projectId: projectId,
      layerId: layerId,
      atMs: atMs < 0 ? 0 : atMs,
      body: '',
      voicePath: path,
      authorId: currentUserId,
      authorName: 'Taylor',
      onSharedTake: layerId == null || !draftLayerIds.contains(layerId),
      createdAt: DateTime.now(),
    );
    _spokenNoteBytes[path] = Uint8List.fromList(bytes);
    _momentNotes.add(note);
    return note;
  }

  @override
  Future<Uint8List> loadSpokenNote(MomentNote note) async {
    final bytes = _spokenNoteBytes[note.voicePath];
    if (bytes == null) throw StateError('That note is no longer here.');
    return Uint8List.fromList(bytes);
  }

  @override
  Future<void> deleteMomentNote(MomentNote note) async {
    // Yours only, the way the function behind this is (0141).
    if (note.authorId == currentUserId) _spokenNoteBytes.remove(note.voicePath);
    _momentNotes.removeWhere(
      (kept) => kept.id == note.id && kept.authorId == currentUserId,
    );
  }

  /// What time it is, for the one thing in here that waits for a day to
  /// come (0158). A test moves it; the app never does.
  DateTime Function() clock = DateTime.now;

  /// The takes that are put away, and until when. Nothing is kept about a
  /// seal that has ended, the way 0158 keeps nothing.
  final Map<String, ({DateTime sealedAt, DateTime until})> _seals =
      <String, ({DateTime sealedAt, DateTime until})>{};

  /// Whether a take is sealed, for a test's stand-in for the takes list:
  /// that list is SongLayerService's and not this repository's, and what it
  /// leaves out is what the database would not hand back.
  bool isPutAway(String takeId) => _seals.containsKey(takeId);

  @override
  Future<DateTime> sealTake(String layerId, {required DateTime until}) async {
    // The same refusals, in the same words and with the same code, as
    // seal_take and the trigger under it (0158). One answer for a take that
    // is not there and a take that is not yours.
    final take = _takes
        .where((one) => one.id == layerId && one.recordedBy == currentUserId)
        .firstOrNull;
    if (take == null) {
      throw const PostgrestException(message: 'No such take.', code: '22023');
    }
    final already = _seals[layerId];
    if (already != null) return already.until;
    if (take.shared) {
      throw const PostgrestException(
        message: 'Only a take nobody else has heard can be sealed.',
        code: '22023',
      );
    }
    final now = clock();
    if (!until.isAfter(now)) {
      throw const PostgrestException(
        message: 'Pick a day that has not come yet.',
        code: '22023',
      );
    }
    final furthest = DateTime(now.year + sealForAtMostYears, now.month,
        now.day, now.hour, now.minute, now.second);
    if (until.isAfter(furthest)) {
      throw const PostgrestException(
        message: 'Ten years is as far as a seal goes.',
        code: '22023',
      );
    }
    _seals[layerId] = (sealedAt: now, until: until);
    return until;
  }

  @override
  Future<List<SealedTake>> sealedTakesDue() async {
    final now = clock();
    final due = <SealedTake>[];
    for (final take in _takes) {
      final seal = _seals[take.id];
      if (seal == null || take.recordedBy != currentUserId) continue;
      if (seal.until.isAfter(now)) continue;
      // A song that is gone has no take list to go back to.
      final room = _roomOf(take.projectId);
      if (room == null) continue;
      due.add(SealedTake(
        id: take.id,
        projectId: take.projectId,
        songTitle: _projectTitle(take.projectId),
        storagePath: '${room.id}/${take.projectId}/layers/${take.id}.m4a',
        part: take.part,
        sealedAt: seal.sealedAt,
        opensAt: seal.until,
      ));
    }
    due.sort((a, b) => a.opensAt.compareTo(b.opensAt));
    return due;
  }

  @override
  Future<void> unsealTake(String layerId) async {
    // Yours only, and quiet when there is nothing to end.
    final mine = _takes.any(
        (one) => one.id == layerId && one.recordedBy == currentUserId);
    if (mine) _seals.remove(layerId);
  }

  @override
  Future<List<WantAround>> wantsAround() async => const <WantAround>[];

  /// The last thing asked of the app, so a test can read it back.
  String? lastQuestion;

  @override
  Future<SongAnswer> askTheSong({
    required String projectId,
    required String question,
  }) async {
    lastQuestion = question;
    final lower = question.toLowerCase();
    final part = lower.contains('drum')
        ? 'drums'
        : lower.contains('harmon')
            ? 'harmony'
            : lower.contains('bass')
                ? 'bass'
                : null;
    return SongAnswer(
      answer: 'In D major the chords the song has not used are Bm and F♯m. '
          'Either sits under the last line of the chorus without anything '
          'else changing.',
      askPart: part,
      askLabel: part == null
          ? 'Or ask somebody: the room, for what it needs'
          : 'Or ask somebody: the room, for $part',
      model: 'preview',
    );
  }

  @override
  Future<SongAsk> askFor({
    required String projectId,
    String? part,
    String note = '',
    AskTerms terms = AskTerms.play,
    String sungIn = '',
  }) async {
    final cleaned = part?.trim();
    final ask = SongAsk(
      id: 'ask-${DateTime.now().microsecondsSinceEpoch}',
      projectId: projectId,
      askedBy: 'preview-user',
      createdAt: DateTime.now(),
      part: cleaned == null || cleaned.isEmpty ? null : cleaned,
      note: note.trim(),
      // Kept as typed, and only what was typed: an ask that did not say
      // stays empty rather than borrowing from anybody's profile. Cut to
      // the column the way the real insert is, so a line in any script is
      // kept whole here exactly when it would be there.
      sungIn: sungInLine(sungIn),
      terms: terms,
    );
    _asks.putIfAbsent(projectId, () => <SongAsk>[]).add(ask);
    return ask;
  }

  @override
  Future<void> closeAsk(SongAsk ask) async {
    final list = _asks[ask.projectId];
    if (list == null) return;
    final index = list.indexWhere((candidate) => candidate.id == ask.id);
    if (index < 0) return;
    list[index] = list[index].copyWith(closed: true);
  }

  @override
  Future<List<String>> loadNods(String projectId) async {
    return _nods[projectId]?.toList(growable: false) ?? const <String>[];
  }

  @override
  Future<void> setNod({
    required String projectId,
    required bool heard,
    String? note,
  }) async {
    final who = _nods.putIfAbsent(projectId, () => <String>{});
    if (heard) {
      who.add(currentUserId);
      final cleaned = note?.trim() ?? '';
      if (cleaned.isEmpty) {
        _nodNotes.remove(projectId);
      } else {
        _nodNotes[projectId] = cleaned;
      }
    } else {
      who.remove(currentUserId);
      _nodNotes.remove(projectId);
    }
  }

  @override
  Future<String?> nodNote(String projectId) async => _nodNotes[projectId];

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
  }) =>
      createProjectInviteFor(
          projectId: project.id, email: email, role: role);

  @override
  Future<InviteResult> createProjectInviteFor({
    required String projectId,
    required String email,
    RoomRole role = RoomRole.editor,
  }) async {
    final cleaned = email.trim().toLowerCase();
    if (!cleaned.contains('@')) throw const NameConflict('Enter a valid email address.');
    return InviteResult(
      code: 'SONG-${projectId.toUpperCase()}',
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
      throw const NameConflict('That color is already being used in this room.');
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

  String? _avatarPath;

  @override
  Future<String?> loadAvatarPath() async => _avatarPath;

  @override
  Future<String> setAvatar(Uint8List bytes) async {
    _avatarBytes = bytes;
    return _avatarPath = 'preview/avatar.png';
  }

  @override
  Future<void> clearAvatar() async {
    _avatarPath = null;
    _avatarBytes = null;
  }

  @override
  Future<Uint8List> loadAvatar(String path) async =>
      _avatarBytes ?? (throw StateError('No avatar set.'));

  Uint8List? _avatarBytes;

  // Nothing to pause: this repository is in memory, so there is no socket and
  // no radio to keep awake.
  @override
  void pauseLiveUpdates() {}

  @override
  void resumeLiveUpdates() {}

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

/// Practice a teacher left a student (0143), as this repository remembers it.
///
/// Not a domain type, and deliberately not one: on a real account this is a
/// row on somebody else's practice_marks that the teacher can never read
/// back. Nothing in the app models it, so nothing outside this fake needs to
/// know the shape.
class LeftPractice {
  const LeftPractice({
    required this.projectId,
    required this.studentId,
    required this.label,
    required this.rate,
    this.startMs,
    this.endMs,
    this.note,
  });

  final String projectId;
  final String studentId;
  final String label;
  final double rate;
  final int? startMs;
  final int? endMs;
  final String? note;
}

/// A take as this repository knows it: enough of `song_layers` to say whose
/// parts a song carries and whether the room has heard them (0155).
class _TakeOnSong {
  const _TakeOnSong({
    required this.id,
    required this.projectId,
    required this.recordedBy,
    required this.part,
    this.shared = true,
    this.startMs = 0,
  });

  final String id;
  final String projectId;
  final String recordedBy;
  final String part;
  final bool shared;

  /// Where on the song it begins (0045). Only a round reads it: a turn
  /// starts on the round's passage.
  final int startMs;

  /// The same take once the room can hear it, which is what handing a turn
  /// in does to a draft.
  _TakeOnSong sharedNow() => _TakeOnSong(
        id: id,
        projectId: projectId,
        recordedBy: recordedBy,
        part: part,
        startMs: startMs,
      );
}

/// One row of 0159's `loop_rounds`, with its seats.
class _Round {
  _Round({
    required this.id,
    required this.projectId,
    required this.startMs,
    required this.endMs,
    required this.startedBy,
    required this.startedAt,
    required this.turnSince,
    required this.seats,
  });

  final String id;
  final String projectId;
  final int startMs;
  final int endMs;
  final String startedBy;
  final DateTime startedAt;
  final List<_Seat> seats;

  /// When the turn last moved. Read by the quiet pass and nothing else.
  DateTime turnSince;
  bool ended = false;
}

/// One row of 0159's `loop_seats`. [state] is the column as stored:
/// 'waiting', 'played' or 'out'.
class _Seat {
  _Seat({required this.userId, required this.place});

  final String userId;
  int place;
  String state = 'waiting';
  String? layerId;
}

/// One row of 0155's `take_consents`. [agreed] null is waiting.
class _Consent {
  const _Consent({required this.userId, required this.agreed});

  final String userId;
  final bool? agreed;
}
