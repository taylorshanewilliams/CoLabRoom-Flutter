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

  /// Removes one for good. The RLS policy for this has existed since 0018;
  /// nothing ever called it, so an inbox could only ever grow.
  Future<void> deleteNotification(AppNotification notification);

  /// Clears everything already read, leaving anything still waiting.
  Future<void> deleteReadNotifications();

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

  /// Removes a song only if nothing was ever put in it.
  ///
  /// For the record button, which creates the song before the recorder opens
  /// — so a bumped button leaves an empty one behind. Returns whether
  /// anything was removed; a song with a take, a word or a recording in it is
  /// always left alone.
  Future<bool> discardIfUntouched(String projectId);

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

  /// One song, with its lyrics — rather than the whole library.
  ///
  /// [loadRooms] fetches every room, every song, every lyric line and every
  /// file in one query. That is the right shape for opening the app and the
  /// wrong shape for typing: a single edited line was re-downloading every
  /// word of every song in every Room, twice — once because the mutation
  /// asked for a reload and once because the realtime channel saw the write
  /// and asked for another.
  ///
  /// Null when the song is gone or no longer visible to this person, which
  /// the caller should treat as "remove it" rather than as an error.
  Future<SongProject?> loadProject(String projectId);

  /// Ids of songs somebody *else* changed, for a listener that wants to
  /// refresh one song rather than everything.
  ///
  /// Separate from [changes] because the two carry different news. [changes]
  /// means "something in the library moved, re-read it"; this means "this one
  /// song's lyrics moved, and nothing else did".
  Stream<String> get projectChanges;

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

  /// Puts one piece of news away, for this person only.
  Future<void> dismissActivity(String eventId);

  /// Brings it back. A feed you can clear without recourse is one people
  /// stop trusting.
  Future<void> restoreActivity(String eventId);

  /// Who is signed in, for the handful of places the UI has to tell this
  /// person's own row apart from everybody else's — whether *you* have nodded,
  /// not merely whether somebody has.
  String get currentUserId;

  /// The work somebody has linked from elsewhere.
  Future<List<ShowcaseLink>> loadShowcase(String profileId);

  /// Adds a link to your own showcase. The server decides the platform from
  /// the host and refuses anything not on the allowlist.
  Future<void> addShowcaseLink({required String url, String title});

  Future<void> removeShowcaseLink(String linkId);

  /// The city you and [profileId] turn out to share, if you have made
  /// something together and they allow it. Null otherwise, which is the
  /// normal case and not an error.
  Future<String?> sharedCityWith(String profileId);

  /// Takes somebody out of a room, and out of every song inside it.
  ///
  /// The owner only, or you removing yourself. The owner cannot be removed at
  /// all — a room with nobody who can invite, rename or delete it is one
  /// whose rows are still there and nobody can reach.
  Future<void> removeRoomMember({
    required String roomId,
    required String userId,
  });

  /// Leaving one yourself. Nobody needs permission to stop being in a band.
  Future<void> leaveRoom(String roomId);

  /// Rooms you own that [profileId] could be invited into.
  Future<List<InvitableRoom>> roomsICanInviteTo(String profileId);

  /// Invites somebody you met into a room. Grants nothing until they say
  /// yes, exactly like an ask.
  Future<void> inviteMusicianToRoom({
    required String roomId,
    required String profileId,
    String note,
  });

  /// Room invitations aimed at you by name.
  Future<List<RoomInviteForMe>> roomInvitesForMe();

  Future<void> answerRoomInvite(String inviteId, {required bool accept});

  /// Songs on the Open Mic, newest first.
  ///
  /// Only songs that are *asking* for something, unless
  /// [includeNotAsking]. The Open Mic is a noticeboard: a song somebody put
  /// up but is not asking about is showcase, and showcase lives on a profile.
  Future<List<OpenMicSong>> openMicSongs({
    String? part,
    int limit,
    bool includeNotAsking,
  });

  /// Songs on the Open Mic that [profileId] made or played on.
  ///
  /// Owned or played on, deliberately: a bass player who has never
  /// written a song is exactly who Open Mic is for, and an owner-only
  /// definition would leave their profile empty while they played on
  /// twenty records.
  Future<List<OpenMicSong>> songsBy(String profileId);

  /// A listening session, ordered for whoever is asking.
  ///
  /// Not a page and not a cursor. Most of it is the songs closest to this
  /// person — asking for a part they play, by somebody they have played
  /// with, in their city — and every fourth one is deliberately outside all
  /// of that, because a feed that only returns your own kind is a room with
  /// one conversation in it. Each track says why it is here.
  ///
  /// A cursor was removed rather than never added: it walked backwards
  /// through time, which only works while the order *is* time.
  Future<List<FeedTrack>> openMicFeed({int limit, String? part});

  /// One of them, as somebody outside the room sees it.
  Future<OpenMicSong?> openMicSong(String projectId);

  /// Offers a song to everybody, or takes it back. Owner only, and only ever
  /// the takes the room has already heard.
  /// Who can hear [projectId], as one answer.
  ///
  /// Derived from the room, the per-song invitations and the Open Mic flag
  /// together — the three things that decide a song's audience and were
  /// never shown anywhere at the same time.
  Future<SongAudience?> songAudience(String projectId);

  Future<void> putOnOpenMic(String projectId);
  Future<void> takeOffOpenMic(String projectId);

  /// The room a recording lands in when nobody has said where it goes.
  ///
  /// Created on first use rather than at signup, so an account that never
  /// records never grows an empty room it has to look at.
  Future<MusicRoom> ideasRoom();

  /// Starts a song for a recording that has no home yet.
  ///
  /// The whole of what the Studio's "Use in a song" button used to do, moved
  /// to the front. A recording *is* a song from the moment it exists — moving
  /// it somewhere else afterwards means picking a room, never converting
  /// one kind of object into another.
  Future<SongProject> startIdea({String? title});

  /// Stops somebody finding you, asking you, or inviting you to anything.
  ///
  /// Symmetric in effect and quiet in fact: neither of you appears to the
  /// other afterwards, and nobody is told. It prevents new contact rather
  /// than tearing up a band you are both already in — wanting out of a
  /// room is [leaveRoom], which is a different thing.
  Future<void> blockUser(String profileId);

  Future<void> unblockUser(String profileId);

  /// Who you have blocked. You cannot see who has blocked you.
  Future<List<BlockedPerson>> peopleIBlocked();

  /// Says that something should not be here.
  ///
  /// Write-only from the app's side: the person reported never sees it, and
  /// neither does anybody else.
  Future<void> reportContent({
    required String kind,
    required String reason,
    String detail,
    String? profileId,
    String? projectId,
    String? layerId,
    String? linkId,
    String? roomId,
  });

  /// Songs you are on and could offer to [profileId], newest first.
  Future<List<OfferableSong>> songsICanOffer(String profileId);

  /// Asks one particular musician to play on one particular song.
  ///
  /// Grants them nothing. It is a message; accepting is what gives access,
  /// and only they can do that.
  Future<void> askMusician({
    required String projectId,
    required String profileId,
    String? part,
    String note,
  });

  /// Open asks aimed at you by name.
  Future<List<AskForMe>> asksForMe();

  /// Says yes or no to one. Yes puts you on that song — and only that song.
  Future<void> answerAsk(String askId, {required bool accept});

  /// One musician, including yourself.
  ///
  /// Null when there is nobody you are allowed to see at that id, which is
  /// not an error — somebody who has not opted in and shares no room with you
  /// simply has no page as far as you are concerned.
  /// What the app has worked out about you and could write down.
  ///
  /// Only ever about yourself, and only ever from things it can count:
  /// shared takes with a part on them, songs on the Open Mic, a field left
  /// empty. Nothing is guessed about taste or ability, because nothing here
  /// supports guessing either.
  Future<List<Noticed>> thingsWeNoticed();

  /// Adds one part to what you play, leaving the rest of the profile alone.
  Future<void> claimPart(String part);

  Future<Musician?> loadMusician(String profileId);

  /// Turning yourself on or off in Open Mic, and what strangers may know.
  ///
  /// A null [city] leaves the existing one alone; an empty one removes it.
  Future<void> setOpenMicPresence({
    required bool discoverable,
    String? city,
    String? locationVisibility,
    List<String>? plays,
    List<String>? soundsLike,
  });

  /// People who play [part], optionally in [city].
  ///
  /// A coarse filter on purpose. An instrument narrows thousands to dozens
  /// and no filter can do the rest — "guitarist" does not distinguish a metal
  /// player from a jazz one, and that judgement is made by listening.
  /// People who do any of [parts], the ones doing most of them first.
  ///
  /// Ranked rather than narrowed. Requiring all of a list turns three ticked
  /// boxes into an empty screen, and requiring any of it throws away what was
  /// asked — the person who does all three is the answer and would land
  /// wherever the shuffle put them.
  Future<List<Musician>> findMusicians({
    List<String>? parts,
    String? city,
    int limit,
    String? soundsLike,
  });

  /// Everything that has happened to this song, oldest first.
  ///
  /// Visible only to somebody the song is already visible to — the function
  /// behind this runs under the caller's own permissions, because a record of
  /// who wrote what must not become a way to read the history of a song you
  /// are not part of.
  Future<List<ProvenanceEvent>> loadProvenance(String projectId);

  /// Everything [projectId] is currently asking for, newest first. Closed
  /// asks are left out — a song only asks for what it still wants.
  Future<List<SongAsk>> loadAsks(String projectId);

  /// Ask for something on this song. A null [part] is an open ask.
  ///
  /// Anybody in the room can ask, not only whoever uploaded the song: a
  /// bandmate saying "this wants drums" is a normal thing to happen in a band.
  Future<SongAsk> askFor({
    required String projectId,
    String? part,
    String note = '',
  });

  /// Stop asking, because somebody answered or because it stopped mattering.
  Future<void> closeAsk(SongAsk ask);

  /// The ids of people who have said they heard this song.
  ///
  /// Nothing like [markProjectSeen], which records that somebody *opened* a
  /// song so a badge can be cleared and is private to them by design. This is
  /// a thing a person chooses to say, and the room is meant to see it.
  Future<List<String>> loadNods(String projectId);

  /// Say you heard it, or take it back.
  Future<void> setNod({required String projectId, required bool heard});

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

  /// Records a question somebody could not find the answer to.
  ///
  /// Sent whether or not the app had an answer, because the interesting case
  /// is a question that *was* answered and asked anyway — that means the
  /// answer is wrong, and nothing else in the app can see that happening.
  Future<void> askForHelp({
    required String question,
    String? matchedAnswer,
    String? route,
  });

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
