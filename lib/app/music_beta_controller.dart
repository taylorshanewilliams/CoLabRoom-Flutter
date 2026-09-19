import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../domain/activity.dart';
import '../data/music_repository.dart';
import '../domain/lesson_link.dart';
import '../domain/music_models.dart';
import '../domain/practice_mark.dart';
import '../domain/sealed_take.dart';
import '../domain/sent_take.dart';
import '../domain/song_brief.dart';
import '../domain/song_analysis_models.dart';
import '../domain/tonight_models.dart';
import '../services/kept_songs.dart';
import '../services/retry.dart';
import '../services/song_analysis_service.dart';
import '../services/user_facing_error.dart';
import '../services/error_reporter.dart';

class MusicBetaController extends ChangeNotifier with WidgetsBindingObserver {
  MusicBetaController(
    this.repository, {
    KeptSongs? kept,
    Future<SongAnalysisBundle> Function(String projectId)? loadSheet,
  })  : _kept = kept ?? KeptSongs(),
        _loadSheetOverride = loadSheet {
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
  List<AskForMe> _asksForMe = const <AskForMe>[];
  List<PartQuestion> _partQuestions = const <PartQuestion>[];
  List<RoomInviteForMe> _roomInvitesForMe = const <RoomInviteForMe>[];
  List<OpenMicSong> _openMicSongs = const <OpenMicSong>[];
  List<Musician> _openMicPeople = const <Musician>[];
  List<Setlist> _setlists = const <Setlist>[];
  List<AppNotification> _notifications = const <AppNotification>[];
  NotificationPreferences _notificationPreferences = const NotificationPreferences();
  bool _loading = false;
  String? _error;
  StreamSubscription<void>? _changesSubscription;
  Timer? _reloadDebounce;

  /// The lesson rooms this person teaches (0129), by id, asked of the
  /// repository once per [load] rather than once per song opened: nearly
  /// everybody teaches nobody, and the answer changes only when a student
  /// joins, which is when the rooms themselves change and are read again.
  /// A failed ask is not kept, so the next song asks afresh.
  List<String>? _taught;

  Future<List<String>> lessonRoomsTaught() async {
    final known = _taught;
    if (known != null) return known;
    final taught = await repository.lessonRoomsTaught();
    _taught = taught;
    return taught;
  }

  // Room logos / song covers are stored privately and fetched by storage
  // path on demand, then kept here so every tile rebuild doesn't re-hit
  // storage — cleared for a path once its Room/Song's logo/cover changes.
  final Map<String, Uint8List> _imageCache = <String, Uint8List>{};
  final Set<String> _imageFetchesInFlight = <String>{};

  /// Invitations somebody has said no thanks to, while Undo is still on
  /// screen.
  ///
  /// Declining is final on the server: `decline_room_invitation` and
  /// `answer_room_invite` both close the invitation and tell whoever sent it,
  /// there and then. So the no is held back here, the card leaves the inbox
  /// at once, and nothing is sent until Undo has gone without being pressed
  /// (audit, 17 September 2026). Here rather than on the inbox screen so the
  /// card stays gone, and the bell's count stays right, after somebody
  /// leaves the inbox and comes back before it is sent.
  final Set<String> _declinesHeld = <String>{};

  /// Declines that have gone out, kept out of the lists for as long as this
  /// controller lives.
  ///
  /// Sending reloads, but a reload already running when the decline goes out
  /// makes that reload a no-op and can finish with the invitation still in
  /// it. Letting go of the hold alone then brought a closed card back with a
  /// live No thanks that could only fail (review of the audit fixes, 17
  /// September 2026). Keeping the id costs nothing: a closed invitation is
  /// never reopened, and inviting somebody again makes a new one.
  final Set<String> _declinesSent = <String>{};

  bool _answeredNo(String inviteId) =>
      _declinesHeld.contains(inviteId) || _declinesSent.contains(inviteId);

  bool _disposed = false;

  /// Takes an invitation out of every list while its decline can be undone.
  void holdDecline(String inviteId) {
    if (_disposed) return;
    if (_declinesHeld.add(inviteId)) notifyListeners();
  }

  /// Undo: the invitation is back, and nobody was told anything.
  void releaseDecline(String inviteId) {
    if (_disposed) return;
    if (_declinesHeld.remove(inviteId)) notifyListeners();
  }

  /// Sends a held decline with [send], unless it was taken back first.
  ///
  /// Also nothing once this controller is gone, which means the account
  /// signed out in the seconds Undo was up. An invitation left open is the
  /// safe way for that to go wrong: it is still there to answer next time.
  Future<void> sendHeldDecline(
    String inviteId,
    Future<void> Function() send,
  ) async {
    if (_disposed || !_declinesHeld.contains(inviteId)) return;
    try {
      await send();
      // Before the hold goes, so the card is never back for a frame.
      _declinesSent.add(inviteId);
    } finally {
      releaseDecline(inviteId);
    }
  }

  List<MusicRoom> get rooms => List<MusicRoom>.unmodifiable(_rooms);
  List<BetaInvite> get invites => List<BetaInvite>.unmodifiable(
      _invites.where((invite) => !_answeredNo(invite.id)));

  /// Somebody asking you by name to play on one of their songs. Kept beside
  /// invitations because it is the same kind of thing to a person — a request
  /// waiting on an answer — even though it grants a song rather than a
  /// room.
  List<AskForMe> get asksForMe => List<AskForMe>.unmodifiable(_asksForMe);

  /// Somebody wanting to put a song with a part of yours on it in front of
  /// everybody, waiting on your yes (0155). The most personal thing the
  /// inbox holds: it is about your own playing, and a song is waiting on it.
  List<PartQuestion> get partQuestions =>
      List<PartQuestion>.unmodifiable(_partQuestions);

  /// Somebody inviting you into a whole room of theirs, by name rather
  /// than by emailing you a code.
  List<RoomInviteForMe> get roomInvitesForMe =>
      List<RoomInviteForMe>.unmodifiable(
          _roomInvitesForMe.where((invite) => !_answeredNo(invite.id)));

  /// A slice of what is going on outside your own rooms.
  ///
  /// Home used to show only your own activity, which for a new account is
  /// nothing at all — you signed in and the app waited for you. These are the
  /// two things that can be true before you have done anything: somebody put
  /// a song up, and somebody is here to play on one.
  List<OpenMicSong> get openMicSongs =>
      List<OpenMicSong>.unmodifiable(_openMicSongs);
  List<Musician> get openMicPeople =>
      List<Musician>.unmodifiable(_openMicPeople);
  List<Setlist> get setlists => List<Setlist>.unmodifiable(_setlists);

  List<Setlist> _setsForTheDay = const <Setlist>[];

  /// The dated sets waiting for this person, whoever made them (0164).
  ///
  /// Not [setlists]: those are this person's own, and these are the
  /// occasions they are playing on — usually somebody else's set, made by
  /// whoever leads. Empty on nearly every day of nearly everybody's year.
  List<Setlist> get setsForTheDay => List<Setlist>.unmodifiable(_setsForTheDay);

  List<AppNotification> get notifications => List<AppNotification>.unmodifiable(_notifications);
  NotificationPreferences get notificationPreferences => _notificationPreferences;
  int get unreadNotificationCount => _notifications.where((n) => !n.isRead).length;

  List<ThreadSummary> _threads = const <ThreadSummary>[];

  /// Every thread you are in, as the Messages screen lists them.
  List<ThreadSummary> get threads => List<ThreadSummary>.unmodifiable(_threads);

  /// Lines from other people you have not seen, across every thread.
  /// The number on the Messages icon.
  int get unreadThreadCount =>
      _threads.fold<int>(0, (sum, thread) => sum + thread.unread);

  Tonight _tonight = const Tonight();
  List<ReleaseNote> _releases = const <ReleaseNote>[];

  /// Today's prompt and song, for the Tonight card on Home.
  Tonight get tonight => _tonight;

  /// What changed lately, for the same card.
  List<ReleaseNote> get releases => List<ReleaseNote>.unmodifiable(_releases);

  List<PracticeMark> _practiceMarks = const <PracticeMark>[];

  /// What a lesson, or this person's own practice, left to practise, newest
  /// first. A mark led by this person is their own work on the song rather
  /// than somebody else's — see isYourOwnPractice in
  /// features/workspace/practice_marks.dart.
  List<PracticeMark> get practiceMarks => List<PracticeMark>.unmodifiable(_practiceMarks);

  List<SongBrief> _songBriefs = const <SongBrief>[];

  /// What to practise on songs a teacher sent (0150), newest first: the
  /// briefs this person is either end of. Home makes a card of the ones
  /// asked of them, and the song shows its own to both people. Read with
  /// everything else and at no other time -- nobody is told when one is
  /// set, and nothing is sent back when one is read.
  List<SongBrief> get songBriefs => List<SongBrief>.unmodifiable(_songBriefs);

  /// The brief on this song, or null, which is nearly every song.
  SongBrief? briefFor(String projectId) =>
      _songBriefs.where((brief) => brief.projectId == projectId).firstOrNull;

  List<SentTake> _sentTakes = const <SentTake>[];

  /// What students have sent this person, across every lesson they teach
  /// (0151), oldest first -- so the last one is the one that came in last.
  ///
  /// Empty for nearly everybody, because nearly everybody teaches nobody.
  /// Home makes one card of it and the listening desk is the list itself.
  /// Read with everything else and at no other time: nothing is written by
  /// reading it, so a student never finds out whether their teacher has got
  /// to theirs.
  List<SentTake> get sentTakes => List<SentTake>.unmodifiable(_sentTakes);

  /// Who is looking, or empty when there is nobody to ask.
  ///
  /// The repository throws rather than answering once a session has gone, and
  /// none of the screens that want to know who you are should fall over
  /// because of it: not knowing simply means a mark cannot be told from a
  /// lesson's, so none is kept.
  String get meOrNobody {
    try {
      return repository.currentUserId;
    } catch (_) {
      return '';
    }
  }

  /// Keeps what a session worked on — a lesson that was followed, or this
  /// person's own practice — and shows it on Home at once rather than at the
  /// next reload. A save that fails is reported, and the card stays for this
  /// session: the student still has it tonight.
  Future<void> keepPracticeMark(PracticeMark mark) async {
    final previous = _practiceMarks.where((kept) => kept.id == mark.id).firstOrNull;
    final shown = PracticeMark(
      id: mark.id,
      projectId: mark.projectId,
      ledBy: mark.ledBy,
      ledByName: mark.ledByName,
      note: (mark.note ?? '').trim().isNotEmpty ? mark.note : previous?.note,
      parts: mark.parts,
      updatedAt: mark.updatedAt,
    );
    _practiceMarks = <PracticeMark>[
      shown,
      for (final kept in _practiceMarks)
        if (kept.id != mark.id) kept,
    ];
    notifyListeners();
    try {
      await retrying(() => repository.keepPracticeMark(mark));
    } catch (error) {
      unawaited(ErrorReporter().reportWarning(
        service: 'app', stage: 'practice_mark.keep', message: error.toString()));
    }
  }

  List<SealedTake> _sealedTakesDue = const <SealedTake>[];

  /// The takes this person sealed whose day has come (0158), earliest first.
  /// Empty on nearly every day of anybody's year.
  List<SealedTake> get sealedTakesDue => List<SealedTake>.unmodifiable(
      _sealedTakesDue.where((take) => !_sealsEnded.contains(take.id)));

  /// The seals answered since the app opened. A reload that lands between
  /// the tap and the server hearing about it would otherwise fetch the take
  /// as still due and put the card straight back.
  final Set<String> _sealsEnded = <String>{};

  /// Seals a take until [until], and answers with the day it opens.
  ///
  /// Through here rather than straight to the repository so that a take
  /// sealed a second time, in a session that already answered its first
  /// card, is offered again when its new day comes.
  ///
  /// The answered card leaves the fetched list before its id leaves
  /// [_sealsEnded]. The list is only refetched when the app loads, so until
  /// then the id was the one thing hiding it, and forgetting the id alone
  /// put "A year ago tonight" back on Home for a take sealed a minute ago --
  /// where either answer would have quietly undone the new seal.
  Future<DateTime> sealTake(String layerId, {required DateTime until}) async {
    final opens = await repository.sealTake(layerId, until: until);
    final stillDue = <SealedTake>[
      for (final take in _sealedTakesDue)
        if (take.id != layerId) take,
    ];
    final changed = stillDue.length != _sealedTakesDue.length;
    _sealedTakesDue = stillDue;
    _sealsEnded.remove(layerId);
    if (changed) notifyListeners();
    return opens;
  }

  /// Ends a seal, whichever way its card was answered.
  ///
  /// Every Musician, Same Song, 17 September 2026: "Not now" ends it for
  /// good, and so does playing it. The card goes before the server hears, the
  /// way a dismissed piece of news does, and it is not put back if the call
  /// fails: a card that returns after "Not now" is the one thing this must
  /// never do while somebody is looking. A seal the server never heard about
  /// is still a seal, so the next time the app opens it is offered again,
  /// which is the honest outcome.
  ///
  /// Answers whether the server heard. Only "Play it" asks, and only when
  /// the take would not play: it has to say where the take is, and "back
  /// among your takes" is not true of a seal that never ended.
  Future<bool> endSeal(SealedTake take) async {
    _sealsEnded.add(take.id);
    notifyListeners();
    try {
      await retrying(() => repository.unsealTake(take.id));
      return true;
    } catch (error) {
      unawaited(ErrorReporter().reportWarning(
        service: 'app', stage: 'sealed_take.end', message: error.toString()));
      return false;
    }
  }

  List<ActivityItem> _activity = const <ActivityItem>[];

  /// What the band has been doing, newest first, nobody's own actions.
  ///
  /// Empty is the ordinary state for a band that has not played this week,
  /// and Home must render that as simply having no news — never as an empty
  /// state announcing the absence, which makes a quiet week look like a
  /// broken feature.
  List<ActivityItem> get activity => List<ActivityItem>.unmodifiable(_activity);

  /// Puts one item away, off the screen before the server hears about it.
  ///
  /// A dismissal that waits for a round trip feels broken on a slow
  /// connection — the row sits there after the swipe as though nothing
  /// happened. It goes on failure too: a piece of news that will not stay
  /// dismissed is worse than one that was never dismissible.
  Future<void> dismissActivity(String eventId) async {
    final removed = _activity.where((item) => item.id == eventId).toList();
    if (removed.isEmpty) return;
    _activity =
        _activity.where((item) => item.id != eventId).toList(growable: false);
    notifyListeners();
    try {
      await repository.dismissActivity(eventId);
    } catch (error) {
      // Put back, because it is still there for everyone else and will
      // reappear on the next load anyway — and counted, because somebody
      // whose dismissals never stick experiences a feed that will not listen.
      unawaited(ErrorReporter().reportWarning(
        service: 'app', stage: 'dismiss_activity', message: error.toString()));
      _activity = <ActivityItem>[...removed, ..._activity]
        ..sort((a, b) => b.at.compareTo(a.at));
      notifyListeners();
    }
  }

  /// Undo.
  Future<void> restoreActivity(ActivityItem item) async {
    try {
      await repository.restoreActivity(item.id);
    } catch (_) {
      // Failing to un-dismiss leaves it dismissed, which is recoverable by
      // nothing the person can see — so put it back on screen regardless and
      // let the next load decide.
    }
    _activity = <ActivityItem>[item, ..._activity]
      ..sort((a, b) => b.at.compareTo(a.at));
    notifyListeners();
  }

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
    } catch (error) {
      // Recording that somebody listened must never interrupt listening, and
      // the next load re-reads the truth from the server. Counted anyway: if
      // this fails for everybody, every unread badge in the app stops
      // clearing and there is no other symptom.
      unawaited(ErrorReporter().reportWarning(
        service: 'app', stage: 'mark_seen', message: error.toString()));
    }
  }
  Iterable<SongProject> get projects => _rooms.expand((room) => room.projects);
  bool get loading => _loading;
  String? get error => _error;

  Future<void> load() async {
    if (_loading) return;
    _loading = true;
    _error = null;
    _taught = null;
    notifyListeners();
    try {
      // The first call carries the token past the server for the first time
      // this session; if the token is refused as "from the future", a few
      // seconds is what fixes it (see worthRetrying). Only the first call is
      // retried: the ones after it use the same token, so if it passed once
      // it passes again, and if it never passes there is one report, not
      // four.
      _rooms = await retrying(
        repository.loadRooms,
        first: const Duration(seconds: 2),
      );
      // And the four after it, for a different reason than the token.
      //
      // The note above is right about tokens and was wrong about the
      // network. A gateway timeout on the third call is not the first
      // call's problem happening again — it is its own, and it took the
      // whole library down with it: one dropped connection anywhere in
      // this sequence and somebody's songs were replaced by an error until
      // they thought to try again. Production's log for the week of
      // 15 September has exactly that, twice, and both landed in the
      // crash-free rate as though the app had broken.
      //
      // Every call here is a read, so repeating one costs nothing and
      // changes nothing. A failure that survives three tries is still
      // reported, which is the one worth reading.
      _invites = await retrying(repository.loadInvites);
      _setlists = await retrying(repository.loadSetlists);
      _notifications = await retrying(repository.loadNotifications);
      _notificationPreferences =
          await retrying(repository.loadNotificationPreferences);
      // Best-effort and last. A badge is the least important thing on this
      // screen: failing to fetch it must never cost somebody their songs,
      // which is what putting it in the main try would do.
      try {
        _unheardTakes = await repository.loadUnheardTakeCounts();
      } catch (_) {
        // Left as it was. A stale count is better than a list that failed.
      }
      // Also best-effort, and for the same reason: somebody who has been
      // asked to play on a song should not lose their own library because
      // that one query failed.
      try {
        _asksForMe = await repository.asksForMe();
      } catch (_) {
        // Left as it was.
      }
      try {
        _partQuestions = await repository.partQuestionsForMe();
      } catch (_) {
        // Left as it was. A question that could not be fetched is still
        // waiting, and nothing goes out until it is answered.
      }
      try {
        _roomInvitesForMe = await repository.roomInvitesForMe();
      } catch (_) {
        // Left as it was.
      }
      // Best-effort, like the rest of this block. A quiet Open Mic must never
      // be the reason somebody cannot see their own songs.
      try {
        _openMicSongs = await repository.openMicSongs(limit: 3);
      } catch (_) {
        // Left as it was.
      }
      try {
        _openMicPeople = await repository.findMusicians(limit: 3);
      } catch (_) {
        // Left as it was.
      }
      try {
        _activity = await repository.loadActivity(limit: 20);
      } catch (_) {
        // Same bargain: news is the nicest thing on Home and the least
        // important. Songs load or nothing else matters.
      }
      try {
        _threads = await repository.myThreads();
      } catch (_) {
        // The badge on the Messages icon. Same bargain again.
      }
      // The Tonight card. The nicest thing on Home and, again, the
      // least important: a day without one is a day, not a failure.
      try {
        _tonight = await repository.tonight();
      } catch (_) {
        // Left as it was.
      }
      try {
        _releases = await repository.releaseNotes();
      } catch (_) {
        // Left as it was.
      }
      // What a lesson left to practise. Same bargain as Tonight.
      try {
        _practiceMarks = await repository.myPracticeMarks();
      } catch (_) {
        // Left as it was.
      }
      // A take sealed a year ago whose day has come (0158). Same bargain,
      // and the kindest failure there is: the seal is still on the server,
      // so a card that could not be fetched today is offered tomorrow.
      try {
        _sealedTakesDue = await repository.sealedTakesDue();
      } catch (_) {
        // Left as it was.
      }
      // And what a teacher asked for with a song they sent. The same again.
      try {
        _songBriefs = await repository.mySongBriefs();
      } catch (_) {
        // Left as it was.
      }
      // The sets somebody is playing on this week (0164). The same bargain:
      // a card that could not be fetched today is offered tomorrow, and the
      // set is on the server either way.
      try {
        _setsForTheDay = await repository.setsForTheDay();
      } catch (_) {
        // Left as it was.
      }
      // What students have sent (0151). One more of the same bargain, and
      // it answers with nothing at all for everybody who teaches nobody.
      try {
        _sentTakes = await repository.takesSentToMe();
      } catch (_) {
        // Left as it was. A hand-in is on the server either way, and the
        // card is offered again the next time the app opens.
      }
      // The signed-in user's own picture, fetched once with everything else.
      // It used to be fetched only by the account screen, so the face in the
      // corner of Home was initials until you had been to Settings — for
      // anybody who never went, the picture they uploaded never appeared.
      unawaited(loadAvatar());
      // The library loaded, so it can say which kept songs are still this
      // person's to hear, and bring the rest up to date.
      unawaited(_followKeptSongs());
    } catch (error) {
      // The most consequential failure in the app: nothing loaded, so from
      // the outside it simply did not open. It has never been reported —
      // a tester saying "it's broken" produced no row, which is
      // indistinguishable from nothing having gone wrong.
      _error = reportAndDescribe(error, service: 'app', stage: 'load');
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// The songs kept on this phone (KeptSongs), for the two rules about them
  /// that are the library's to apply. See [_followKeptSongs].
  final KeptSongs _kept;

  /// Where a kept song's sheet is asked for. Null in production, which
  /// reaches for the real service; a test hands in its own.
  final Future<SongAnalysisBundle> Function(String projectId)? _loadSheetOverride;

  Future<SongAnalysisBundle> _loadSheet(String projectId) =>
      (_loadSheetOverride ?? SongAnalysisService(kept: _kept).load)(projectId);

  /// The kept songs whose sheet the library has already brought up to date
  /// since the app was opened. Once each is enough: the library reloads on
  /// every change anybody makes, and five requests a song each time would
  /// be a great deal of asking about songs nobody is looking at.
  final Set<String> _sheetsFollowed = <String>{};

  /// The follow that is running now, if one is. A second load while it runs
  /// joins it rather than starting another beside it.
  Future<void>? _keptFollowed;

  /// What the last library load is still doing about the kept songs. A test
  /// waits on it before it takes the disk away.
  @visibleForTesting
  Future<void> get keptSongsFollowed => _keptFollowed ?? Future<void>.value();

  /// Takes off this phone any kept song this person can no longer open, and
  /// brings the others up to date.
  ///
  /// A kept copy is only ever made of something this person's own session
  /// could download, which is the same storage policy that decides what
  /// plays online. But rooms change: somebody is removed from a band, or a
  /// song is deleted, and a copy kept for the van must not outlive the
  /// right to hear it. Only run once the library has loaded, because a song
  /// missing from a library that did not load is not missing at all -- it
  /// is the very case the copy was kept for. A kept song the library does
  /// not list is asked about by id, and dropped only on a clear no; a
  /// question the server did not answer keeps it.
  ///
  /// And a copy must not quietly fall behind the song while the menu goes
  /// on saying "On this phone". A set kept on Monday for Friday is not
  /// opened in Perform song by song in between, so Perform's own refresh
  /// never runs; the library is what does open (review, 18 September 2026).
  /// The words cost nothing, because this load already carries them, so
  /// they follow every time. The sheet is asked for once a session.
  ///
  /// Quiet throughout, and after the library is shown: nothing here may
  /// cost anybody their songs.
  Future<void> _followKeptSongs() =>
      _keptFollowed ??= _followKeptSongsNow().whenComplete(() => _keptFollowed = null);

  Future<void> _followKeptSongsNow() async {
    try {
      final ids = await _kept.keptIds();
      for (final id in ids) {
        final project = projectById(id);
        if (project == null) {
          final still = await repository.loadProject(id);
          if (still == null) await _kept.remove(id);
          continue;
        }
        await _kept.followWords(project);
        if (_sheetsFollowed.contains(id)) continue;
        try {
          await _kept.refresh(project, await _loadSheet(id));
          _sheetsFollowed.add(id);
        } catch (_) {
          // The sheet as it was kept. The next load asks again, and so
          // does Perform's own door.
        }
      }
    } catch (_) {
      // Next load.
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
    // Setting a picture clears any earlier failure to fetch one at this
    // path, or the face the account just chose would stay initials
    // everywhere it is drawn from the cache.
    _avatarMisses.remove(path);
    notifyListeners();
  }

  Future<void> clearAvatar() async {
    await repository.clearAvatar();
    if (_avatarPath != null) _imageCache.remove(_avatarPath);
    _avatarPath = null;
    notifyListeners();
  }

  final Set<String> _avatarFetchesInFlight = <String>{};
  final Set<String> _avatarMisses = <String>{};

  /// Bytes for anybody's profile picture, by storage path — a bandmate whose
  /// face belongs on a song they started, or the actor on an activity row.
  ///
  /// Same shape as [roomLogoBytes]: asking triggers the fetch and
  /// [notifyListeners] fires when it lands, so a face appears the frame
  /// after it arrives without any caller awaiting anything. Cached by path
  /// rather than by person, because one picture belongs to one profile and
  /// shows up in every room they are in.
  ///
  /// Deliberately separate from [_imageBytes]: that one identifies an image
  /// by searching the loaded rooms for something that claims the path, and a
  /// face can belong to somebody who is not in any of them.
  Uint8List? avatarBytesFor(String? path) {
    if (path == null) return null;
    final cached = _imageCache[path];
    if (cached != null) return cached;
    // A path that already failed is not retried. Song lists rebuild often,
    // and a picture whose object is gone would otherwise mean a fresh 404
    // per row per frame.
    if (_avatarMisses.contains(path)) return null;
    if (_avatarFetchesInFlight.add(path)) {
      unawaited(_fetchAvatar(path));
    }
    return null;
  }

  Future<void> _fetchAvatar(String path) async {
    try {
      _imageCache[path] = await repository.loadAvatar(path);
      notifyListeners();
    } catch (_) {
      // A face that will not download is a missing face, not an error worth
      // showing on a list of songs — the initials are already the fallback.
      _avatarMisses.add(path);
    } finally {
      _avatarFetchesInFlight.remove(path);
    }
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

  Future<void> cutLine(Contribution line) async {
    await repository.cutLine(line);
    await refreshProject(line.projectId);
  }

  /// Your own lines cut from [project], whoever cut them. Read when asked
  /// for rather than carried on the song: a cut line is not part of it.
  Future<List<Contribution>> linesYouCut(SongProject project) => repository.linesYouCut(project);

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

  Future<void> renameSetlist(Setlist setlist, String name) async {
    await repository.renameSetlist(setlist, name);
    await load();
  }

  Future<void> deleteSetlist(Setlist setlist) async {
    await repository.deleteSetlist(setlist);
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

  Future<void> saveSetlistSong(Setlist setlist, SetlistSong song) async {
    await repository.saveSetlistSong(setlist, song);
    await load();
  }

  /// Says which day a set is for, or takes the day off it again (0164).
  Future<void> setSetlistDay(Setlist setlist, DateTime? day) async {
    await repository.setSetlistDay(setlist, day);
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

  /// Opens somebody's lesson link and returns the room it gave you, with
  /// the library reloaded so the room is already on the shelf -- and the
  /// class room, when this was the scan that put you in one (0148). The
  /// server says only which room is yours, so the class room is whichever
  /// room of the teacher's you are a viewer in now and were not before, the
  /// way join_from_address finds an invitation's room.
  Future<LessonJoined> joinLessonLink(String code) async {
    final before = _rooms.map((room) => room.id).toSet();
    final roomId = await repository.joinLessonLink(code);
    await load();
    final room = roomById(roomId);
    if (room == null) return const LessonJoined(room: null);
    final me = repository.currentUserId;
    final classRoom = _rooms
        .where((each) =>
            each.id != room.id &&
            !before.contains(each.id) &&
            each.accountId == room.accountId &&
            each.members.any((member) => member.userId == me && member.role == RoomRole.viewer))
        .firstOrNull;
    return LessonJoined(room: room, classRoom: classRoom);
  }

  Future<void> declineInvite(BetaInvite invite) async {
    await repository.declineInvite(invite);
    await load();
  }

  /// Starts a song for a recording that has no home yet, and reloads so it
  /// appears under Songs straight away.
  Future<SongProject> startIdea({String? title}) async {
    final project = await repository.startIdea(title: title);
    await load();
    return project;
  }

  Future<void> removeRoomMember({
    required String roomId,
    required String userId,
  }) async {
    await repository.removeRoomMember(roomId: roomId, userId: userId);
    await load();
  }

  Future<void> leaveRoom(String roomId) async {
    await repository.leaveRoom(roomId);
    await load();
  }

  Future<void> inviteMusicianToRoom({
    required String roomId,
    required String profileId,
    String note = '',
  }) {
    return repository.inviteMusicianToRoom(
      roomId: roomId,
      profileId: profileId,
      note: note,
    );
  }

  Future<void> answerRoomInvite(
    RoomInviteForMe invite, {
    required bool accept,
  }) async {
    await repository.answerRoomInvite(invite.id, accept: accept);
    await load();
  }

  /// Says yes or no to being asked to play on somebody's song.
  ///
  /// Yes puts you on that one song — not the room it sits in. Reloading
  /// afterwards is what makes it appear under Songs, which is the whole
  /// visible result of saying yes.
  Future<void> answerAsk(AskForMe ask, {required bool accept}) async {
    await repository.answerAsk(ask.id, accept: accept);
    await load();
  }

  /// Yes or no to your part going in front of everybody on [projectId]
  /// (0155). From the card in the inbox, or from the song's dial afterwards
  /// when somebody changes their mind. Reloading is what takes the card
  /// away, and what brings in the word the owner is sent.
  Future<void> answerForMyPart(String projectId, {required bool yes}) async {
    await repository.answerForMyPart(projectId, yes: yes);
    await load();
  }

  Future<void> setMemberColor(MusicRoom room, int colorValue) async {
    await repository.setMemberColor(roomId: room.id, colorValue: colorValue);
    await load();
  }

  Future<void> submitFeedback(FeedbackDraft feedback) {
    return repository.submitFeedback(feedback);
  }

  /// The Messages list, fresh. On its own rather than through [load]
  /// because a thread is the one thing that changes while you look.
  Future<void> refreshThreads() async {
    try {
      _threads = await repository.myThreads();
      notifyListeners();
    } catch (error) {
      unawaited(ErrorReporter().reportWarning(
          service: 'app', stage: 'threads', message: error.toString()));
    }
  }

  /// Seen. The count clears here before the server hears about it, so
  /// the badge does not linger on the way back to Home.
  Future<void> markThreadRead(ThreadSummary thread) async {
    _threads = <ThreadSummary>[
      for (final existing in _threads)
        if (existing.kind == thread.kind && existing.targetId == thread.targetId)
          existing.copyWith(unread: 0)
        else
          existing,
    ];
    notifyListeners();
    try {
      await repository.markThreadRead(kind: thread.kind, targetId: thread.targetId);
    } catch (error) {
      unawaited(ErrorReporter().reportWarning(
          service: 'app', stage: 'thread_read', message: error.toString()));
    }
  }

  Future<void> markNotificationRead(AppNotification notification) async {
    if (notification.isRead) return;
    await repository.markNotificationRead(notification);
    await load();
  }

  /// Removes one, off the screen before the server hears about it.
  Future<void> deleteNotification(AppNotification notification) async {
    final kept = _notifications
        .where((item) => item.id != notification.id)
        .toList(growable: false);
    if (kept.length == _notifications.length) return;
    _notifications = kept;
    notifyListeners();
    try {
      await repository.deleteNotification(notification);
    } catch (error) {
      // Back on the next load. Better than a row that will not go away — but
      // a notification that keeps returning is exactly the kind of small
      // wrongness people stop reporting and start resenting.
      unawaited(ErrorReporter().reportWarning(
        service: 'app', stage: 'delete_notification', message: error.toString()));
    }
  }

  /// Clears everything already read, leaving anything still waiting.
  Future<void> deleteReadNotifications() async {
    _notifications =
        _notifications.where((item) => !item.isRead).toList(growable: false);
    notifyListeners();
    try {
      await repository.deleteReadNotifications();
    } catch (_) {
      // Same bargain.
    }
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
    _disposed = true;
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
