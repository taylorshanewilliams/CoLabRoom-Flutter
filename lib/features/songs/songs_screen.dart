import 'dart:async';
import 'dart:math' as math;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../../app/routes.dart';
import '../../services/current_route.dart';
import '../../services/set_aside.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../app/music_beta_controller.dart';
import '../../widgets/player_face.dart';
import '../../domain/activity.dart';
import '../../domain/music_models.dart';
import '../../domain/practice_mark.dart';
import '../../domain/sealed_take.dart';
import '../../domain/song_analysis_models.dart' show SongGrid;
import '../../services/kept_songs.dart';
import '../../services/now_playing.dart';
import '../../services/song_analysis_service.dart';
import '../../widgets/on_this_phone_mark.dart';
import '../lessons/what_came_in.dart';
import '../lessons/what_to_practise.dart';
import '../workspace/live_performance_screen.dart';
import '../workspace/practice_marks.dart';
import '../workspace/practice_rules.dart' show SongCount;
import '../../widgets/app_surface.dart';
import '../../widgets/bloom_tap.dart';
import '../../domain/name_policy.dart';
import '../../widgets/music_tiles.dart';
import '../../widgets/app_top_bar.dart';
import '../../widgets/text_measures.dart';
import 'new_song_flow.dart';
import 'pick_it_back_up.dart';
import 'sealed_take_card.dart';
import 'waiting_on_you.dart';
import 'tonight.dart';
import 'firsts.dart';
import '../../app/beta_config.dart';
import '../../services/app_release.dart';
import '../../services/push_registration.dart';
import '../../services/push_trouble.dart';
import '../welcome/play_later.dart';
import '../openmic/musician_profile_screen.dart';
import '../rooms/room_detail_screen.dart';
import '../rooms/setlist_detail_screen.dart';
import '../rooms/setlist_pack.dart' show setSongFacts;
import 'a_set_for_a_day.dart';
import '../workspace/song_workspace_screen.dart';
import '../../services/song_search.dart';
import '../workspace/song_analysis_screen.dart';
import '../workspace/song_reading_store.dart';
import '../workspace/song_transpose_store.dart';
import 'song_sheet_queue.dart';
import '../../services/user_facing_error.dart';
import '../../widgets/note_that_fits.dart';

/// Songs, or the sets they're grouped into for a specific occasion.
/// What the library is filtered to.
///
/// These were three tabs. Songs was everything, the Control Room was songs
/// sorted by whether their sheet existed, and Sets sat under a toggle of
/// equal weight to the whole library despite there being one of them. None of
/// those is a place — they are all the same list with a different question
/// asked of it, and a question is a chip.
/// Two kinds of thing, not six filters.
///
/// This was byRoom / all / ideas / needsSheet / hasSheet / sets — a query
/// builder wearing a segmented control, and the clearest single piece of
/// evidence that the app was laid out by whoever wrote the queries.
///
/// Of the six: "by room" is the default and is a *place*, not a filter, so
/// it stopped being a chip. "Ideas" filtered to a room that is already
/// visible as a room. "Needs a sheet" and "has a sheet" are states, which
/// is what search and the sheet queue banner are for. "Everything" is what
/// typing in the search box already gives you.
///
/// What is left is the one distinction that is not a filter at all: a song
/// and a set are different things.
enum _SongsView { songs, rooms, sets }

/// How far past its last row every list on this tab scrolls, so that row
/// can come out from under the gold record button.
///
/// The shell floats a 56 px button 16 px above the tab bar, over the bottom
/// right corner of whatever is in the tab. The lists here ended 30 px from
/// the bottom, less than the 72 the button takes up, so the last row stayed
/// partly under it with the list scrolled as far as it goes, and a list too
/// short to scroll left whatever sat in that corner covered. The audit found
/// the waveform and chevron of South Of Midnight under it (17 September
/// 2026). The button's height and both its margins, so the last row ends a
/// margin clear of it rather than touching.
const double kClearOfRecordButton = 56 + kFloatingActionButtonMargin * 2;

/// Whether [room] is the Ideas room the record button made for you, with
/// nothing in it yet.
///
/// The button files a recording that has no home in a room called Ideas,
/// and makes that room the first time it is pressed (`ideas_catalog`, 0066).
/// Backing out without a sound sweeps the song up but not the room, so one
/// brushed thumb left "Ideas · just you · Nothing in here yet" on Home for
/// good (audit, 17 September 2026). Nobody asked for that room, so Home
/// leaves it out until something lands in it. The room itself stays: the
/// next recording goes straight back into it. It keeps its name too, so a
/// new room called Ideas opens this one rather than saying the name is taken.
///
/// Recognised by what `ideas_catalog` writes, the name and the 💡, because a
/// room somebody names Ideas themselves gets the ordinary ♪ and is a place
/// they chose to make, empty or not. Yours and only yours, because a room
/// somebody else is in is somewhere two people share.
bool isUnusedIdeasRoom(MusicRoom room, {required String me}) =>
    room.projects.isEmpty &&
    room.name.trim().toLowerCase() == 'ideas' &&
    room.icon == '💡' &&
    room.accountId == me &&
    room.members.every((member) => member.userId == me);

/// Every song the user can reach, in one place.
///
/// Songs are what this app is for, and until now they had no home of their
/// own — they lived two or three taps inside whichever Room they happened to
/// be filed under, and the only way to find one was to remember where you
/// put it. Rooms still exist and still control who can see what; they're a
/// filter here rather than a place you have to visit first.
class SongsScreen extends StatefulWidget {
  const SongsScreen({
    required this.displayName,
    required this.onOpenAccount,
    required this.onOpenNotifications,
    this.onRecord,
    this.onFindMusicians,
    this.onOpenMessages,
    this.showTopBar = true,
    this.analysisService,
    this.hearSealedTake,
    super.key,
  });

  /// Where a song's sheet comes from when Perform opens from here, and
  /// where the songs kept on this phone live. Null in production; a test
  /// hands in one that answers without a network.
  final SongAnalysisService? analysisService;

  /// Plays a sealed take when its card is answered "Play it" (0158), and
  /// answers whether it is sounding.
  ///
  /// Substituted in tests, real everywhere else: the real one is the app's
  /// one player, which cannot make a sound under a widget test.
  final Future<bool> Function(SealedTake take)? hearSealedTake;

  /// For the avatar in the corner, which is also the way into the account.
  final String displayName;
  final VoidCallback onOpenAccount;
  final VoidCallback onOpenNotifications;

  /// The two doors this screen cannot open on its own: the record button
  /// lives in the shell, and finding people means changing tab.
  final VoidCallback? onRecord;
  final VoidCallback? onFindMusicians;

  /// The Messages tab, for a first step that leads there.
  final VoidCallback? onOpenMessages;

  /// False when the shell is drawing one across the top for every tab, which
  /// it does once there is width to put the destinations up there.
  final bool showTopBar;

  @override
  State<SongsScreen> createState() => _SongsScreenState();
}

class _SongsScreenState extends State<SongsScreen> {
  /// How many times somebody has asked for a different old idea today.
  ///

  final _searchController = TextEditingController();
  String _query = '';
  String? _roomFilterId;
  /// Opens on places rather than on a list.
  ///
  /// The audit was right that three tabs were three filters on one library.
  /// It was wrong to conclude the answer was one flat list — a room is not
  /// a filter, it is a *place*, and places are how people remember where
  /// things are. Every room carries an emoji, a name and a set of faces,
  /// which is everything needed to tell one from another in a second, and
  /// none of it was on this screen.
  _SongsView _view = _SongsView.songs;

  /// The song open in the pane beside the library, on a desk.
  ///
  /// Null on a phone, where opening a song is a route and this screen is not
  /// on top of it any more.
  String? _openedId;

  /// The room open in that same pane instead, if one is.
  ///
  /// One pane, two kinds of thing in it, so these are mutually exclusive —
  /// setting either clears the other. Holding both and picking a winner at
  /// build time is the version of this that eventually shows a song while
  /// the rail highlights a room.
  String? _openedRoomId;

  /// Rooms showing all of their songs rather than the first six.
  ///
  /// 'All 23 in South Dean' used to leave for the room screen, which is a
  /// different place with a different layout that answers a different
  /// question. What it was asked for is the rest of a list somebody is
  /// already reading, so now it is the rest of the list.
  final Set<String> _expandedRoomIds = <String>{};

  /// Whether there is room to show a song rather than only list it.
  ///
  /// Set by the layout builder before the body is built, the same way the
  /// shell does it, so `_open` knows which of its two behaviours it has
  /// without every caller having to be told.
  bool _desk = false;

  SongAnalysisService get _analysis => widget.analysisService ?? SongAnalysisService();

  /// The songs kept on this phone, for the small phone on their rows: what
  /// is ready for a basement, seen from the list rather than from a dozen
  /// menus opened one by one (review, 18 September 2026). Empty in a
  /// browser, which keeps nothing.
  Set<String> _keptIds = const <String>{};

  Future<void> _loadKeptIds() async {
    if (!KeptSongs.supported) return;
    final ids = await _analysis.kept.keptIds();
    if (mounted) setState(() => _keptIds = ids);
  }

  /// The grid each song with a practice card on it is counted on.
  ///
  /// Held as the grid rather than as a finished [SongCount] so that bar 1
  /// moving, or a cycle being counted, changes the cards on the way back from
  /// Perform without anything being fetched again: the grid comes from the
  /// recording and does not move, and where bar 1 is comes off the song.
  final Map<String, SongGrid> _grids = <String, SongGrid>{};

  /// Songs already asked about, answered or not, so a rebuilding strip asks
  /// once rather than once a frame.
  final Set<String> _gridsAsked = <String>{};

  /// How [song] counts itself now, or null while nothing has been read for
  /// it — in which case a practice card keeps the words its mark was kept
  /// under (see practicePassage).
  SongCount? _countOf(SongProject song) {
    final grid = _grids[song.id];
    if (grid == null || grid.isEmpty) return null;
    return SongCount.of(grid, barOne: song.barOne, cycle: song.cycle);
  }

  /// Reads the grids of the songs the strip is about to name a passage of.
  ///
  /// One request for all of them, and only for songs that have a practice
  /// card — which for most people is none at all, and that is the point:
  /// nothing is fetched for a Home with nothing to rename. Called from the
  /// build that needs them and deferred a frame, because the answer arrives
  /// as a setState.
  void _askHowTheyCount(List<SongProject> songs) {
    final wanted = <SongProject>[
      for (final song in songs)
        if (!_gridsAsked.contains(song.id)) song,
    ];
    if (wanted.isEmpty) return;
    _gridsAsked.addAll(wanted.map((song) => song.id));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadGrids(wanted.map((song) => song.id).toList()));
    });
  }

  Future<void> _loadGrids(List<String> projectIds) async {
    final grids = await _analysis.gridsFor(projectIds);
    if (!mounted || grids.isEmpty) return;
    setState(() => _grids.addAll(grids));
  }

  void _keptSongsChanged() => unawaited(_loadKeptIds());

  @override
  void initState() {
    super.initState();
    unawaited(_loadKeptIds());
    KeptSongs.changes.addListener(_keptSongsChanged);
    // After the first frame: BetaScope needs a mounted context, and the strip
    // is a convenience the screen works without.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadRequests());
      // The state that cost a week of silence was readable the whole
      // time, on a settings screen nobody opens. Read it where people
      // actually are instead.
      if (mounted) unawaited(_checkPush());
    });
    // The server's answer about this build arrives after the first frame;
    // the strip redraws when it does.
    AppRelease.minimum.addListener(_releaseChanged);
    // Whether somebody said "not now" to playing something, read from the
    // device before the strip decides what is waiting.
    unawaited(PlayLater.load().then((_) {
      if (mounted) setState(() {});
    }));
    // The keys songs are kept in on this phone, and the parts they are read
    // for, for the Tonight card. The strip listens for both, so there is
    // nothing to redraw here.
    unawaited(SongTransposeStore.warm());
    unawaited(SongReadingStore.warm());
  }

  @override
  void dispose() {
    AppRelease.minimum.removeListener(_releaseChanged);
    KeptSongs.changes.removeListener(_keptSongsChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _releaseChanged() {
    if (mounted) setState(() {});
  }

  /// What to actually do about it, on this phone.
  Future<void> _checkPush() async {
    final trouble = await PushRegistration.troubleOnThisPhone();
    if (mounted) setState(() => _pushTrouble = trouble);
  }

  /// One tap where one tap is enough, and honest words where it is not.
  ///
  /// Asking again works until somebody has hard-refused twice, after
  /// which Android stops showing the dialog at all and only the system
  /// settings page can turn it back on. A button that silently does
  /// nothing is the thing this screen exists to avoid, so when the ask
  /// cannot land this says where to go instead of pretending.
  Future<void> _fixPush(PushTrouble trouble) async {
    if (trouble.kind == PushTroubleKind.switchedOff) {
      final allowed = await PushRegistration.enable();
      if (!mounted) return;
      if (allowed) {
        await _checkPush();
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Turn notifications back on'),
          content: const Text(
            'Your phone will not show the request again, so it has to be '
            'done in its own settings:\n\n'
            'Settings, Apps, CoLabRoom, Notifications, and turn them '
            'on.\n\n'
            'While you are there, set Battery to Unrestricted. Phones '
            'switch notifications off again for apps they decide are '
            'unused.',
          ),
          actions: <Widget>[
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      await _checkPush();
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Your phone is holding the app asleep'),
        content: const Text(
          'Notifications are allowed, they were sent, and this phone '
          'drew none of them. That is the phone saving battery rather '
          'than anything in the app:\n\n'
          'Settings, Apps, CoLabRoom, Battery, set it to Unrestricted.\n\n'
          'On Samsung, also take CoLabRoom out of Deep sleeping apps, '
          'and turn off the setting that removes permissions from '
          'unused apps.',
        ),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _howToUpdate() async {
    final oldest = AppRelease.minimum.value ?? '';
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Get the newer build'),
        content: Text(
          '${AppRelease.howToUpdate}\n\n'
          'This phone has ${BetaConfig.appVersion}. Afterwards, the Account '
          'screen should say $oldest or later.',
        ),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _open(SongProject project) {
    // On a desk the song opens *beside* the library rather than on top of it.
    //
    // This is the whole difference between a web app and a phone in a frame.
    // A phone hides everything except the one thing you are looking at,
    // because that is all that fits; a screen with room shows the list and
    // the thing at once, and moving between songs stops being a push and a
    // pop and becomes a click.
    if (_desk) {
      setState(() {
        _openedId = project.id;
        _openedRoomId = null;
      });
      // The address bar still has to follow, or the back button and a shared
      // link both stop meaning anything on the one platform where people
      // expect them to work.
      CurrentRoute.enter(AppRoutes.song(project.id));
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: RouteSettings(name: AppRoutes.song(project.id)),
        builder: (_) => SongWorkspaceScreen(projectId: project.id),
      ),
    );
  }

  /// The paid room, still a room — just not a shelf you always see.
  ///
  /// The argument for the Control Room as a tab was that separate rooms
  /// explain a price better than a badge. That is about the door you walk
  /// through, not the tab you never tap: this opens it, with the depth choice
  /// and the cost on the other side.
  void _openSheet(SongProject project) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'Song sheet'),
        builder: (_) => SongAnalysisScreen(project: project),
      ),
    );
  }

  /// The room itself — members, invites, sets, the running order.
  ///
  /// Beside the library on a desk rather than on top of it, for the same
  /// reason a song is: the list is the thing you navigate by, and a layout
  /// that throws it away every time you look at a room is a layout you have
  /// to keep rebuilding in your head.
  void _openRoom(MusicRoom room) {
    if (_desk) {
      setState(() {
        _openedRoomId = room.id;
        _openedId = null;
      });
      // A real address, not the word 'Room'. Every other pane in this layout
      // puts something in the bar you could paste to somebody.
      CurrentRoute.enter(AppRoutes.room(room.id));
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'Room'),
        builder: (_) => RoomDetailScreen(roomId: room.id),
      ),
    );
  }

  void _openSet(Setlist setlist) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: RouteSettings(name: AppRoutes.setlist(setlist.id)),
        builder: (_) => SetlistDetailScreen(setlistId: setlist.id),
      ),
    );
  }

  /// Connection requests waiting on an answer, loaded once when this screen
  /// opens. Empty until they arrive, which is the right default: a strip that
  /// guessed would flicker.
  List<Connection> _requests = const <Connection>[];

  /// Whether this phone has quietly stopped being able to show
  /// notifications.
  ///
  /// Null until the check has run, and null again whenever there is
  /// nothing to say, which is almost always. See push_trouble.dart.
  PushTrouble? _pushTrouble;

  Future<void> _loadRequests() async {
    try {
      final all = await BetaScope.of(context, listen: false)
          .repository
          .listConnections();
      if (!mounted) return;
      setState(() => _requests =
          all.where((c) => !c.accepted && c.incoming).toList(growable: false));
    } catch (_) {
      // The strip is a convenience over screens that all work without it.
      // A failure here must not be the reason somebody cannot see their songs.
    }
  }

  Future<void> _openPerson(String personId) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'Musician'),
      builder: (_) => MusicianProfileScreen(
        profileId: personId,
        repository: BetaScope.of(context, listen: false).repository,
      ),
    ));
    if (mounted) await _loadRequests();
  }

  void _openProjectById(String projectId) {
    for (final room in BetaScope.of(context, listen: false).rooms) {
      for (final project in room.projects) {
        if (project.id == projectId) {
          _open(project);
          return;
        }
      }
    }
  }

  /// Everything that wants something from you, gathered from wherever it
  /// lives.
  ///
  /// Ordered by who is waiting. A person who has asked to connect is waiting
  /// on an answer; a song that has been sitting for a fortnight is not
  /// waiting on anything and will still be there tomorrow. Anything somebody
  /// has closed is gone from here for good -- see [SetAside].
  List<WaitingItem> _waiting() {
    final controller = BetaScope.of(context);
    final items = <WaitingItem>[];

    // Something new for today -- every card that is due, each its own.
    // Closing one closes exactly that one, and nothing steps out from
    // behind it: Taylor wants them "all being there scrollable ... without
    // anything being buried".
    final tonightSong = controller.tonight.song;
    final tonightCards = composeTonightCards(
      today: DateTime.now(),
      releases: controller.releases,
      song: tonightSong,
      prompt: controller.tonight.prompt,
      firsts: firstsFor(
        me: controller.repository.currentUserId,
        rooms: controller.rooms,
        threads: controller.threads,
      ),
      seen: (id) => SetAside.has(SetAside.tonight, id),
      // The key the song's sheet opens in on this phone, so the chord the
      // card suggests is the one the sheet will show. The instrument's part
      // goes with it: a trumpet player's sheet opens a tone up from the
      // band's key, and a card naming the band's chord would send them to a
      // page that has never heard of it (review, 17 September 2026).
      songTranspose: tonightSong == null
          ? 0
          : SongTransposeStore.held(tonightSong.projectId) +
              SongReadingStore.held(tonightSong.projectId).semitones,
    );
    for (final tonight in tonightCards) {
      items.add(WaitingItem(
        id: 'tonight-${tonight.id}',
        kind: WaitingKind.tonight,
        eyebrow: switch (tonight.kind) {
          TonightKind.whatChanged => 'New this week',
          TonightKind.firstStep => 'Now you can',
          TonightKind.chordMove => 'Tonight · a chord',
          TonightKind.firstLine => 'Tonight · a first line',
          TonightKind.challenge => 'Tonight · a challenge',
        },
        line: tonight.title,
        detail: tonight.body,
        actionLabel: tonight.cta,
        onAction: () => unawaited(_doTonight(tonight)),
        onDismiss: () => unawaited(_setAside(SetAside.tonight, tonight.id)),
      ));
    }

    final me = controller.meOrNobody;

    // What a teacher asked for with a song they sent (0150): the passage,
    // the speed and when by, in the practice card's own grammar, because to
    // the student it is the same thing -- something to practise, from
    // somebody. It says nothing about when it was asked and counts down to
    // nothing; "before Thursday" is the teacher's words and only words.
    // What they are listening for is on the song, where there is room.
    final briefed = <String>{};
    for (final brief in briefsAskedOf(me, controller.songBriefs)) {
      if (briefed.contains(brief.projectId)) continue;
      if (SetAside.has(SetAside.practice, brief.id)) continue;
      final song = _songById(controller, brief.projectId);
      if (song == null) continue;
      briefed.add(brief.projectId);
      items.add(WaitingItem(
        id: 'brief-${brief.id}',
        kind: WaitingKind.practice,
        who: brief.teacherName,
        eyebrow: briefFrom(brief, me: me),
        line: song.title,
        detail: songBriefSaid(brief),
        actionLabel: 'Practise',
        onAction: () => unawaited(_practise(song, brief.part)),
        // Closed on this phone and nowhere else: nothing tells the teacher.
        onDismiss: () => unawaited(_setAside(SetAside.practice, brief.id)),
      ));
    }

    // What a lesson left to practise, or what this person last worked on by
    // themselves. One card a song, the latest — except that words outlast
    // work; see _cardMark.
    final practised = <String>{};
    final toCount = <SongProject>[];
    for (final newest in controller.practiceMarks) {
      if (practised.contains(newest.projectId)) continue;
      if (SetAside.has(SetAside.practice, newest.id)) continue;
      final song = _songById(controller, newest.projectId);
      if (song == null) continue;
      practised.add(newest.projectId);
      toCount.add(song);
      final mark = _cardMark(controller, newest);
      // Practising from a brief's card keeps this person's own mark on the
      // song, like any other practice, and a second card beside the brief
      // saying the same passage at the same speed is the row repeating
      // itself. The brief stands for the song while it is there; a mark that
      // carries somebody's words is a different thing said and keeps its
      // card. Nothing is lost: the mark is still kept.
      if (briefed.contains(mark.projectId) && isYourOwnPractice(mark, me: me)) continue;
      // Named by how the song counts itself now, not by the words the mark
      // was kept under: see practicePassage, and _countOf for where the
      // counting comes from.
      final worked = practiceWorked(mark, counted: _countOf(song));
      final note = mark.note;
      final mine = isYourOwnPractice(mark, me: me);
      items.add(WaitingItem(
        id: 'practice-${mark.id}',
        kind: WaitingKind.practice,
        // Your own practice draws the repeat icon rather than your own face:
        // a card about what you did is not a card about somebody.
        who: mine ? null : mark.ledByName,
        eyebrow: practiceFrom(mark, me: me),
        line: song.title,
        detail: <String>[
          if (worked != null) worked,
          if (note != null) '“$note”',
        ].join(' · '),
        actionLabel: 'Practise',
        onAction: () => unawaited(_practise(song, mark.lead)),
        onDismiss: () => unawaited(_setAside(SetAside.practice, mark.id)),
      ));
    }
    _askHowTheyCount(toCount);

    // What a student sent their teacher (0151). One card, however many
    // came in: nine cards for nine students would be the strip turning into
    // an inbox, and the desk itself is the list. It names the newest
    // arrival, because that is the one the teacher has not heard.
    //
    // Closed by every take that was on the desk at the time, not only by the
    // newest one: once a teacher has been to the desk they have seen all of
    // it. Closing only the newest means that when that take is deleted --
    // a student re-recording it -- the one behind it has never been set
    // aside, and Home says "what came in" about something heard last week.
    // A hand-in that arrives after this is a new id and a new card.
    final newest = controller.sentTakes.lastOrNull;
    if (newest != null && !SetAside.has(SetAside.cameIn, newest.takeId)) {
      final heard = <String>[
        for (final take in controller.sentTakes) take.takeId,
      ];
      items.add(WaitingItem(
        id: 'came-in-${newest.takeId}',
        kind: WaitingKind.cameIn,
        who: newest.studentName,
        line: newest.songTitle,
        actionLabel: 'Listen',
        onAction: () => unawaited(_openWhatCameIn(heard)),
        onDismiss: () => unawaited(_setAsideAll(SetAside.cameIn, heard)),
      ));
    }

    // The set somebody is playing on this week (0164). One quiet card, from
    // a week out until the day has gone by, for everybody in the room and
    // not only for whoever made the set.
    //
    // No push and no reminder: it is here when the app is opened and nowhere
    // else. Nothing is written when it is opened, so there is no answer to
    // give a leader who wants to know who has looked at Sunday.
    final today = DateTime.now();
    for (final set in setsForTheWeek(controller.setsForTheDay, today)) {
      // A card with nothing behind it does nothing when it is tapped. The
      // server hands back only the songs from rooms this person is in, so
      // this is the library on this phone not having caught up rather than
      // a set they cannot see.
      if (!set.projectIds.any((id) => _songById(controller, id) != null)) {
        continue;
      }
      items.add(setForDayCard(
        set,
        today: today,
        onOpen: () => unawaited(_performSet(set)),
      ));
    }

    // A take sealed for later, on the day it comes back (0158). One quiet
    // card, and either answer is the last of it.
    for (final sealed in controller.sealedTakesDue) {
      items.add(sealedTakeCard(
        sealed,
        now: DateTime.now(),
        onPlay: () => unawaited(_hearSealed(sealed)),
        onNotNow: () => unawaited(controller.endSeal(sealed)),
      ));
    }

    // People first. Somebody is on the other end of this one.
    for (final person in _requests) {
      items.add(WaitingItem(
        id: 'request-${person.personId}',
        kind: WaitingKind.request,
        who: person.displayName,
        whoAvatarPath: person.avatarPath,
        at: person.since,
        // The card already says "Wants to connect" above the name and draws
        // their face beside it, so the sentence would have been the third
        // time in four inches.
        line: person.displayName,
        actionLabel: 'See who',
        onAction: () => unawaited(_openPerson(person.personId)),
      ));
    }

    // This phone, if it has fallen behind. Above the chores because the
    // person who just asked to connect may be waiting on a screen this build
    // does not have. The x hides it for the session -- there is no permanent
    // no to "you are out of date", only an update.
    // The app saying it cannot reach you, which nothing else here can
    // say. No permanent dismiss: there is no meaningful no to being
    // unreachable, only turning it back on, and the card goes by itself
    // once it is.
    final trouble = _pushTrouble;
    if (trouble != null) {
      items.add(WaitingItem(
        id: 'unreachable-' + trouble.kind.name,
        kind: WaitingKind.unreachable,
        line: trouble.line,
        detail: trouble.detail,
        actionLabel: trouble.actionLabel,
        onAction: () => unawaited(_fixPush(trouble)),
      ));
    }

    if (AppRelease.isStale) {
      items.add(WaitingItem(
        id: 'update-${AppRelease.minimum.value}',
        kind: WaitingKind.update,
        line: 'A newer CoLabRoom is waiting',
        detail: 'This phone has ${BetaConfig.appVersion}',
        actionLabel: 'How',
        onAction: () => unawaited(_howToUpdate()),
      ));
    }

    // The offer somebody was too busy for on their first launch, kept for a
    // later one. Gone by itself the moment there is any recording; gone for
    // good when closed. The verb is the gold button's, from here.
    final onRecord = widget.onRecord;
    final hasAnyRecording = controller.rooms
        .any((room) => room.projects.any((song) => song.hasAudioReference));
    if (onRecord != null && PlayLater.shouldRemind(hasAnyRecording: hasAnyRecording)) {
      items.add(WaitingItem(
        id: 'first-take',
        kind: WaitingKind.firstTake,
        line: 'Play something',
        detail: 'Twenty seconds is enough',
        actionLabel: 'Record',
        onAction: onRecord,
        onDismiss: () => unawaited(_setAside(SetAside.playLater, 'first')),
      ));
    }

    // Every recording with no sheet, a card each. It used to be one at a
    // time, so closing it only brought the next song out from behind.
    final queue = SongSheetQueue.from(controller.rooms)
        .without(SetAside.of(SetAside.songSheet));
    // The queue keeps its lead apart from the rest of the waiting pile, so
    // the lead goes back at the front of it.
    final lead = queue.lead;
    final unwritten = <SheetQueueEntry>[
      if (lead != null && !queue.leadIsSheet) lead,
      ...queue.waiting,
    ];
    for (final waiting in unwritten) {
      items.add(WaitingItem(
        id: 'sheet-${waiting.project.id}',
        kind: WaitingKind.sheet,
        line: waiting.project.title,
        detail: 'Recorded, not written down',
        actionLabel: 'Make it',
        onAction: () => _openSheet(waiting.project),
        onDismiss: () =>
            unawaited(_setAside(SetAside.songSheet, waiting.project.id)),
      ));
    }

    // Every song you left, a card each, the longest-left first. Closing one
    // stops that song being offered and brings nothing out in its place.
    final leftSongs = PickItBackUp.all(<SongProject>[
      for (final room in controller.rooms)
        for (final project in room.projects)
          if (!SetAside.has(SetAside.pickItBackUp, project.id)) project,
    ]);
    for (final left in leftSongs) {
      items.add(WaitingItem(
        id: 'left-${left.song.id}',
        kind: WaitingKind.unfinished,
        // The song's name is the thing being talked about, and it was the one
        // word the card before last left out of its own heading. When it was
        // left goes in the eyebrow, so the title gets the whole line and what
        // the app already knows about it gets the one underneath — which is
        // the actual reason to come back.
        eyebrow: left.when.replaceFirst('You left this ', 'Left '),
        line: left.song.title,
        detail: left.knownBriefly,
        actionLabel: 'Open',
        onAction: () => _open(left.song),
        onDismiss: () =>
            unawaited(_setAside(SetAside.pickItBackUp, left.song.id)),
      ));
    }

    // And what other people did. Last, because it is news rather than a
    // request -- nobody is waiting on you to read it.
    for (final entry in controller.activity) {
      final id = 'news-${entry.id}';
      if (SetAside.has(SetAside.pickItBackUp, id)) continue;
      items.add(WaitingItem(
        id: id,
        kind: WaitingKind.news,
        who: entry.actorName ?? 'Somebody',
        whoAvatarPath: entry.actorAvatarPath,
        about: entry.projectTitle,
        at: entry.at,
        // Carried through so the card can play it rather than describe it.
        audioPath: entry.audioPath,
        audioMs: entry.audioMs,
        // What kind of news it is, above the sentence. "New take" and "New
        // message" are both somebody doing something on your song, and only
        // one of them is worth putting headphones on for.
        eyebrow: switch (entry.kind) {
          ActivityKind.recording => 'New take',
          ActivityKind.message => 'New message',
          ActivityKind.analyzed => 'Song sheet ready',
          ActivityKind.joined => 'Joined the room',
          ActivityKind.edited => 'Edited',
        },
        line: entry.sentence,
        // What the thing actually is, so the button is worth pressing. "Hear
        // it" is a different invitation from "Open".
        actionLabel: switch (entry.kind) {
          ActivityKind.recording => 'Hear it',
          ActivityKind.message => 'Read it',
          ActivityKind.analyzed => 'See the sheet',
          _ => 'Open',
        },
        onAction: () => _openProjectById(entry.projectId),
        onDismiss: () => unawaited(_setAside(SetAside.pickItBackUp, id)),
      ));
    }

    return items;
  }

  /// "Play it", on a sealed take's card.
  ///
  /// Every Musician, Same Song, 17 September 2026. It plays here, through the
  /// one player the app shares, so the bar at the bottom carries it while the
  /// card goes: playing it is an answer, the seal ends with it, and the take
  /// is back among the song's takes -- which is what the bar's second line
  /// says, because after a year that is not obvious. No song id goes with it:
  /// the bar opens a song's public page and counts a listen, and neither is
  /// true of a private idea.
  Future<void> _hearSealed(SealedTake take) async {
    final controller = BetaScope.of(context, listen: false);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final hear = widget.hearSealedTake ?? _playSealed;
    // Started before the seal ends: the sound should not queue behind a
    // round trip, and its path is signed for this person whether the take is
    // sealed or not. The seal does not wait for the sound either.
    final sounding = hear(take);
    final ending = controller.endSeal(take);
    var heard = false;
    try {
      heard = await sounding;
    } catch (_) {
      // The same as a take that would not start.
    }
    if (heard) return;
    // The player fails quietly by design: no bar, no message. Here that left
    // the card gone, no sound, and nothing anywhere saying what became of an
    // idea kept for a year. The bar's second line is the only other place
    // that says where the take went, and it is only there when it plays.
    //
    // Which words depends on whether the seal ended, so this one path waits
    // to find out. With no signal at all neither call gets through, the take
    // is still sealed, and saying it was back in the song would send them
    // looking for something that is not there.
    final ended = await ending;
    messenger?.showNote(ended ? sealedTakeIsBackWords(take) : sealedTakeWillBeOfferedAgainWords);
  }

  /// The app's one player, and whether the take is the thing it now has.
  static Future<bool> _playSealed(SealedTake take) async {
    await NowPlaying.instance.play(
      take.storagePath,
      knownLength:
          take.durationMs > 0 ? Duration(milliseconds: take.durationMs) : null,
      title: take.songTitle,
      byline: 'Back among your takes',
    );
    return NowPlaying.instance.isCurrent(take.storagePath);
  }

  /// Doing what the Tonight card asks. A first line opens the recorder; a
  /// chord move opens the song; a challenge opens the song you left or
  /// the first one you have; a release is read and closed.
  Future<void> _doTonight(TonightCard card) async {
    final controller = BetaScope.of(context, listen: false);
    switch (card.kind) {
      case TonightKind.whatChanged:
        await _setAside(SetAside.tonight, card.id);
      case TonightKind.firstStep:
        // Shown once: going is the same as having seen it.
        await _setAside(SetAside.tonight, card.id);
        if (!mounted) return;
        switch (card.go) {
          case FirstGo.openSong:
            final id = card.projectId;
            if (id != null) _openProjectById(id);
          case FirstGo.record:
            // "Sing Midnight Signal once" is about Midnight Signal. It went to
            // the Record button, which starts a new idea, so the take landed
            // in "Idea 2" and the song it named still had no sheet (audit,
            // 17 September 2026).
            final named = card.projectId == null ? null : _songById(controller, card.projectId!);
            if (named != null) {
              await Navigator.of(context).push(MaterialPageRoute<void>(
                settings: const RouteSettings(name: 'Song sheet'),
                builder: (_) => SongAnalysisScreen(project: named, autoRecord: true),
              ));
              break;
            }
            final record = widget.onRecord;
            if (record != null) {
              record();
            } else {
              await showNewSongFlow(context, controller);
            }
          case FirstGo.messages:
            widget.onOpenMessages?.call();
          case FirstGo.openMic:
            widget.onFindMusicians?.call();
          case null:
            break;
        }
      case TonightKind.chordMove:
        final id = card.projectId;
        if (id != null) _openProjectById(id);
      case TonightKind.firstLine:
        final record = widget.onRecord;
        if (record != null) {
          record();
        } else {
          await showNewSongFlow(context, controller);
        }
      case TonightKind.challenge:
        final left = PickItBackUp.choose(<SongProject>[
          for (final room in controller.rooms) ...room.projects,
        ]);
        final song = left?.song ??
            controller.rooms
                .expand((room) => room.projects)
                .cast<SongProject?>()
                .firstWhere((_) => true, orElse: () => null);
        if (song != null) {
          _open(song);
        } else {
          final record = widget.onRecord;
          if (record != null) record();
        }
    }
  }

  /// Which of a song's practice marks its one card is built from.
  ///
  /// Newest wins, except that words outlast work. Practising alone keeps a
  /// mark with no note on it — nobody said anything — and the minutes most
  /// likely to be spent practising alone are the ones straight after a
  /// lesson, on the screen that is already open. Newest-wins alone would
  /// therefore take "keep it slow until the change is clean" off Home at the
  /// exact moment the student did what they were told to do, and the teacher
  /// would have said it to nobody. So a mark that carries words is shown
  /// ahead of a wordless newer one on the same song (Every Musician, Same
  /// Song, 17 September 2026). Nothing of the person's own work is lost by
  /// it: the part and the speed the card offers back are the ones to
  /// practise either way, and the mark itself is still kept.
  PracticeMark _cardMark(MusicBetaController controller, PracticeMark newest) {
    if ((newest.note ?? '').trim().isNotEmpty) return newest;
    for (final mark in controller.practiceMarks) {
      if (mark.projectId != newest.projectId) continue;
      if (SetAside.has(SetAside.practice, mark.id)) continue;
      if ((mark.note ?? '').trim().isNotEmpty) return mark;
    }
    return newest;
  }

  SongProject? _songById(MusicBetaController controller, String projectId) {
    for (final room in controller.rooms) {
      for (final project in room.projects) {
        if (project.id == projectId) return project;
      }
    }
    return null;
  }

  /// Straight to the part and the speed the lesson worked on, or the ones a
  /// teacher's brief asked for (0150), with the song not yet playing: the
  /// student decides when to start.
  ///
  /// And what is done here is kept, like any other practice. The card whose
  /// only verb is Practise would be a strange door to walk through and leave
  /// no trace, when the same half hour opened from the song leaves one
  /// (Every Musician, Same Song, 17 September 2026).
  Future<void> _practise(SongProject song, PracticePart? part) async {
    // Held before the push rather than looked up on the way back: this screen
    // can be rebuilt away while Perform is open.
    final controller = BetaScope.of(context, listen: false);
    final me = controller.meOrNobody;
    // The sheet as the server has it, or as this phone kept it, or a word
    // about why neither -- the same door the song itself opens Perform by.
    final sheet = await _analysis.sheetForPerform(song);
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        settings: RouteSettings(name: AppRoutes.songLive(song.id)),
        builder: (_) => LivePerformanceScreen(
          project: song,
          analysis: sheet.bundle,
          missing: sheet.missing,
          analysisService: widget.analysisService,
          practise: part,
          me: me,
          ownMarkId: ownPracticeMarkId(controller.practiceMarks, projectId: song.id, me: me),
          keepPractice: (worked) => unawaited(controller.keepPracticeMark(worked)),
          // Where bar 1 is, when this person is one of the two who may say it
          // (0161). A student practising somebody else's song counts from the
          // bars the room counts, and is offered no way to move them.
          onSayBarOne:
              (controller.roomById(song.roomId)?.canEditSongs(me) ?? false)
                  ? (downbeat) async {
                      await controller.repository.setBarOne(song.id, downbeat);
                      await controller.refreshProject(song.id);
                    }
                  : null,
          // And the cycle the band counts, on the same terms (0162).
          onCountCycle:
              (controller.roomById(song.roomId)?.canEditSongs(me) ?? false)
                  ? (cycle) async {
                      await controller.repository.setSongCycle(song.id, cycle);
                      await controller.refreshProject(song.id);
                    }
                  : null,
        ),
        fullscreenDialog: true,
      ),
    );
  }

  /// The set for the day, from its card on Home (0164).
  ///
  /// Its songs in the running order, each in the key the set does it in, one
  /// Perform at a time: "Next" in the top bar comes back with true and opens
  /// the song after this one, and the x comes back with nothing and that is
  /// the end of the set. Songs from rooms this person is not in never arrive
  /// here to be opened, and a song this phone has not loaded is passed over
  /// rather than opening an empty screen.
  ///
  /// Nothing is kept. Practising from a card keeps a practice mark, and a
  /// set of eight songs would put eight more cards on Home for a week —
  /// which is the row turning into the "what you have not done yet" list
  /// this app does not have. Nothing tells the person who made the set
  /// either: there is no row to write.
  ///
  /// And no way to move bar 1 from here (0161). Most of a Sunday band can
  /// only look at these songs, and where bar 1 is belongs to the room rather
  /// than to the occasion — it is said on the song, by somebody who may
  /// write on it.
  Future<void> _performSet(Setlist set) async {
    // One set at a time. The card is on Home, and Home is what the player is
    // looking at while the first song's sheet is being read, so a second tap
    // there would otherwise start a second walk through the same set and
    // stack its Perform under this one.
    if (_walkingASet) return;
    _walkingASet = true;
    final controller = BetaScope.of(context, listen: false);
    final me = controller.meOrNobody;
    final songs = <SongProject>[];
    for (final id in set.projectIds) {
      final song = _songById(controller, id);
      if (song != null) songs.add(song);
    }
    // The next song's sheet, asked for while this one is still on the
    // screen. sheetForPerform is a read over the network, and asking for it
    // only once Perform has closed drops the player onto Home for as long as
    // it takes — on a church wifi that is a second or three of looking at
    // the wrong screen in the middle of a set, wondering whether it ended.
    Future<PerformSheet>? ahead;
    try {
      for (var index = 0; index < songs.length; index += 1) {
        final song = songs[index];
        // The sheet as the server has it, or as this phone kept it, or a word
        // about why neither — the same door every other way into Perform uses,
        // which is also what makes the set work in a basement once it has been
        // kept on this phone.
        final sheet = await (ahead ?? _analysis.sheetForPerform(song));
        if (!mounted) return;
        ahead = index + 1 < songs.length
            ? _analysis.sheetForPerform(songs[index + 1])
            : null;
        final entry = set.songFor(song.id);
        // Read through the one call the set's screen and its printed pack read
        // the key through, so the page on the stand and the screen in somebody's
        // hand cannot disagree about what key Sunday is in. Null when the set
        // says nothing about the song, which leaves this phone's own key alone:
        // an undated preference of the singer's is not overruled by silence.
        final facts = setSongFacts(entry, song, sheet.bundle);
        final onward = await Navigator.of(context).push<bool>(
          MaterialPageRoute<bool>(
            settings: RouteSettings(name: AppRoutes.songLive(song.id)),
            builder: (_) => LivePerformanceScreen(
              project: song,
              analysis: sheet.bundle,
              missing: sheet.missing,
              analysisService: widget.analysisService,
              me: me,
              transpose: entry?.key == null ? null : facts.transpose,
              nextInSet:
                  index + 1 < songs.length ? songs[index + 1].title : null,
            ),
            fullscreenDialog: true,
          ),
        );
        if (onward != true || !mounted) return;
      }
    } finally {
      _walkingASet = false;
      // A sheet asked for ahead of a set that has since been closed: nobody
      // is going to open it, so its answer is dropped here rather than left
      // to surface later as a failure nothing is waiting on.
      final abandoned = ahead;
      if (abandoned != null) {
        unawaited(abandoned.then((_) {}, onError: (_) {}));
      }
    }
  }

  /// Whether a set for a day is being walked through right now (0164).
  bool _walkingASet = false;

  /// The listening desk (0151), from the card that says something arrived.
  ///
  /// Opening it answers the card, the way a hint is answered by being
  /// tapped: the teacher has been shown what came in, so the same card
  /// waiting when they come back would be the app asking again. Something
  /// newer arriving is a new id and a new card. Kept on this phone and
  /// nowhere else -- nothing here tells a student their take has been
  /// opened, and nothing ever will.
  Future<void> _openWhatCameIn(List<String> heard) async {
    final controller = BetaScope.of(context, listen: false);
    await _setAsideAll(SetAside.cameIn, heard);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'What came in'),
      builder: (_) => WhatCameInScreen(repository: controller.repository),
    ));
  }

  /// Said no, and remembered.
  Future<void> _setAside(String kind, String id) async {
    await SetAside.add(kind, id);
    if (mounted) setState(() {});
  }

  /// The same, for a card that answers for a handful of things at once.
  Future<void> _setAsideAll(String kind, List<String> ids) async {
    for (final id in ids) {
      await SetAside.add(kind, id);
    }
    if (mounted) setState(() {});
  }

  Future<void> _newSong() async {
    final controller = BetaScope.of(context);
    final project = await showNewSongFlow(context, controller);
    if (project != null && mounted) _open(project);
  }

  /// A room of its own, without having to be making a song first.
  ///
  /// Somebody setting up a space for their band is not writing a song at
  /// that moment, and making them start one to get a room is the wrong way
  /// round.
  Future<void> _newRoom() async {
    final controller = BetaScope.of(context, listen: false);
    final me = controller.repository.currentUserId;
    final room = await showCreateRoomDialog(
      context,
      controller,
      // The empty Ideas room this tab leaves out still holds the name Ideas.
      unseen: controller.rooms
          .where((room) => isUnusedIdeasRoom(room, me: me))
          .toList(growable: false),
    );
    if (room == null || !mounted) return;
    _openRoom(room);
  }

  Future<void> _newSet() async {
    final controller = BetaScope.of(context);
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _NewSetDialog(),
    );
    final cleaned = NamePolicy.clean(name ?? '');
    if (cleaned.isEmpty || !mounted) return;
    try {
      final setlist = await controller.createSetlist(cleaned);
      // Straight into the set so the next thing is adding songs, rather than
      // leaving an empty set sitting in a list.
      if (mounted) _openSet(setlist);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showNote(
          reportAndDescribe(error, service: 'app', route: 'Songs'),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Below this, a song is a route. Above it, a song is a pane.
    //
    // 1100 rather than the shell's 900: the library needs 400 and a song
    // needs a readable measure beside it, and at 1000 the song would get
    // less than a phone gives it — which is worse than the push it replaced.
    return LayoutBuilder(
      builder: (context, constraints) {
        final desk = constraints.maxWidth >= 1100;
        // Set before the body is built, so `_open` knows which of its two
        // behaviours it has without every caller being told.
        _desk = desk;
        if (!desk) return _library(context);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(width: 400, child: _library(context)),
            const VerticalDivider(width: 1, color: AppColors.line),
            Expanded(child: _openSong(context)),
          ],
        );
      },
    );
  }

  /// The song showing beside the library.
  ///
  /// Falls back to the most recently touched one rather than to an empty
  /// pane. A desk that opens on "pick something" has spent two thirds of a
  /// monitor asking a question, which is the exact complaint this layout is
  /// answering — and the answer is almost always the song you were last in.
  Widget _openSong(BuildContext context) {
    final controller = BetaScope.of(context);

    // A room in the pane wins, because putting it there was the last thing
    // asked for. It keeps its own Scaffold and loses only its back arrow —
    // there is nothing behind it to go back to.
    final roomId = _openedRoomId;
    if (roomId != null &&
        controller.rooms.any((room) => room.id == roomId)) {
      return RoomDetailScreen(
        key: ValueKey<String>('room-$roomId'),
        roomId: roomId,
        embedded: true,
        // Straight into the pane the room is sitting in. Without this the
        // room pushes a full-screen song over a two-pane layout, which is
        // the exact jump that made this screen feel like two apps.
        onOpenSong: _open,
      );
    }

    final projects = controller.rooms
        .expand((room) => room.projects)
        .toList(growable: false)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    if (projects.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Text(
            'Your songs will open here.',
            style: TextStyle(color: AppColors.muted, fontSize: 15),
          ),
        ),
      );
    }

    // The opened one, if it still exists — a song can be deleted from the
    // list on the left while it is the thing on the right.
    final opened = _openedId == null
        ? null
        : projects.where((p) => p.id == _openedId).firstOrNull;
    final showing = opened ?? projects.first;

    return SongWorkspaceScreen(
      // Keyed by song, so switching songs rebuilds the workspace rather than
      // handing the new song the old one's editor state.
      key: ValueKey<String>(showing.id),
      projectId: showing.id,
      embedded: true,
    );
  }

  /// The name of the tab, and the one button beside it.
  ///
  /// Side by side while the two fit, and the button under the title when they
  /// do not. Every Musician, Same Song, 17 September 2026: the phone's own
  /// text size is honoured, never clamped — and at the largest one there was
  /// room for about six characters of a two-word heading, so the tab somebody
  /// was standing on announced itself as "Your m…". Given the whole width
  /// instead, the words are simply there.
  ///
  /// The switch is at 1.5 rather than at the first pixel of trouble. Below it
  /// nothing about this header moves, which is most phones, and a heading
  /// that reshuffles itself because somebody nudged their text size one step
  /// is worse than either layout.
  Widget _titleAndNew(BuildContext context) {
    Widget title(int lines) => Text(
          'Your music',
          maxLines: lines,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.displaySmall,
        );
    // One button, three things, and the third is the point.
    //
    // Making a room was only possible inside the new-song flow — pick a room,
    // or create one without leaving. So the concept this app is named after
    // had no front door: you could only make a room as a step on the way to
    // making a song, which is exactly backwards for somebody setting up a
    // space for their band.
    //
    // It also drops an oddity: the button changed its own label depending on
    // which segment was showing, so what "+" did depended on where you had
    // last tapped.
    final newThing = MenuAnchor(
      builder: (context, controller, _) => FilledButton.icon(
        key: const Key('songs_new_button'),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.add_rounded, size: 20),
        label: const Text('New'),
      ),
      menuChildren: <Widget>[
        MenuItemButton(
          leadingIcon: const Icon(Icons.music_note_rounded, size: 19),
          onPressed: () => unawaited(_newSong()),
          child: const Text('Song'),
        ),
        MenuItemButton(
          key: const Key('songs_new_room'),
          leadingIcon: const Icon(Icons.meeting_room_outlined, size: 19),
          onPressed: () => unawaited(_newRoom()),
          child: const Text('Room'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.queue_music_rounded, size: 19),
          onPressed: () => unawaited(_newSet()),
          child: const Text('Set'),
        ),
      ],
    );

    if (textGrowth(context, 30) < 1.5) {
      // One line beside the button, as it has always been.
      return Row(
        children: <Widget>[Expanded(child: title(1)), newThing],
      );
    }
    // The whole width, and two lines if the heading needs them.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        title(2),
        const SizedBox(height: 8),
        newThing,
      ],
    );
  }

  Widget _library(BuildContext context) {
    final controller = BetaScope.of(context);
    // Without the Ideas room the record button left behind empty. Every
    // other room shows, empty or not. See isUnusedIdeasRoom.
    final me = controller.repository.currentUserId;
    final rooms = controller.rooms
        .where((room) => !isUnusedIdeasRoom(room, me: me))
        .toList(growable: false);
    final searching = _query.trim().isNotEmpty;

    final showingSongs = _view == _SongsView.songs;
    final showingRooms = _view == _SongsView.rooms;
    // Searching flattens. Somebody typing a half-remembered line wants the
    // song, not a tour of where it might live.
    // Grouped unless you are searching. Places are how people remember
    // where a song is; a search is the moment they have stopped remembering
    // and want everything at once.
    final grouped = showingSongs && !searching;
    // Rooms matching what was typed, for the Rooms segment. Matched on the
    // name only: a room is a place, and somebody searching here is looking
    // for the place rather than for something inside it — that is what the
    // Songs segment is for, and it already searches lyrics.
    final visibleRooms = searching
        ? rooms
            .where((room) => NamePolicy.normalized(room.name)
                .contains(NamePolicy.normalized(_query)))
            .toList(growable: false)
        : rooms;

    var results = searching ? searchSongs(rooms, _query) : allSongsByRecency(rooms);
    if (_roomFilterId != null) {
      results = results.where((r) => r.room.id == _roomFilterId).toList(growable: false);
    }
    // The Control Room's two piles, as a filter on the one list rather than a
    // destination of their own. A song with no recording is in neither: there
    // is nothing a sheet could be made from.
    // Where a recording lands when nobody has said where it goes. The Studio
    // used to be a second library holding these; now they are songs like any
    // other, in a room, and this is the chip that finds them.
    final sets = searching
        ? controller.setlists
            .where((s) => NamePolicy.normalized(s.name).contains(NamePolicy.normalized(_query)))
            .toList(growable: false)
        : controller.setlists;

    return CustomScrollView(
      slivers: <Widget>[
        if (widget.showTopBar)
        SliverToBoxAdapter(
          child: AppTopBar(
            displayName: widget.displayName,
            onOpenAccount: widget.onOpenAccount,
            onOpenNotifications: widget.onOpenNotifications,
          ),
        ),
        // Everything that wants something from you, in one place and in one
        // grammar. Three cards in two positions, each with its own shape and
        // its own idea of how to be dismissed, was one feature built three
        // times -- and two of the three could not be closed at all.
        if (!searching)
          SliverPadding(
            // No horizontal padding, on purpose. The strip is a row of cards
            // that runs off the right edge, and it insets itself so the card
            // edges still line up with everything else — a container 18 in
            // from each side would clip the card that is peeking, which is
            // the one thing telling you the row goes sideways.
            padding: const EdgeInsets.only(top: 10),
            // Redrawn when a song's kept key or part changes: on a desk the
            // song is open beside this strip, and its transpose buttons and
            // its Read as choice both change the chord the Tonight card
            // names.
            sliver: SliverToBoxAdapter(
              child: AnimatedBuilder(
                animation: Listenable.merge(<Listenable>[
                  SongTransposeStore.changes,
                  SongReadingStore.changes,
                ]),
                builder: (_, child) => WaitingOnYou(items: _waiting()),
              ),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 6, 18, 10),
          sliver: SliverToBoxAdapter(child: _titleAndNew(context)),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
          sliver: SliverToBoxAdapter(
            // A Row inside a scroll view rather than a ListView. Four fixed
            // chips do not need lazy building, and lazy building actively
            // hurts here: at 360px with the text scaled up, the fourth chip
            // is off-screen and a ListView never builds it at all — so it is
            // not merely out of view, it does not exist to a screen reader or
            // to anything looking for it.
            //
            // A row that runs sideways has to be given a height, and 34 is
            // the height somebody measured on their own phone. Every
            // Musician, Same Song, 17 September 2026: the phone's own text
            // size is honoured, never clamped, so at the sizes an iOS
            // accessibility setting asks for these three words were sliced
            // top and bottom — silently, because a fixed box clips rather
            // than overflows and nothing in a render walk throws. Measured
            // with the style the chips are drawn in, with 34 kept as a floor
            // so nothing moves for anybody who has not turned their text up.
            // The 12 is the chip's own room above and below its label.
            child: SizedBox(
              height: math.max(
                34,
                linesOfTextHigh(context, _RoomChip.labelStyle) + 12,
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: <Widget>[
                    for (final option
                        in const <({_SongsView view, String label})>[
                      (view: _SongsView.songs, label: 'Songs'),
                      // Rooms, as a place to stand rather than a grouping
                      // somebody has to infer from a long list. Songs already
                      // groups by room, but grouping answers "where is this
                      // song"; it does not answer "what rooms do I have, who
                      // is in them, and how do I make another" — which is
                      // the question somebody has when they are setting up
                      // rather than writing.
                      (view: _SongsView.rooms, label: 'Rooms'),
                      (view: _SongsView.sets, label: 'Sets'),
                    ])
                      _RoomChip(
                        label: option.label,
                        selected: _view == option.view,
                        onTap: () => setState(() => _view = option.view),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
          sliver: SliverToBoxAdapter(
            child: TextField(
              key: const Key('songs_search_field'),
              controller: _searchController,
              onChanged: (value) => setState(() => _query = value),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: showingSongs
                    ? 'Search songs, rooms, or a lyric you remember'
                    : showingRooms
                        ? 'Search rooms'
                        : 'Search sets',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: searching
                    ? IconButton(
                        tooltip: 'Clear search',
                        icon: const Icon(Icons.close_rounded, size: 19),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      )
                    : null,
              ),
            ),
          ),
        ),
        if (showingRooms)
          if (visibleRooms.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(30, 20, 30, kClearOfRecordButton),
                child: Center(
                  child: Text(
                    searching
                        ? 'No rooms match “${_query.trim()}”.'
                        : 'No rooms yet.\n\nA room is a place rather than a folder: '
                            'your band, a side project, or just what you have '
                            'written on your own. Everything in one is visible to '
                            'everybody in it, which is the whole of the privacy '
                            'rule.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.muted, height: 1.5),
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, kClearOfRecordButton),
              sliver: SliverLayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.crossAxisExtent;
                  final count = width >= 980 ? 4 : width >= 620 ? 3 : 2;
                  return SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: count,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 10,
                      mainAxisExtent: 158,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) => _RoomTile(
                        room: visibleRooms[index],
                        controller: controller,
                        onTap: () => _openRoom(visibleRooms[index]),
                      ),
                      childCount: visibleRooms.length,
                    ),
                  );
                },
              ),
            )
        else if (!showingSongs)
          if (sets.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(30, 20, 30, kClearOfRecordButton),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        searching
                            ? 'No sets match “${_query.trim()}”.'
                            : 'No sets yet.\n\nA set is a running order for one occasion — '
                                'Friday practice, Saturday’s show — built from songs you '
                                'already have, in whatever order you’ll play them.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppColors.muted, height: 1.5),
                      ),
                      // The way to make one, where it has just been
                      // described. The only way in was New > Set at the top
                      // of the tab, so the empty list explained a set and
                      // left somebody to find the button (audit, 17
                      // September 2026).
                      if (!searching) ...<Widget>[
                        const SizedBox(height: 18),
                        FilledButton.icon(
                          key: const Key('sets_empty_new'),
                          onPressed: () => unawaited(_newSet()),
                          icon: const Icon(Icons.add_rounded, size: 20),
                          label: const Text('New set'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, kClearOfRecordButton),
              sliver: SliverLayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.crossAxisExtent;
                  final count = width >= 980 ? 4 : width >= 620 ? 3 : 2;
                  return SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: count,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 10,
                      mainAxisExtent: 158,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) => SetlistTile(
                        setlist: sets[index],
                        onTap: () => _openSet(sets[index]),
                      ),
                      childCount: sets.length,
                    ),
                  );
                },
              ),
            )
        else if (rooms.length > 1 && !grouped)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
            sliver: SliverToBoxAdapter(
              // Measured, and 34 kept as a floor — the same fixed box as the
              // selector above, and a room's name is longer than "Songs".
              child: SizedBox(
                height: math.max(
                  34,
                  linesOfTextHigh(context, _RoomChip.labelStyle) + 12,
                ),
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: <Widget>[
                    _RoomChip(
                      label: 'All rooms',
                      selected: _roomFilterId == null,
                      onTap: () => setState(() => _roomFilterId = null),
                    ),
                    for (final room in rooms)
                      _RoomChip(
                        label: room.name,
                        selected: _roomFilterId == room.id,
                        onTap: () => setState(
                          () => _roomFilterId = _roomFilterId == room.id ? null : room.id,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        // Empty first, and before the grouping question.
        //
        // The grouped branch had no empty state at all: with no rooms it
        // drew a list of nothing and stopped, so a brand-new account saw a
        // blank screen. Grouped is the default, so that was every new
        // account.
        if (showingSongs && results.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(30, 20, 30, kClearOfRecordButton),
              child: Center(
                child: searching
                    ? Text(
                        'Nothing matches “${_query.trim()}”.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppColors.muted),
                      )
                    : _ThreeDoors(
                        onRecord: widget.onRecord,
                        onNewSong: () => unawaited(_newSong()),
                        onFindMusicians: widget.onFindMusicians,
                      ),
              ),
            ),
          )
        // Grouped: the library as the places it lives in.
        else if (showingSongs && grouped)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, kClearOfRecordButton),
            sliver: SliverList.list(
              children: <Widget>[
                for (final room in rooms)
                  _RoomSection(
                    room: room,
                    controller: controller,
                    keptIds: _keptIds,
                    onOpenSong: _open,
                    onOpenRoom: () => _openRoom(room),
                    expanded: _expandedRoomIds.contains(room.id),
                    onToggleExpanded: () => setState(() {
                      if (!_expandedRoomIds.remove(room.id)) {
                        _expandedRoomIds.add(room.id);
                      }
                    }),
                  ),
              ],
            ),
          )
        else if (showingSongs)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, kClearOfRecordButton),
              sliver: SliverList.separated(
                itemCount: results.length,
                separatorBuilder: (_, __) => const SizedBox(height: 9),
                itemBuilder: (context, index) {
                  final result = results[index];
                  final author = result.room.authorOf(result.project);
                  return _SongRow(
                    result: result,
                    onTap: () => _open(result.project),
                    keptHere: _keptIds.contains(result.project.id),
                    owner: author?.displayName,
                    ownerColor:
                        author == null ? null : Color(author.colorValue),
                    ownerPhoto: controller.avatarBytesFor(author?.avatarPath),
                  );
                },
              ),
            ),
      ],
    );
  }
}

/// One room, and the songs in it.
///
/// The thing that faded. A room carries an emoji, a name and a set of
/// faces — everything needed to tell your band from your own workspace from
/// the thing you started with somebody last week — and none of it appeared on
/// the screen where you look for songs. Twenty-eight titles in one list is a
/// list you have to read; four places with faces on them is one you recognise.
///
/// **The faces are the privacy signal, and they are always on.** Nothing here
/// needs a lock icon: who can see a room is exactly who is pictured beside
/// its name, which is a fact rather than a promise and is true at a glance.
class _RoomSection extends StatelessWidget {
  const _RoomSection({
    required this.room,
    required this.controller,
    required this.keptIds,
    required this.onOpenSong,
    required this.onOpenRoom,
    required this.expanded,
    required this.onToggleExpanded,
  });

  final MusicRoom room;
  final MusicBetaController controller;

  /// The songs kept on this phone, for the mark on their rows.
  final Set<String> keptIds;
  final ValueChanged<SongProject> onOpenSong;
  final VoidCallback onOpenRoom;

  /// Whether this room is showing all of its songs or the first six.
  final bool expanded;

  /// Show the rest, or fold them back up.
  final VoidCallback onToggleExpanded;

  @override
  Widget build(BuildContext context) {
    final songs = List<SongProject>.from(room.projects)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InkWell(
            onTap: onOpenRoom,
            borderRadius: BorderRadius.circular(9),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: <Widget>[
                  // No glyph. The name is the thing somebody is reading, and
                  // an emoji beside it was decoration paid for out of the
                  // name's own size: 20 points of guitar so the room could
                  // have 16.
                  Flexible(
                    // Two lines rather than one. A room's name is the heading
                    // of everything under it, and at the largest text size
                    // "After Hours Studio" read "After Hours St…" — a room
                    // somebody named, cut in half on the screen where they
                    // look for it. Two lines is enough for every room name
                    // anybody has, and still ends the section rather than
                    // becoming a paragraph.
                    child: Text(
                      room.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 18.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (room.members.length > 1)
                    _Faces(room: room, controller: controller)
                  else
                    // Said plainly rather than drawn as one lonely face. "Just
                    // you" is the most reassuring thing this screen can say
                    // about a room, and it is the default for most of them.
                    const Text(
                      'just you',
                      style: TextStyle(color: AppColors.muted, fontSize: 11.5),
                    ),
                  const SizedBox(width: 4),
                  const Icon(Icons.chevron_right_rounded,
                      size: 17, color: AppColors.muted),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          if (songs.isEmpty)
            // Shown rather than hidden. An empty room is still a place, and
            // a place that vanishes when you empty it is one you stop trusting
            // to hold anything.
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 2),
              child: Text(
                'Nothing in here yet',
                style: TextStyle(
                  color: AppColors.muted.withValues(alpha: 0.7),
                  fontSize: 12.5,
                ),
              ),
            )
          else
            for (final project in expanded ? songs : songs.take(6))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _SongRow(
                  result: SongSearchResult(
                    project: project,
                    room: room,
                    match: SongMatch.title,
                  ),
                  onTap: () => onOpenSong(project),
                  keptHere: keptIds.contains(project.id),
                  owner: room.authorOf(project)?.displayName,
                  ownerColor: room.authorOf(project) == null
                      ? null
                      : Color(room.authorOf(project)!.colorValue),
                  ownerPhoto: controller
                      .avatarBytesFor(room.authorOf(project)?.avatarPath),
                ),
              ),
          if (songs.length > 6)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                // Unfolds here. It used to leave for the room screen, which
                // is a different place, laid out differently, answering a
                // different question — and the way back from it landed
                // nowhere near the list you had been reading.
                onPressed: onToggleExpanded,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: AppColors.cyan,
                ),
                child: Text(
                  expanded
                      ? 'Fewer'
                      : 'All ${songs.length} in ${room.name}',
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w700),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Who can see this room, drawn as the people themselves.
class _Faces extends StatelessWidget {
  const _Faces({required this.room, required this.controller});

  final MusicRoom room;
  final MusicBetaController controller;

  @override
  Widget build(BuildContext context) {
    final shown = room.members.take(4).toList(growable: false);
    return SizedBox(
      height: 22,
      width: 22 + (shown.length - 1) * 15,
      child: Stack(
        children: <Widget>[
          for (var i = 0; i < shown.length; i += 1)
            Positioned(
              left: i * 15,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.deepNavy, width: 1.5),
                ),
                child: PlayerFace(
                  name: shown[i].displayName,
                  color: Color(shown[i].colorValue),
                  photo: controller.avatarBytesFor(shown[i].avatarPath),
                  size: 22,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// What is waiting for a song sheet, when anything is.
///
/// This is the whole Control Room, reduced to the one sentence it existed to
/// say. In production 19 of 22 recordings already had their sheet, so the tab
/// was a room with three things in it and a permanent place in the
/// navigation. A banner can be absent; a tab cannot.
class _NewSetDialog extends StatefulWidget {
  const _NewSetDialog();

  @override
  State<_NewSetDialog> createState() => _NewSetDialogState();
}

class _NewSetDialogState extends State<_NewSetDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New set'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: TextField(
          controller: _name,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Name this set',
            hintText: 'Friday practice',
            helperText: 'You’ll pick the songs and their order next.',
            // Wraps. Left to itself a helper is one line with an ellipsis,
            // and in a dialog on a phone this one read "You’ll pick the
            // songs and their or…" (audit, 17 September 2026).
            helperMaxLines: 3,
          ),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) Navigator.pop(context, value);
          },
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        // Waits for words: with nothing typed it used to close and complain.
        ListenableBuilder(
          listenable: _name,
          builder: (context, _) => FilledButton(
            onPressed: _name.text.trim().isEmpty ? null : () => Navigator.pop(context, _name.text),
            child: const Text('Create'),
          ),
        ),
      ],
    );
  }
}

/// A room as a place, on the segment that lists them.
///
/// The same four facts the grouped list carries in its headings — the emoji,
/// the name, how much is in it, and who else can see it — laid out as a card
/// so a screen full of them can be read at a glance. Who else can see it is
/// the important one and the reason this is not a plain list of names: it is
/// the only privacy signal in the app, and it should never take a tap to
/// find out.
class _RoomTile extends StatelessWidget {
  const _RoomTile({
    required this.room,
    required this.controller,
    required this.onTap,
  });

  final MusicRoom room;
  final MusicBetaController controller;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final songs = room.projects.length;
    final logo = controller.roomLogoBytes(room);
    return BloomTap(
      onTap: onTap,
      semanticLabel: 'Open ${room.name}',
      child: AppSurface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                // A real logo if the room has one, and otherwise nothing at
                // all. The square used to hold the default glyph, which meant
                // every room without a logo wore the same tiny guitar.
                if (logo != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Image.memory(logo, width: 44, height: 44,
                        fit: BoxFit.cover),
                  ),
                const Spacer(),
                if (room.members.length > 1)
                  _Faces(room: room, controller: controller)
                else
                  const Icon(Icons.chevron_right_rounded,
                      color: AppColors.muted, size: 20),
              ],
            ),
            const Spacer(),
            Text(
              room.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              // Larger than titleMedium, which is what the glyph was taking.
              style: const TextStyle(
                color: AppColors.text,
                fontSize: 19,
                fontWeight: FontWeight.w800,
                height: 1.15,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              room.members.length > 1
                  ? '$songs ${songs == 1 ? 'song' : 'songs'} · '
                      '${room.members.length} people'
                  : '$songs ${songs == 1 ? 'song' : 'songs'} · just you',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoomChip extends StatelessWidget {
  const _RoomChip({required this.label, required this.selected, required this.onTap});

  /// What the rows these sit in have to be tall enough for. Public to the
  /// file so a row measures the same style the chip draws.
  static const TextStyle labelStyle = TextStyle(
    fontSize: 12.5,
    fontWeight: FontWeight.w700,
  );

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(17),
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: selected ? AppColors.cyan.withValues(alpha: 0.15) : AppColors.surface,
            borderRadius: BorderRadius.circular(17),
            border: Border.all(color: selected ? AppColors.cyan : AppColors.line),
          ),
          child: Text(
            label,
            style: labelStyle.copyWith(
              color: selected ? AppColors.cyan : AppColors.muted,
            ),
          ),
        ),
      ),
    );
  }
}

/// A row rather than a grid tile: a list scans faster when the thing you're
/// looking for is a name, and it leaves room to show *why* a search result
/// matched.
class _SongRow extends StatelessWidget {
  const _SongRow({
    required this.result,
    required this.onTap,
    this.keptHere = false,
    this.owner,
    this.ownerColor,
    this.ownerPhoto,
  });

  final SongSearchResult result;
  final VoidCallback onTap;

  /// Whether the song is kept on this phone. One more small state at the
  /// end of the row, beside "has a recording" and "finished".
  final bool keptHere;

  /// Who started it — see MusicRoom.authorOf. Null in a room of one.
  final String? owner;
  final Color? ownerColor;
  final Uint8List? ownerPhoto;

  @override
  Widget build(BuildContext context) {
    final project = result.project;
    final lyric = result.lyricLine;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(19),
      child: AppSurface(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
        child: Row(
          children: <Widget>[
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.raised,
                borderRadius: BorderRadius.circular(12),
              ),
              child: owner != null
                  ? PlayerFace(
                      name: owner,
                      color: ownerColor,
                      photo: ownerPhoto,
                      size: 38,
                    )
                  : const Icon(Icons.music_note_rounded,
                      color: AppColors.cyan, size: 19),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    project.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  if (lyric != null)
                    Text(
                      '“$lyric”',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.cyan,
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                      ),
                    )
                  else
                    Text(
                      result.room.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.muted, fontSize: 12),
                    ),
                ],
              ),
            ),
            if (project.hasAudioReference)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Icon(Icons.graphic_eq_rounded, size: 15, color: AppColors.gold),
              ),
            if (project.status == SongStatus.completed)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Icon(Icons.check_circle_rounded, size: 15, color: AppColors.cyan),
              ),
            if (keptHere)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: OnThisPhoneMark(),
              ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right_rounded, color: AppColors.muted, size: 20),
          ],
        ),
      ),
    );
  }
}


/// What this app is for, offered as three things to do.
///
/// Somebody arrives as one of three people and the app cannot tell which:
/// working alone, working with a band, or looking for somebody to play with.
/// Two tabs holding songs serve the first two and abandon the third, who has
/// no songs to put in either.
///
/// The old landing rule sent a new person to the Open Mic on the reasoning
/// that it is "a room with music in it" — which was true against seventy-five
/// seeded musicians and is false against four real ones. So neither tab had
/// anything for somebody on their first morning.
///
/// This is not a mode picker and not a tour. It is an empty state, which is
/// the one place in an interface where saying what is possible is
/// unambiguously right — and it is gone for good the moment there is a single
/// song to show instead.
class _ThreeDoors extends StatelessWidget {
  const _ThreeDoors({
    required this.onRecord,
    required this.onNewSong,
    required this.onFindMusicians,
  });

  final VoidCallback? onRecord;
  final VoidCallback onNewSong;
  final VoidCallback? onFindMusicians;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Text(
          'Nothing here yet',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.text,
            fontSize: 19,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 22),
        _Door(
          key: const Key('door_record'),
          icon: Icons.mic_rounded,
          tint: AppColors.gold,
          title: 'Play something',
          // The promise, not the mechanism. Nothing anywhere told a new
          // person that a phone recording comes back with the chords and
          // the words on it, and that is the whole product.
          detail: 'Humming counts. It comes back with the chords and the '
              'words written down.',
          onTap: onRecord ?? onNewSong,
        ),
        const SizedBox(height: 10),
        _Door(
          key: const Key('door_band'),
          icon: Icons.group_rounded,
          tint: AppColors.cyan,
          // Not "with your band". This screen's three doors are meant to
          // cover somebody at any stage — play something alone, start
          // something with other people, go and find those people — and the
          // middle one was the only one that first required you to already
          // have them.
          title: 'Start something together',
          detail: 'A room everybody adds to, from wherever they are, whenever '
              'they are free.',
          onTap: onNewSong,
        ),
        const SizedBox(height: 10),
        _Door(
          key: const Key('door_find'),
          icon: Icons.travel_explore_rounded,
          tint: AppColors.green,
          title: 'Find somebody to play with',
          detail: 'Hear what people are working on, and put yourself where '
              'they can hear you.',
          onTap: onFindMusicians,
        ),
      ],
    );
  }
}

class _Door extends StatelessWidget {
  const _Door({
    required this.icon,
    required this.tint,
    required this.title,
    required this.detail,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final Color tint;
  final String title;
  final String detail;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.raised,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: tint.withValues(alpha: 0.34)),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(icon, color: tint, size: 22),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      detail,
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
