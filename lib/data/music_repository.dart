import 'dart:typed_data';

import '../domain/activity.dart';
import '../domain/calls.dart';
import '../domain/lesson_link.dart';
import '../domain/moment_note.dart';
import '../domain/music_models.dart';
import '../domain/practice_mark.dart';
import '../domain/tonight_models.dart';

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

  /// Puts [contribution] at [position] in its song, and changes nothing else
  /// about it: not its words, its writer, its colour or its voice note.
  ///
  /// The song editor uses it when a line moves, and when there is no room
  /// left between two lines for a new one and the lines have to be spaced out
  /// again. `position` is one of the two columns room editors may update
  /// (migration 0006).
  Future<Contribution> moveContribution({
    required Contribution contribution,
    required double position,
  });

  /// Takes [line] out of its song without deleting it.
  ///
  /// The row keeps its writer, its colour, its place and its voice note, and
  /// stops being part of the song. Only its writer can find it again, through
  /// [linesYouCut], whoever cut it. This used to delete the row, and the
  /// voice note with it: one person's words disappearing at another person's
  /// hand, with nothing to show they were ever there (Every Musician, Same
  /// Song, 17 September 2026; migration 0153).
  Future<void> cutLine(Contribution line);

  /// The signed-in person's own lines that have been cut from [project],
  /// newest cut first. Nobody else's: the writer is the one person a cut line
  /// is kept for.
  Future<List<Contribution>> linesYouCut(SongProject project);

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

  /// A set's new name. Sets could be made and never renamed or thrown away
  /// (audit, 17 September 2026).
  Future<void> renameSetlist(Setlist setlist, String name);

  /// Throws a set away. The songs in it are not touched.
  Future<void> deleteSetlist(Setlist setlist);

  /// Persists a new manual song order within [setlist] ([orderedProjectIds]
  /// must contain the same set of ids currently in the setlist).
  Future<void> reorderSetlistProjects(Setlist setlist, List<String> orderedProjectIds);

  /// What [saveSetlistSong] says when the set belongs to somebody else. One
  /// sentence for both repositories, so the fake refuses the way the
  /// database does.
  static const String notYourSet =
      'Only the person whose set this is can change what it says.';

  /// What [saveSetlistSong] says when the set is theirs but the song is not
  /// in it any more: taken out on another device, or in a room they can no
  /// longer see. Told apart from [notYourSet] so the owner of a set is not
  /// told it is somebody else's (review, 18 September 2026).
  static const String songNotInSet =
      'That song is no longer in this set. Reopen the set and try again.';

  /// What the band does with one song in this set: the key, the tempo, the
  /// count-in, the form, the ending and the note (Every Musician, Same Song,
  /// 17 September 2026). A null field means "what the song says".
  ///
  /// The set's owner's to write, the way the set is. Throws with a sentence
  /// when the set is not theirs, and [ArgumentError] for a field the columns
  /// will not hold (see [SetlistSong.cleaned]).
  Future<void> saveSetlistSong(Setlist setlist, SetlistSong song);

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

  /// Who can hear [projectId], as one answer.
  ///
  /// Derived from the room, the per-song invitations and the Open Mic flag
  /// together — the three things that decide a song's audience and were
  /// never shown anywhere at the same time. Since 0155 it also carries who
  /// has been asked about their part and what they said.
  Future<SongAudience?> songAudience(String projectId);

  /// Offers a song to everybody, or takes it back. Owner only, and only ever
  /// the parts their players have said yes to.
  ///
  /// The first press asks everybody with a shared take on the song and puts
  /// nothing up; the song goes up on a press made after they have all
  /// answered (Every Musician, Same Song, 17 September 2026). Neither
  /// outcome is an error, so a caller reads [songAudience] afterwards to
  /// find out which one it was and who is still to answer.
  Future<void> putOnOpenMic(String projectId);
  Future<void> takeOffOpenMic(String projectId);

  /// The songs somebody wants to put in front of everybody with a part of
  /// yours on them, waiting on your answer. One per song.
  Future<List<PartQuestion>> partQuestionsForMe();

  /// Yes or no, for every part of yours on [projectId], now or whenever you
  /// change your mind. A no on a song that is already out takes your part
  /// off it; the song stays up without it, or comes down if nothing audible
  /// is left. Refused with a plain sentence when nobody has asked you.
  Future<void> answerForMyPart(String projectId, {required bool yes});

  /// Says whose song it is: ours, public domain, or somebody else's.
  ///
  /// Owner or editor. Marking a song as somebody else's also takes it off
  /// both public surfaces — the Open Mic and the showcase — because a song
  /// the room did not write does not go in front of strangers (Every
  /// Musician, Same Song, 17 September 2026).
  Future<void> setSongOrigin(String projectId, SongOrigin origin);

  /// Says what key the song is in, when the analysis got it wrong.
  ///
  /// Owner or editor, and shared with the room: a person's transpose and capo
  /// are theirs, but where the 1 is changes what everybody's numbers mean, so
  /// it belongs to the song (Every Musician, Same Song, 17 September 2026). A
  /// null [key] hands the song back to the detected one.
  Future<void> setSongKey(String projectId, String? key);

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
  ///
  /// [terms] says what answering means, and is settled here: the database
  /// refuses to change it once the ask has gone. [sungIn] is what they would
  /// be joining, in your words: "Sa = C#, Rupak, Hindi".
  Future<void> askMusician({
    required String projectId,
    required String profileId,
    String? part,
    String note,
    AskTerms terms,
    String sungIn,
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
  /// Has a just-uploaded picture looked at before anybody else sees it.
  ///
  /// Avatars are readable by every signed-in account, so one vile image
  /// reaches the whole app at once. Reporting catches it eventually; this
  /// catches the ordinary case before it is seen.
  ///
  /// Never throws. A moderation call that fails must not stop somebody
  /// having a profile picture — the report path still exists.
  Future<void> checkPicture({
    required String bucket,
    required String path,
    required String kind,
    required String subject,
  });

  /// A room, a first song and an invitation, in one call.
  ///
  /// They are invited rather than added: the room is yours until they accept,
  /// the same as every other door in this app. Returns the room and the song
  /// to open.
  Future<({String roomId, String projectId})> startSomethingWith(
    String profileId, {
    String note,
  });

  /// Somebody listened to [projectId] for long enough to mean it.
  ///
  /// Counted once per person per day, and never logged with a time — the
  /// owner is told a number and can never be told an identity.
  Future<void> recordPlay(String projectId);

  /// Your own songs on the Open Mic, and what has come back to them.
  Future<List<OpenMicStatus>> myOpenMic();

  /// What this account is allowed to do, asked of the one place that knows.
  /// Questions you have asked, newest first, with anything said back.
  Future<List<HelpRequest>> myHelpRequests();

  Future<MyPlan> myPlan();

  /// Finished songs somebody chose to show, newest first.
  Future<List<ShowcaseSong>> showcase({int limit});

  /// Marks a song done. Private: this alone shows it to nobody.
  Future<void> finishSong(String projectId);

  /// Shows the finished song publicly. Separate consent, like the Open Mic.
  Future<void> showSong(String projectId);

  Future<void> unshowSong(String projectId);

  Future<void> claimPart(String part);

  Future<Musician?> loadMusician(String profileId);

  /// What you say about yourself, in your own words.
  ///
  /// Its own call rather than another argument on [setOpenMicPresence],
  /// which takes `discoverable` as a required parameter — editing a sentence
  /// about yourself must never be able to flip a privacy switch, and the
  /// cheapest way to guarantee that is a function that cannot. An empty
  /// string clears it.
  Future<void> setBio(String bio);

  /// Turning yourself on or off in Open Mic, and what strangers may know.
  ///
  /// A null [city] leaves the existing one alone; an empty one removes it.
  /// [singsIn] is the languages and traditions somebody declares, kept like
  /// [soundsLike]: five at most, one spelling for one word.
  Future<void> setOpenMicPresence({
    required bool discoverable,
    String? city,
    String? locationVisibility,
    List<String>? plays,
    List<String>? soundsLike,
    List<String>? singsIn,
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

  /// Find somebody by name.
  ///
  /// Only people who have turned discoverability on — being findable is off
  /// until somebody switches it on, and a name search that ignored that
  /// would quietly undo the one privacy control the Open Mic has.
  Future<List<FoundPerson>> searchPeople(String query);

  /// Who can be told about this song, and why each of them is on the list.
  ///
  /// Everybody in the room it lives in, plus your own people. Not anybody
  /// whose id you happen to hold.
  Future<List<SuggestedPerson>> peopleToTell(String projectId);

  /// Tell some people, or the whole room, about this song.
  ///
  /// [personIds] null or empty means everybody in the room. A band does not
  /// divide neatly into "one person" and "all of them", so this takes however
  /// many were picked. Returns how many were actually told — a list where
  /// everybody has blocked you tells nobody, and the button must not claim
  /// otherwise.
  Future<int> tellAboutSong(
    String projectId, {
    String? note,
    List<String>? personIds,
  });

  /// Everybody you are connected to, plus anybody waiting on an answer.
  ///
  /// Pending first, because a request nobody answers is the one thing here
  /// that goes stale.
  Future<List<Connection>> listConnections();

  /// Ask somebody to connect. Returns true when the pair ended up connected,
  /// which happens immediately if they had already asked you.
  Future<bool> requestConnection(String personId);

  /// Answer somebody who asked.
  Future<void> respondToConnection(String personId, {required bool accept});

  /// Undo, from either side, whatever the state.
  Future<void> removeConnection(String personId);

  /// People the app can say something true about, who are not connected yet.
  Future<List<SuggestedPerson>> peopleYouMightAdd();

  /// Say how reachable you are, and until when.
  Future<void> setAvailability(
    Availability state, {
    String? note,
    DateTime? until,
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
  ///
  /// [terms] says what answering means, and is settled here: the database
  /// refuses to change it once the ask has gone up. [sungIn] is what somebody
  /// answering would be joining, in the asker's words: "Sa = C#, Rupak,
  /// Hindi" (Every Musician, Same Song, 17 September 2026).
  Future<SongAsk> askFor({
    required String projectId,
    String? part,
    String note = '',
    AskTerms terms = AskTerms.play,
    String sungIn = '',
  });

  /// Stop asking, because somebody answered or because it stopped mattering.
  Future<void> closeAsk(SongAsk ask);

  /// The ids of people who have said they heard this song.
  ///
  /// Nothing like [markProjectSeen], which records that somebody *opened* a
  /// song so a badge can be cleared and is private to them by design. This is
  /// a thing a person chooses to say, and the room is meant to see it.
  Future<List<String>> loadNods(String projectId);

  /// Say you heard it, or take it back. A [note] is one line to whoever put
  /// the song up; null is the nod on its own.
  Future<void> setNod({
    required String projectId,
    required bool heard,
    String? note,
  });

  /// The line you attached to your own nod on this song, or null.
  Future<String?> nodNote(String projectId);

  /// What has been said back on an ask, oldest first.
  ///
  /// Readable by exactly the people who can see the ask: the room for a
  /// room ask, the one person for a direct one, and whoever asked. An
  /// opinion is the exception: its writer always sees it, the asker sees it
  /// once they have said they are ready, and nobody else ever does.
  Future<List<AskReply>> loadAskReplies(String askId);

  /// Say something on an ask, through a [door] or as a plain line. The
  /// people already in the conversation are told; the room is not told
  /// again. An opinion tells nobody until the asker is ready for it.
  Future<AskReply> replyToAsk({
    required String askId,
    required String body,
    ReplyDoor? door,
  });

  /// Say you are ready to read the opinions on your own ask. Once, and it
  /// stands: from here on opinions arrive normally. Refused for anybody
  /// but the person who asked.
  Future<void> openOpinions(String askId);

  /// Take back something you said.
  Future<void> deleteAskReply(AskReply reply);

  /// Whether you can write to this person: connected, or in a room together,
  /// and no block either way. The same rule as telling them about a song.
  Future<bool> canMessage(String personId);

  /// What the two of you have said, oldest first.
  Future<List<DirectMessage>> loadMessagesWith(String personId);

  /// Say something to one person. They are told; nobody else is.
  Future<DirectMessage> sendMessageTo({
    required String personId,
    required String body,
  });

  /// Take back something you said to them.
  Future<void> deleteMessage(DirectMessage message);

  /// Every thread you are in -- each room, and each person you have
  /// written to or heard from -- newest first, with what was last said
  /// and how much you have not seen.
  Future<List<ThreadSummary>> myThreads();

  /// You have looked at this thread, now.
  Future<void> markThreadRead({required ThreadKind kind, required String targetId});

  /// What the room has said, oldest first.
  Future<List<RoomMessage>> loadRoomMessages(String roomId);

  /// Say something to the whole room. Every other member is told.
  Future<RoomMessage> sendRoomMessage({required String roomId, required String body});

  /// Take back something you said to the room.
  Future<void> deleteRoomMessage(RoomMessage message);

  /// Today's prompt, kept for the day, and one of your songs with a key
  /// and chords, for the Tonight card on Home.
  Future<Tonight> tonight();

  /// What changed in the app lately, newest first.
  Future<List<ReleaseNote>> releaseNotes();

  /// The notes you have left, unexpired, newest first.
  Future<List<StandingWant>> myWants();

  /// Leave a note that you would like to meet somebody who plays [part].
  /// Leaving the same one again renews it for a month.
  Future<StandingWant> leaveWant({
    required String part,
    required String label,
    String? note,
  });

  /// Not looking any more.
  Future<void> dropWant(String id);

  /// What followed sessions left you to practise in the last fortnight,
  /// newest first. Nobody else can read these.
  Future<List<PracticeMark>> myPracticeMarks();

  /// Your open lesson links, oldest first; empty when you have none.
  Future<List<LessonLink>> myLessonLinks();

  /// Makes a lesson link named [title]. With [asClass], also the room the
  /// whole class listens in, named for the link (0148). Refused at the
  /// ninth open link, in the sentence [lessonLinksAreCapped].
  Future<LessonLink> openLessonLink(String title, {bool asClass = false});

  /// Makes an open link of yours a class, or stops it being one. Turning it
  /// on makes the class room if the link has none; turning it off leaves the
  /// room and everybody in it, because a room with people in it is theirs.
  Future<void> setLessonLinkClass(String linkId, {required bool asClass});

  /// Turns one lesson link off. Rooms already made through it stay.
  Future<void> closeLessonLink(String linkId);

  /// Opens somebody's lesson link: your own room with them, made the first
  /// time and the same room every time after. Returns the room's id.
  ///
  /// A class link (0148) also puts you in the class room, to listen, in the
  /// same step; the room returned is still your own.
  Future<String> joinLessonLink(String code);

  /// Whether this room was made by opening a teacher's lesson link (0129) --
  /// the teacher and one student, and nobody else.
  ///
  /// Every Musician, Same Song, 17 September 2026: a hand-in already works by
  /// construction, because a take is private until it is shared and sharing
  /// in a two-person room tells exactly one person. All that is missing is
  /// the words, and this is the question those words hang on.
  ///
  /// False for every band room, and false for somebody who is not in the
  /// lesson: `lesson_rooms` shows a row only to the student it belongs to
  /// and to the teacher whose link made it.
  Future<bool> isLessonRoom(String roomId);

  /// Your code for meeting in person (0130), made the first time you ask.
  Future<String> myMeetingCode();

  /// A new meeting code. The old one opens nobody; people already added
  /// stay added.
  Future<String> changeMyMeetingCode();

  /// Whose meeting code this is, typed however it was typed. Adds nobody:
  /// adding is [requestConnection].
  Future<MetPerson> personWithMeetingCode(String code);

  /// Where you stand for calls (0134): never asked, adult, under 18, or
  /// refused after an under-13 answer (0138).
  Future<CallStanding> myCallStanding();

  /// Your birth month, said once. Under 13 is not an error: it answers
  /// [CallStanding.refused] and is remembered without the month (0138). Any
  /// later answer is refused: correcting one goes through a person.
  Future<CallStanding> setMyBirthMonth({required int year, required int month});

  /// A ticket into this room's call. Throws [CallRefused] with the reason
  /// said to the person, or with [CallRefused.birthMonthNeeded].
  Future<CallTicket> callTicket({required String roomId, required String device});

  /// I am in this room's call. Every twenty seconds while in it; the first
  /// in a quiet room tells the rest of the room.
  Future<void> hearMeInCall({required String roomId, required String device});

  Future<void> leaveCall({required String roomId, required String device});

  /// Who is in this room's call right now.
  Future<List<InCallPerson>> roomCall(String roomId);

  /// Keeps what a followed session worked on. Keeping a mark with the same
  /// id again updates it; a note already kept is not lost to a later save
  /// without one.
  Future<void> keepPracticeMark(PracticeMark mark);

  /// Leaves a student something to practise, without a live session (0143).
  ///
  /// Only a teacher can, and only in a lesson room of their own (0129) on a
  /// song in it; everybody else is refused. It writes the mark 0128 writes,
  /// owned by the student and led by the teacher, so what arrives is the
  /// practice card Home already has. Leaving practice again on the same song
  /// replaces what this teacher left before rather than adding a second.
  ///
  /// Nothing comes back. A mark is read by its owner and nobody else, so a
  /// teacher never sees this again — not the mark, and not whether it was
  /// opened.
  Future<void> leavePracticeForStudent({
    required String projectId,
    required String studentId,
    required String label,
    required double rate,
    int? startMs,
    int? endMs,
    String? note,
  });

  /// Every note pinned to a moment of a recording on this song, earliest
  /// moment first.
  ///
  /// Read by exactly the people who can hear the recording (0141), so a note
  /// on somebody else's unshared take never arrives here at all.
  Future<List<MomentNote>> loadMomentNotes(String projectId);

  /// Pins words at [atMs] of a recording. A null [layerId] means the song's
  /// own recording; [endMs] makes it a passage rather than an instant.
  ///
  /// Whoever played the recording is told, once. Nobody is told about their
  /// own note.
  Future<MomentNote> addMomentNote({
    required String projectId,
    required int atMs,
    required String body,
    String? layerId,
    int? endMs,
  });

  /// Pins what somebody said at [atMs] of a recording (0152).
  ///
  /// The audio goes up first, the way a line voice note does, and the row
  /// is written once the bytes are there; if either half does not land,
  /// this throws rather than leaving a note that plays nothing. [roomId] is
  /// the first segment of the storage path, which every policy on the
  /// bucket reads.
  Future<MomentNote> addSpokenMomentNote({
    required String roomId,
    required String projectId,
    required int atMs,
    required Uint8List bytes,
    String? layerId,
  });

  /// What was said, for a note with a voice. Throws for a typed note.
  Future<Uint8List> loadSpokenNote(MomentNote note);

  /// Takes back a note you left. Yours only, and nothing is said about a
  /// note that is not. A spoken note's audio goes with it.
  Future<void> deleteMomentNote(MomentNote note);

  /// Who is looking for what you play, as counts per part.
  Future<List<WantAround>> wantsAround();

  /// Ask the app about a song. It answers from what it worked out -- key,
  /// chords, sections, words, who played what -- and every answer carries
  /// the way to a person.
  Future<SongAnswer> askTheSong({
    required String projectId,
    required String question,
  });

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

  /// The same thing from an id alone.
  ///
  /// For callers that know which song they mean without holding its whole
  /// row — the picker behind "ask somebody who is not here yet" lists songs
  /// from `songs_i_can_offer`, which returns identities rather than rows,
  /// and loading every song in every room to build one invitation would be
  /// an expensive way to end up with the same string.
  Future<InviteResult> createProjectInviteFor({
    required String projectId,
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
