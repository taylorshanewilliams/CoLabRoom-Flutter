import 'dart:typed_data';

import '../domain/activity.dart';
import '../domain/calls.dart';
import '../domain/lesson_link.dart';
import '../domain/moment_note.dart';
import '../domain/music_models.dart';
import '../domain/practice_mark.dart';
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
    _replaceSetlist(setlist.copyWith(
      projectIds: merged.toList(growable: false),
      updatedAt: DateTime.now(),
    ));
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
  LessonLink? _lessonLink;
  final Map<String, ({String title, String teacherName})> _lessonsOffered =
      <String, ({String title, String teacherName})>{};
  final Map<String, String> _lessonRooms = <String, String>{};

  /// Somebody else's lesson link this repository will open. There is only
  /// one person in an in-memory world, so the teacher on the other end of a
  /// lesson has to be put there by hand, for tests and previews.
  void offerLesson({required String code, required String title, required String teacherName}) {
    _lessonsOffered[code] = (title: title, teacherName: teacherName);
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

  @override
  String get currentUserId => 'preview-user';

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
        ownerName: 'Dev Okonjo',
        storagePath: 'preview/kitchen.m4a',
        putUpAt: now.subtract(const Duration(days: 2)),
        askingFor: const <String>['harmony'],
        musicalKey: 'D',
        durationMs: 142000,
        reason: 'Nothing like what you play',
      ),
    ];
    return <FeedTrack>[
      for (final track in all)
        if (part == null || track.askingFor.contains(part)) track,
    ];
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
        );
      }
    }
    return null;
  }

  @override
  Future<void> putOnOpenMic(String projectId) async {
    _onOpenMic.add(projectId);
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
        // else's song comes off the Open Mic when it is named as one.
        if (origin == SongOrigin.cover) _onOpenMic.remove(projectId);
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
        if (!ask.closed)
          ask.copyWith(replyCount: _replies[ask.id]?.length ?? 0),
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  @override
  Future<List<AskReply>> loadAskReplies(String askId) async =>
      List<AskReply>.unmodifiable(_replies[askId] ?? const <AskReply>[]);

  @override
  Future<AskReply> replyToAsk(
      {required String askId, required String body}) async {
    final reply = AskReply(
      id: 'reply-${DateTime.now().microsecondsSinceEpoch}',
      askId: askId,
      authorId: currentUserId,
      authorName: 'You',
      body: body.trim(),
      createdAt: DateTime.now(),
    );
    _replies.putIfAbsent(askId, () => <AskReply>[]).add(reply);
    return reply;
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
  Future<LessonLink?> myLessonLink() async => _lessonLink;

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
  Future<LessonLink> openLessonLink(String title) async {
    _lessonsNeedAnAdult();
    final cleaned = title.trim().isEmpty ? 'Lessons' : title.trim();
    final existing = _lessonLink;
    final link = LessonLink(
      id: existing?.id ?? _id('lesson'),
      code: existing?.code ?? 'a1b2c3d4e5f6',
      title: cleaned.length > 60 ? cleaned.substring(0, 60) : cleaned,
      createdAt: existing?.createdAt ?? DateTime.now(),
      students: existing?.students ?? 0,
    );
    _lessonLink = link;
    return link;
  }

  @override
  Future<void> closeLessonLink() async {
    _lessonLink = null;
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
    if (_lessonLink?.code == cleaned) {
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
    final already = _lessonRooms[cleaned];
    if (already != null && _rooms.any((room) => room.id == already)) return already;
    final now = DateTime.now();
    final room = MusicRoom(
      id: _id('room'),
      accountId: 'teacher-${offered.teacherName.toLowerCase()}',
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

  @override
  Future<void> deleteMomentNote(MomentNote note) async {
    // Yours only, the way the function behind this is (0141).
    _momentNotes.removeWhere(
      (kept) => kept.id == note.id && kept.authorId == currentUserId,
    );
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
  }) async {
    final cleaned = part?.trim();
    final ask = SongAsk(
      id: 'ask-${DateTime.now().microsecondsSinceEpoch}',
      projectId: projectId,
      askedBy: 'preview-user',
      createdAt: DateTime.now(),
      part: cleaned == null || cleaned.isEmpty ? null : cleaned,
      note: note.trim(),
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
