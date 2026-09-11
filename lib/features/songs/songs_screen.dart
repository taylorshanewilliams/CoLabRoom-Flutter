import 'dart:async';

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
import '../../widgets/app_surface.dart';
import '../../widgets/bloom_tap.dart';
import '../../domain/name_policy.dart';
import '../../widgets/music_tiles.dart';
import '../../widgets/app_top_bar.dart';
import 'new_song_flow.dart';
import 'pick_it_back_up.dart';
import 'waiting_on_you.dart';
import '../openmic/musician_profile_screen.dart';
import '../rooms/room_detail_screen.dart';
import '../rooms/setlist_detail_screen.dart';
import '../workspace/song_workspace_screen.dart';
import '../../services/song_search.dart';
import '../workspace/song_analysis_screen.dart';
import 'song_sheet_queue.dart';
import '../../services/user_facing_error.dart';

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
    this.showTopBar = true,
    super.key,
  });

  /// For the avatar in the corner, which is also the way into the account.
  final String displayName;
  final VoidCallback onOpenAccount;
  final VoidCallback onOpenNotifications;

  /// The two doors this screen cannot open on its own: the record button
  /// lives in the shell, and finding people means changing tab.
  final VoidCallback? onRecord;
  final VoidCallback? onFindMusicians;

  /// False when the shell is drawing one across the top for every tab, which
  /// it does once there is width to put the destinations up there.
  final bool showTopBar;

  @override
  State<SongsScreen> createState() => _SongsScreenState();
}

class _SongsScreenState extends State<SongsScreen> {
  /// How many times somebody has asked for a different old idea today.
  ///
  /// Session-only on purpose. Saying "something else" is a mood, not a
  /// setting, and a skip that persisted would slowly hide the pile it exists
  /// to open up.
  int _somethingElse = 0;

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

  @override
  void initState() {
    super.initState();
    // After the first frame: BetaScope needs a mounted context, and the strip
    // is a convenience the screen works without.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadRequests());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
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

    // A recording with no sheet. One, not a queue: the queue was a card that
    // announced how many other songs were behind this one, which is a fact
    // about the pile rather than a thing to do.
    final queue = SongSheetQueue.from(controller.rooms)
        .without(SetAside.of(SetAside.songSheet));
    final lead = queue.lead;
    if (lead != null && !queue.leadIsSheet) {
      items.add(WaitingItem(
        id: 'sheet-${lead.project.id}',
        kind: WaitingKind.sheet,
        line: lead.project.title,
        detail: 'Recorded, not written down',
        actionLabel: 'Make it',
        onAction: () => _openSheet(lead.project),
        onDismiss: () =>
            unawaited(_setAside(SetAside.songSheet, lead.project.id)),
      ));
    }

    // Something you left. `_somethingElse` still rotates which one is
    // offered; closing it stops this song being offered at all.
    final left = PickItBackUp.choose(
      <SongProject>[
        for (final room in controller.rooms)
          for (final project in room.projects)
            if (!SetAside.has(SetAside.pickItBackUp, project.id)) project,
      ],
      skip: _somethingElse,
    );
    if (left != null) {
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
    for (final entry in controller.activity.take(3)) {
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

  /// Said no, and remembered.
  Future<void> _setAside(String kind, String id) async {
    await SetAside.add(kind, id);
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
    final room = await showCreateRoomDialog(context, controller);
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(reportAndDescribe(error, service: 'app', route: 'Songs'))));
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

  Widget _library(BuildContext context) {
    final controller = BetaScope.of(context);
    final rooms = controller.rooms;
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
            sliver: SliverToBoxAdapter(child: WaitingOnYou(items: _waiting())),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 6, 18, 10),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text('Your music',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.displaySmall),
                ),
                // One button, three things, and the third is the point.
                //
                // Making a room was only possible inside the new-song flow —
                // pick a room, or create one without leaving. So the concept
                // this app is named after had no front door: you could only
                // make a room as a step on the way to making a song, which
                // is exactly backwards for somebody setting up a space for
                // their band.
                //
                // It also drops an oddity: the button changed its own label
                // depending on which segment was showing, so what "+" did
                // depended on where you had last tapped.
                MenuAnchor(
                  builder: (context, controller, _) => FilledButton.icon(
                    key: const Key('songs_new_button'),
                    onPressed: () => controller.isOpen
                        ? controller.close()
                        : controller.open(),
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
                ),
              ],
            ),
          ),
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
            child: SizedBox(
              height: 34,
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
                padding: const EdgeInsets.fromLTRB(30, 20, 30, 60),
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
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 30),
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
                padding: const EdgeInsets.fromLTRB(30, 20, 30, 60),
                child: Center(
                  child: Text(
                    searching
                        ? 'No sets match “${_query.trim()}”.'
                        : 'No sets yet.\n\nA set is a running order for one occasion — '
                            'Friday practice, Saturday’s show — built from songs you '
                            'already have, in whatever order you’ll play them.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.muted, height: 1.5),
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 30),
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
              child: SizedBox(
                height: 34,
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
              padding: const EdgeInsets.fromLTRB(30, 20, 30, 60),
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
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 30),
            sliver: SliverList.list(
              children: <Widget>[
                for (final room in rooms)
                  _RoomSection(
                    room: room,
                    controller: controller,
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
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 30),
              sliver: SliverList.separated(
                itemCount: results.length,
                separatorBuilder: (_, __) => const SizedBox(height: 9),
                itemBuilder: (context, index) {
                  final result = results[index];
                  final author = result.room.authorOf(result.project);
                  return _SongRow(
                    result: result,
                    onTap: () => _open(result.project),
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
    required this.onOpenSong,
    required this.onOpenRoom,
    required this.expanded,
    required this.onToggleExpanded,
  });

  final MusicRoom room;
  final MusicBetaController controller;
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
                    child: Text(
                      room.name,
                      maxLines: 1,
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
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _name.text),
          child: const Text('Create'),
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
            style: TextStyle(
              color: selected ? AppColors.cyan : AppColors.muted,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
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
    this.owner,
    this.ownerColor,
    this.ownerPhoto,
  });

  final SongSearchResult result;
  final VoidCallback onTap;

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
