import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../data/music_repository.dart';
import '../domain/music_models.dart';

class MusicBetaController extends ChangeNotifier with WidgetsBindingObserver {
  MusicBetaController(this.repository) {
    _changesSubscription = repository.changes.listen((_) {
      _reloadDebounce?.cancel();
      _reloadDebounce = Timer(const Duration(milliseconds: 300), load);
    });
    // A bandmate typing refreshes the song they typed in, not the library.
    // Coalesced per song, so somebody pasting a whole lyric sheet costs one
    // read of one song rather than one read of everything per line.
    _projectChangesSubscription = repository.projectChanges.listen((projectId) {
      _projectDebounce[projectId]?.cancel();
      _projectDebounce[projectId] = Timer(
        const Duration(milliseconds: 400),
        () {
          _projectDebounce.remove(projectId);
          unawaited(refreshProject(projectId));
        },
      );
    });
    WidgetsBinding.instance.addObserver(this);
  }

  /// Live updates follow the app in and out of the foreground.
  ///
  /// Watching for other people's changes earns a held-open socket while
  /// somebody is looking at the screen, and earns nothing at all while the
  /// phone is in a pocket — where that same socket goes on heartbeating, and
  /// reconnecting every time the radio flickers. That is what "CoLabRoom
  /// keeps waking up frequently" was made of.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        repository.resumeLiveUpdates();
        // Reload rather than replay: whatever happened while the socket was
        // shut is simply read back now.
        unawaited(load());
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        repository.pauseLiveUpdates();
      case AppLifecycleState.inactive:
        // Transient — the notification shade, an incoming call, the app
        // switcher. Tearing the socket down and rebuilding it for those would
        // cost more than it saves.
        break;
    }
  }

  StreamSubscription<String>? _projectChangesSubscription;
  final Map<String, Timer> _projectDebounce = <String, Timer>{};

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

  Map<String, int> _unheardTakes = const <String, int>{};

  /// Takes added by somebody else since this person last opened [projectId].
  ///
  /// Zero for a song with nothing new, which is the overwhelmingly common
  /// case and the reason the map holds only songs that have something.
  int unheardTakesFor(String projectId) => _unheardTakes[projectId] ?? 0;

  /// Everything new across every band, for the Home surface.
  int get unheardTakesTotal =>
      _unheardTakes.values.fold(0, (sum, count) => sum + count);

  /// Called when somebody opens a song's takes: the badge clears immediately
  /// rather than waiting for the next load, because the person is looking at
  /// the thing it refers to.
  Future<void> markProjectSeen(String projectId) async {
    if (_unheardTakes.containsKey(projectId)) {
      final next = Map<String, int>.from(_unheardTakes)..remove(projectId);
      _unheardTakes = next;
      notifyListeners();
    }
    try {
      await repository.markProjectSeen(projectId);
    } catch (_) {
      // Recording that somebody listened must never interrupt listening. The
      // next load re-reads the truth from the server.
    }
  }
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
      // Best-effort and last. A badge is the least important thing on this
      // screen: failing to fetch it must never cost somebody their songs,
      // which is what putting it in the main try would do.
      try {
        _unheardTakes = await repository.loadUnheardTakeCounts();
      } catch (_) {
        // Left as it was. A stale count is better than a list that failed.
      }
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

  String? _avatarPath;

  /// The signed-in user's profile picture, or null while it's still being
  /// fetched — or if they haven't set one. Same shape as [roomLogoBytes]:
  /// asking triggers the fetch and [notifyListeners] fires when it lands.
  Uint8List? get avatarBytes => _avatarPath == null ? null : _imageCache[_avatarPath];

  bool get hasAvatar => _avatarPath != null;

  Future<void> loadAvatar() async {
    final path = await repository.loadAvatarPath();
    if (path == _avatarPath && (path == null || _imageCache.containsKey(path))) return;
    _avatarPath = path;
    if (path != null && !_imageCache.containsKey(path)) {
      try {
        _imageCache[path] = await repository.loadAvatar(path);
      } catch (_) {
        // A picture that won't download is a missing picture, not an error
        // worth showing on the account screen.
        _avatarPath = null;
      }
    }
    notifyListeners();
  }

  Future<void> setAvatar(Uint8List bytes) async {
    final path = await repository.setAvatar(bytes);
    if (_avatarPath != null) _imageCache.remove(_avatarPath);
    _avatarPath = path;
    _imageCache[path] = bytes;
    notifyListeners();
  }

  Future<void> clearAvatar() async {
    await repository.clearAvatar();
    if (_avatarPath != null) _imageCache.remove(_avatarPath);
    _avatarPath = null;
    notifyListeners();
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

  /// Re-reads one song and puts it back where it was.
  ///
  /// The alternative — and what this replaces — is [load], which fetches
  /// every Room, every song and every lyric line in the account. Typing a
  /// line was doing that twice: once here and once again when the realtime
  /// channel saw the same write land.
  ///
  /// A song that comes back null has been deleted or is no longer visible, so
  /// it is dropped from the Room rather than left as a tile that opens onto
  /// nothing.
  Future<void> refreshProject(String projectId) async {
    final updated = await repository.loadProject(projectId);
    var changed = false;
    final rooms = <MusicRoom>[];
    for (final room in _rooms) {
      final index =
          room.projects.indexWhere((project) => project.id == projectId);
      if (index < 0) {
        rooms.add(room);
        continue;
      }
      final projects = List<SongProject>.from(room.projects);
      if (updated == null) {
        projects.removeAt(index);
      } else if (updated.roomId != room.id) {
        // It moved. Taking it out here is right; the Room it went to is
        // reloaded by the move itself.
        projects.removeAt(index);
      } else {
        projects[index] = updated;
      }
      rooms.add(room.copyWith(projects: projects));
      changed = true;
    }
    if (!changed) {
      // A song this device has not seen before — an invitation accepted
      // elsewhere, a song added to a Room while the app was open. Nothing to
      // splice into, so read the library properly this once.
      await load();
      return;
    }
    _rooms = rooms;
    notifyListeners();
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
    await refreshProject(project.id);
  }

  Future<void> updateContribution(Contribution contribution, String body) async {
    await repository.updateContribution(contribution: contribution, body: body);
    await refreshProject(contribution.projectId);
  }

  Future<void> deleteContribution(Contribution contribution) async {
    await repository.deleteContribution(contribution);
    await refreshProject(contribution.projectId);
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
    await refreshProject(project.id);
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
    WidgetsBinding.instance.removeObserver(this);
    _reloadDebounce?.cancel();
    for (final timer in _projectDebounce.values) {
      timer.cancel();
    }
    _projectDebounce.clear();
    _changesSubscription?.cancel();
    _projectChangesSubscription?.cancel();
    repository.dispose();
    super.dispose();
  }
}
