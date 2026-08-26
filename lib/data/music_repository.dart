import 'dart:typed_data';

import '../domain/activity.dart';
import '../domain/music_models.dart';

abstract interface class MusicRepository {
  Stream<void> get changes;

  Future<List<MusicRoom>> loadRooms();

  Future<List<BetaInvite>> loadInvites();

  Future<List<AppNotification>> loadNotifications();

  Future<NotificationPreferences> loadNotificationPreferences();

  Future<void> setNotificationPreferences(NotificationPreferences preferences);

  Future<void> markNotificationRead(AppNotification notification);

  Future<void> markAllNotificationsRead();

  Future<List<Setlist>> loadSetlists();

  Future<MusicRoom> createRoom({required String name, required String icon});

  Future<MusicRoom> renameRoom({required MusicRoom room, required String name});

  /// Permanently deletes [room] and everything in it (members, projects,
  /// contributions, files) via cascading foreign keys.
  Future<void> deleteRoom(MusicRoom room);

  /// Persists a new manual display order for the given rooms (the order of
  /// [orderedRooms] becomes the new order).
  Future<void> reorderRooms(List<MusicRoom> orderedRooms);

  /// Uploads [bytes] as [room]'s tile logo, replacing any existing one.
  Future<MusicRoom> setRoomLogo({required MusicRoom room, required Uint8List bytes});

  /// Removes [room]'s custom tile logo, reverting to its default icon.
  Future<MusicRoom> clearRoomLogo(MusicRoom room);

  Future<Uint8List> loadRoomLogo(MusicRoom room);

  Future<SongProject> createSong({
    required MusicRoom room,
    required String title,
  });

  Future<SongProject> renameSong({
    required SongProject project,
    required String title,
  });

  Future<SongProject> setSongStatus({
    required SongProject project,
    required SongStatus status,
  });

  Future<void> deleteSong(SongProject project);

  /// Persists a new manual song order within [room] ([orderedProjectIds]
  /// must contain the same set of project ids currently in the Room).
  Future<void> reorderRoomProjects(MusicRoom room, List<String> orderedProjectIds);

  /// Uploads [bytes] as [project]'s tile cover image, replacing any existing
  /// one.
  Future<SongProject> setProjectCover({required SongProject project, required Uint8List bytes});

  /// Removes [project]'s custom cover image, reverting to its default icon.
  Future<SongProject> clearProjectCover(SongProject project);

  Future<Uint8List> loadProjectCover(SongProject project);

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

  /// How many takes have landed on each song since this person last listened,
  /// keyed by project id. Songs with nothing new are absent rather than zero.
  Future<Map<String, int>> loadUnheardTakeCounts();

  /// Records that this person has now heard what is on [projectId].
  Future<void> markProjectSeen(String projectId);

  /// What other people have done lately, across every song at once.
  ///
  /// Excludes this person's own actions: a feed that reports your own typing
  /// back to you teaches everyone to stop reading it.
  Future<List<ActivityItem>> loadActivity({int limit});

  Future<InviteResult> createInvite({
    required MusicRoom room,
    required String email,
    RoomRole role = RoomRole.editor,
  });

  /// Like [createInvite], but the resulting invite grants access to just
  /// [project] instead of its whole Room.
  Future<InviteResult> createProjectInvite({
    required SongProject project,
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

  /// The signed-in user's profile picture, as a storage path rather than
  /// bytes — see [loadAvatar]. Null when they haven't set one.
  Future<String?> loadAvatarPath();

  /// Replaces the signed-in user's profile picture, returning its new path.
  Future<String> setAvatar(Uint8List bytes);

  Future<void> clearAvatar();

  Future<Uint8List> loadAvatar(String path);

  /// Closes the live-updates connection while the app is in the background,
  /// and opens it again on return. A socket held open through a night of
  /// dozing is a phone that never idles, watching for changes nobody is
  /// there to see.
  void pauseLiveUpdates();
  void resumeLiveUpdates();

  void dispose();
}
