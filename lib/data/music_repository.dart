import 'dart:typed_data';

import '../domain/music_models.dart';

abstract interface class MusicRepository {
  Stream<void> get changes;

  Future<List<MusicRoom>> loadRooms();

  Future<List<BetaInvite>> loadInvites();

  Future<List<Setlist>> loadSetlists();

  Future<MusicRoom> createRoom({required String name, required String icon});

  Future<MusicRoom> renameRoom({required MusicRoom room, required String name});

  /// Permanently deletes [room] and everything in it (members, projects,
  /// contributions, files) via cascading foreign keys.
  Future<void> deleteRoom(MusicRoom room);

  /// Persists a new manual display order for the given rooms (the order of
  /// [orderedRooms] becomes the new order).
  Future<void> reorderRooms(List<MusicRoom> orderedRooms);

  Future<SongProject> createSong({
    required MusicRoom room,
    required String title,
  });

  Future<SongProject> renameSong({
    required SongProject project,
    required String title,
  });

  Future<void> deleteSong(SongProject project);

  Future<Contribution> addContribution({
    required SongProject project,
    required String body,
    int colorValue = 0xFFFF8A4C,
    double? position,
  });

  Future<Contribution> updateContribution({
    required Contribution contribution,
    required String body,
  });

  Future<void> deleteContribution(Contribution contribution);

  Future<List<Contribution>> importContributions({
    required SongProject project,
    required List<ContributionDraft> drafts,
    int colorValue = 0xFFFF8A4C,
  });

  Future<VoiceNote> attachVoiceNote({
    required SongProject project,
    required Contribution contribution,
    required Uint8List bytes,
    required int durationMs,
  });

  Future<Uint8List> loadVoiceNote(VoiceNote note);

  Future<void> deleteVoiceNote(VoiceNote note);

  Future<Setlist> createSetlist(String name);

  Future<void> addProjectsToSetlist(Setlist setlist, Iterable<String> projectIds);

  Future<void> removeProjectFromSetlist(Setlist setlist, String projectId);

  /// Persists a new manual song order within [setlist] ([orderedProjectIds]
  /// must contain the same set of ids currently in the setlist).
  Future<void> reorderSetlistProjects(Setlist setlist, List<String> orderedProjectIds);

  Future<void> moveProjects(Iterable<SongProject> projects, MusicRoom targetRoom);

  Future<String> createInvite({
    required MusicRoom room,
    required String email,
    RoomRole role = RoomRole.editor,
  });

  Future<void> acceptInvite({String? code, BetaInvite? invite});

  /// Sets the caller's own display color within [roomId] to [colorValue].
  /// [colorValue] must be one of [AppColors.memberPalette] and must not
  /// already be in use by another member of that room — implementations
  /// should throw if either is violated.
  Future<void> setMemberColor({required String roomId, required int colorValue});

  Future<void> declineInvite(BetaInvite invite);

  Future<void> submitFeedback(FeedbackDraft feedback);

  void dispose();
}
