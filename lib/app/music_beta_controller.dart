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
  bool _loading = false;
  String? _error;
  StreamSubscription<void>? _changesSubscription;
  Timer? _reloadDebounce;

  List<MusicRoom> get rooms => List<MusicRoom>.unmodifiable(_rooms);
  List<BetaInvite> get invites => List<BetaInvite>.unmodifiable(_invites);
  List<Setlist> get setlists => List<Setlist>.unmodifiable(_setlists);
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

  Future<SongProject> createSong(MusicRoom room, String title) async {
    final result = await repository.createSong(room: room, title: title);
    await load();
    return result;
  }

  Future<void> renameSong(SongProject project, String title) async {
    await repository.renameSong(project: project, title: title);
    await load();
  }

  Future<void> deleteSong(SongProject project) async {
    await repository.deleteSong(project);
    await load();
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

  Future<String> createInvite(
    MusicRoom room,
    String email, {
    RoomRole role = RoomRole.editor,
  }) {
    return repository.createInvite(room: room, email: email, role: role);
  }

  Future<void> acceptInvite({String? code, BetaInvite? invite}) async {
    await repository.acceptInvite(code: code, invite: invite);
    await load();
  }

  Future<void> declineInvite(BetaInvite invite) async {
    await repository.declineInvite(invite);
    await load();
  }

  Future<void> submitFeedback(FeedbackDraft feedback) {
    return repository.submitFeedback(feedback);
  }

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    _changesSubscription?.cancel();
    repository.dispose();
    super.dispose();
  }
}
