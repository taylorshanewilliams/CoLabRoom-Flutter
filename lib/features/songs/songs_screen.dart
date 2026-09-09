import 'dart:async';

import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../../app/routes.dart';
import '../../services/current_route.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../app/music_beta_controller.dart';
import '../../widgets/player_face.dart';
import '../../domain/music_models.dart';
import '../../widgets/app_surface.dart';
import '../../domain/name_policy.dart';
import '../../widgets/music_tiles.dart';
import '../../widgets/app_top_bar.dart';
import 'new_song_flow.dart';
import 'pick_it_back_up.dart';
import 'while_you_were_gone.dart';
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
enum _SongsView { songs, sets }

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

  /// Whether there is room to show a song rather than only list it.
  ///
  /// Set by the layout builder before the body is built, the same way the
  /// shell does it, so `_open` knows which of its two behaviours it has
  /// without every caller having to be told.
  bool _desk = false;

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
      setState(() => _openedId = project.id);
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

  void _openRoom(MusicRoom room) {
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
    await Navigator.of(context).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'Room'),
      builder: (_) => RoomDetailScreen(roomId: room.id),
    ));
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
    // Searching flattens. Somebody typing a half-remembered line wants the
    // song, not a tour of where it might live.
    // Grouped unless you are searching. Places are how people remember
    // where a song is; a search is the moment they have stopped remembering
    // and want everything at once.
    final grouped = showingSongs && !searching;
    final queue = SongSheetQueue.from(rooms);

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
        // The news, at the top of the songs somebody was going to open
        // anyway. It was the only thing on Home that existed nowhere else.
        if (!searching)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
            sliver: SliverToBoxAdapter(
              child: WhileYouWereGone(
                activity:
                    controller.activity.take(6).toList(growable: false),
              ),
            ),
          ),
        // And what *you* left. The news says what other people did, which on
        // a quiet week is nothing — and an app with nothing to say on a quiet
        // week gets opened when somebody remembers it exists.
        if (!searching)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
            sliver: SliverToBoxAdapter(
              child: PickItBackUp(
                songs: <SongProject>[
                  for (final room in controller.rooms) ...room.projects,
                ],
                skip: _somethingElse,
                onSkip: () => setState(() => _somethingElse += 1),
                onOpen: _open,
              ),
            ),
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
        // Present only when there is something to act on, and absent when
        // there is not. The Control Room was a permanent tab for this
        // question and answered it with an empty room most of the time.
        if (queue.lead != null && queue.waiting.length + 1 > 0 && !searching)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
            sliver: SliverToBoxAdapter(
              child: _SheetQueueBanner(
                queue: queue,
                onTap: () => _openSheet(queue.lead!.project),
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
        if (!showingSongs)
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
  });

  final MusicRoom room;
  final MusicBetaController controller;
  final ValueChanged<SongProject> onOpenSong;
  final VoidCallback onOpenRoom;

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
                  Text(room.icon, style: const TextStyle(fontSize: 20)),
                  const SizedBox(width: 9),
                  Flexible(
                    child: Text(
                      room.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 16,
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
            for (final project in songs.take(6))
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
                onPressed: onOpenRoom,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: AppColors.cyan,
                ),
                child: Text(
                  'All ${songs.length} in ${room.name}  ›',
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
class _SheetQueueBanner extends StatelessWidget {
  const _SheetQueueBanner({required this.queue, required this.onTap});

  final SongSheetQueue queue;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final lead = queue.lead!;
    final alsoWaiting = queue.waiting.length;
    final working = queue.working.length;

    return Material(
      color: AppColors.gold.withValues(alpha: 0.1),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(13),
        side: BorderSide(color: AppColors.gold.withValues(alpha: 0.5)),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Row(
            children: <Widget>[
              const Icon(Icons.graphic_eq_rounded,
                  color: AppColors.gold, size: 20),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      queue.leadIsSheet
                          ? 'Open the sheet for ${lead.project.title}'
                          : 'Make the song sheet for ${lead.project.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _rest(alsoWaiting, working),
                      style: const TextStyle(
                          color: AppColors.muted, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  color: AppColors.muted, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  /// The rest of the queue in one line, and nothing when there is no rest.
  /// "1 more waiting" is worth saying; "0 more waiting" is noise.
  static String _rest(int waiting, int working) {
    final parts = <String>[
      if (waiting > 0) '$waiting more waiting',
      if (working > 0) '$working being worked out',
    ];
    return parts.isEmpty ? 'Nothing else is waiting' : parts.join(' · ');
  }
}

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
                      '${result.room.icon}  ${result.room.name}',
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
          title: 'Start something with your band',
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
