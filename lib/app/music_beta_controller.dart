import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/music_repository.dart';
import '../domain/music_models.dart';

class MusicBetaController extends ChangeNotifier {
  MusicBetaController(this.repository) {
    _changesSubscription = repository.changes.listen((_) {
      _reloadDebounce?.cancel();
      _reloadDebounce = Timer(const Duration(milliseconds: 300), load);
    });
  }

  final MusicRepository repository;

  List<MusicRoom> _rooms = const <MusicRoom>[];
  List<BetaInvite> _invites = const <BetaInvite>[];
  List<Setlist> _setlists = const <Setlist>[];
  List<AppNotification> _notifications = const <AppNotification>[];
  NotificationPreferences _notificationPreferences = const NotificationPreferences();
  bool _loading = false;
  String? _error;
  StreamSubscription<void>? _changesSubscription;
  Timer? _reloadDebounce;

  // Room logos / song covers are stored privately and fetched by storage
  // path on demand, then kept here so every tile rebuild doesn't re-hit
  // storage — cleared for a path once its Room/Song's logo/cover changes.
  final Map<String, Uint8List> _imageCache = <String, Uint8List>{};
  final Set<String> _imageFetchesInFlight = <String>{};

  List<MusicRoom> get rooms => List<MusicRoom>.unmodifiable(_rooms);
  List<BetaInvite> get invites => List<BetaInvite>.unmodifiable(_invites);
  List<Setlist> get setlists => List<Setlist>.unmodifiable(_setlists);
  List<AppNotification> get notifications => List<AppNotification>.unmodifiable(_notifications);
  NotificationPreferences get notificationPreferences => _notificationPreferences;
  int get unreadNotificationCount => _notifications.where((n) => !n.isRead).length;
  Iterable<SongProject> get projects => _rooms.expand((room) => room.projects);
  bool get loading => _loading;
  String? get error => _error;

  Future<void> load() async {
    if (_loading) return;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _rooms = await repository.loadRooms();
      _invites = await repository.loadInvites();
      _setlists = await repository.loadSetlists();
      _notifications = await repository.loadNotifications();
      _notificationPreferences = await repository.loadNotificationPreferences();
    } catch (error) {
      _error = error.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  MusicRoom? roomById(String id) {
    for (final room in _rooms) {
      if (room.id == id) return room;
    }
    return null;
  }

  Setlist? setlistById(String id) {
    for (final setlist in _setlists) {
      if (setlist.id == id) return setlist;
    }
    return null;
  }

  SongProject? projectById(String id) {
    for (final project in projects) {
      if (project.id == id) return project;
    }
    return null;
  }

  MusicRoom? roomForProject(String projectId) {
    for (final room in _rooms) {
      if (room.projects.any((project) => project.id == projectId)) return room;
    }
    return null;
  }

  Future<MusicRoom> createRoom({required String name, required String icon}) async {
    final result = await repository.createRoom(name: name, icon: icon);
    await load();
    return result;
  }

  Future<void> renameRoom(MusicRoom room, String name) async {
    await repository.renameRoom(room: room, name: name);
    await load();
  }

  Future<void> deleteRoom(MusicRoom room) async {
    await repository.deleteRoom(room);
    await load();
  }

  Future<void> reorderRooms(List<MusicRoom> orderedRooms) async {
    // Update local state immediately so the drag feels instant; `load()`
    // afterward reconciles with whatever the backend actually persisted.
    _rooms = orderedRooms;
    notifyListeners();
    try {
      await repository.reorderRooms(orderedRooms);
    } finally {
      await load();
    }
  }

  /// Bytes for [room]'s custom logo, or null if it has none or they haven't
  /// been fetched yet (a fetch starts automatically and [notifyListeners]
  /// fires once it lands).
  Uint8List? roomLogoBytes(MusicRoom room) => _imageBytes(room.logoPath);

  Future<void> setRoomLogo(MusicRoom room, Uint8List bytes) async {
    final updated = await repository.setRoomLogo(room: room, bytes: bytes);
    _imageCache[updated.logoPath!] = bytes;
    await load();
  }

  Future<void> clearRoomLogo(MusicRoom room) async {
    if (room.logoPath != null) _imageCache.remove(room.logoPath);
    await repository.clearRoomLogo(room);
    await load();
  }

  /// Bytes for [project]'s custom cover image, or null if it has none or
  /// they haven't been fetched yet — see [roomLogoBytes].
  Uint8List? projectCoverBytes(SongProject project) => _imageBytes(project.coverImagePath);

  Future<void> setProjectCover(SongProject project, Uint8List bytes) async {
    final updated = await repository.setProjectCover(project: project, bytes: bytes);
    _imageCache[updated.coverImagePath!] = bytes;
    await load();
  }

  Future<void> clearProjectCover(SongProject project) async {
    if (project.coverImagePath != null) _imageCache.remove(project.coverImagePath);
    await repository.clearProjectCover(project);
    await load();
  }

  Uint8List? _imageBytes(String? path) {
    if (path == null) return null;
    final cached = _imageCache[path];
    if (cached != null) return cached;
    if (_imageFetchesInFlight.add(path)) {
      unawaited(_fetchImage(path));
    }
    return null;
  }

  Future<void> _fetchImage(String path) async {
    try {
      MusicRoom? room;
      for (final candidate in _rooms) {
        if (candidate.logoPath == path) {
          room = candidate;
          break;
        }
      }
      Uint8List bytes;
      if (room != null) {
        bytes = await repository.loadRoomLogo(room);
      } else {
        SongProject? project;
        for (final candidate in projects) {
          if (candidate.coverImagePath == path) {
            project = candidate;
            break;
          }
        }
        if (project == null) return;
        bytes = await repository.loadProjectCover(project);
      }
      _imageCache[path] = bytes;
      notifyListeners();
    } catch (_) {
      // Leave the tile on its default icon if the fetch fails.
    } finally {
      _imageFetchesInFlight.remove(path);
    }
  }

  Future<SongProject> createSong(MusicRoom room, String title) async {
    final result = await repository.createSong(room: room, title: title);
    await load();
    return result;
  }

  Future<void> renameSong(SongProject project, String title) async {
    await repository.renameSong(project: project, title: title);
    await load();
  }

  Future<void> setSongStatus(SongProject project, SongStatus status) async {
    await repository.setSongStatus(project: project, status: status);
    await load();
  }

  Future<void> deleteSong(SongProject project) async {
    await repository.deleteSong(project);
    await load();
  }

  Future<void> reorderRoomProjects(MusicRoom room, List<SongProject> orderedProjects) async {
    // Update local state immediately so the drag feels instant; `load()`
    // afterward reconciles with whatever the backend actually persisted.
    final index = _rooms.indexWhere((candidate) => candidate.id == room.id);
    if (index != -1) {
      _rooms[index] = _rooms[index].copyWith(projects: orderedProjects);
      notifyListeners();
    }
    try {
      await repository.reorderRoomProjects(room, orderedProjects.map((p) => p.id).toList(growable: false));
    } finally {
      await load();
    }
  }

  Future<void> addContribution(
    SongProject project,
    String body, {
    int colorValue = 0xFFFF8A4C,
    double? position,
  }) async {
    await repository.addContribution(
      project: project,
      body: body,
      colorValue: colorValue,
      position: position,
    );
    await load();
  }

  Future<void> updateContribution(Contribution contribution, String body) async {
    await repository.updateContribution(contribution: contribution, body: body);
    await load();
  }

  Future<void> deleteContribution(Contribution contribution) async {
    await repository.deleteContribution(contribution);
    await load();
  }

  Future<int> importContributions(
    SongProject project,
    List<ContributionDraft> drafts, {
    int colorValue = 0xFFFF8A4C,
  }) async {
    final imported = await repository.importContributions(
      project: project,
      drafts: drafts,
      colorValue: colorValue,
    );
    await load();
    return imported.length;
  }

  Future<VoiceNote> attachVoiceNote(
    SongProject project,
    Contribution contribution,
    Uint8List bytes, {
    required int durationMs,
  }) async {
    final note = await repository.attachVoiceNote(
      project: project,
      contribution: contribution,
      bytes: bytes,
      durationMs: durationMs,
    );
    await load();
    return note;
  }

  Future<Uint8List> loadVoiceNote(VoiceNote note) => repository.loadVoiceNote(note);

  Future<void> deleteVoiceNote(VoiceNote note) async {
    await repository.deleteVoiceNote(note);
    await load();
  }

  Future<Setlist> createSetlist(String name) async {
    final setlist = await repository.createSetlist(name);
    await load();
    return setlist;
  }

  Future<void> addProjectsToSetlist(Setlist setlist, Iterable<String> projectIds) async {
    await repository.addProjectsToSetlist(setlist, projectIds);
    await load();
  }

  Future<void> removeProjectFromSetlist(Setlist setlist, String projectId) async {
    await repository.removeProjectFromSetlist(setlist, projectId);
    await load();
  }

  Future<void> reorderSetlistProjects(Setlist setlist, List<String> orderedProjectIds) async {
    await repository.reorderSetlistProjects(setlist, orderedProjectIds);
    await load();
  }

  Future<void> moveProjects(Iterable<SongProject> projects, MusicRoom targetRoom) async {
    await repository.moveProjects(projects, targetRoom);
    await load();
  }

  Future<InviteResult> createInvite(
    MusicRoom room,
    String email, {
    RoomRole role = RoomRole.editor,
  }) {
    return repository.createInvite(room: room, email: email, role: role);
  }

  /// Like [createInvite], but the resulting invite grants access to just
  /// [project] instead of its whole Room.
  Future<InviteResult> createProjectInvite(
    SongProject project,
    String email, {
    RoomRole role = RoomRole.editor,
  }) {
    return repository.createProjectInvite(project: project, email: email, role: role);
  }

  Future<void> acceptInvite({String? code, BetaInvite? invite}) async {
    await repository.acceptInvite(code: code, invite: invite);
    await load();
  }

  Future<void> declineInvite(BetaInvite invite) async {
    await repository.declineInvite(invite);
    await load();
  }

  Future<void> setMemberColor(MusicRoom room, int colorValue) async {
    await repository.setMemberColor(roomId: room.id, colorValue: colorValue);
    await load();
  }

  Future<void> submitFeedback(FeedbackDraft feedback) {
    return repository.submitFeedback(feedback);
  }

  Future<void> markNotificationRead(AppNotification notification) async {
    if (notification.isRead) return;
    await repository.markNotificationRead(notification);
    await load();
  }

  Future<void> markAllNotificationsRead() async {
    await repository.markAllNotificationsRead();
    await load();
  }

  Future<void> updateNotificationPreferences(NotificationPreferences preferences) async {
    await repository.setNotificationPreferences(preferences);
    await load();
  }

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    _changesSubscription?.cancel();
    repository.dispose();
    super.dispose();
  }
}
