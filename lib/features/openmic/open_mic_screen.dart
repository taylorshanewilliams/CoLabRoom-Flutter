import 'dart:async';

import 'package:flutter/material.dart';
import '../../app/routes.dart';

import '../../app/colabroom_theme.dart';
import '../../data/music_repository.dart';
import '../../domain/music_models.dart';
import '../../services/current_route.dart';
import '../../services/user_facing_error.dart';
import '../../widgets/app_top_bar.dart';
import '../../widgets/demo_chip.dart';
import '../../widgets/play_button.dart';
import 'ask_somebody_not_here.dart';
import 'listen_screen.dart';
import 'musician_profile_screen.dart';
import 'open_mic_song_screen.dart';
import '../../widgets/offer_to_be_found.dart';
import 'out_there.dart';
import 'what_are_you_after.dart';
import '../../widgets/problem_report.dart';

/// Open Mic — where you meet somebody you have not met.
///
/// The name is the design. A room is yours and a band's; the open mic is a
/// place you visibly step onto and can step off again. That boundary being a
/// *place* rather than a setting is what makes it safe to have at all —
/// "public" is an abstraction nobody trusts, and "put this on the open mic"
/// is a thing a musician can picture.
///
/// **Why this is not a search form.** Instrument, genre, location, Search is
/// what every marketplace builds, and it fails for a reason no filter can
/// express: "guitarist" does not distinguish a metal player from a jazz one.
/// The judgement you actually want is made by ear in about ten seconds. So
/// the filter here is deliberately coarse — it narrows thousands to dozens,
/// and the listening does the rest.
class OpenMicScreen extends StatefulWidget {
  const OpenMicScreen({
    required this.repository,
    this.displayName = '',
    this.onOpenAccount,
    this.onOpenNotifications,
    this.showTopBar = true,
    super.key,
  });

  final MusicRepository repository;

  /// The corner. Null when this screen is shown somewhere that already has
  /// its own chrome — a pushed route rather than a tab.
  final String displayName;
  final VoidCallback? onOpenAccount;
  final VoidCallback? onOpenNotifications;

  /// False when the shell draws one across the top for every tab.
  final bool showTopBar;

  @override
  State<OpenMicScreen> createState() => _OpenMicScreenState();
}

class _OpenMicScreenState extends State<OpenMicScreen> {
  /// What you are looking at, as one value.
  ///
  /// This was four: a segmented button, a set of ticked chips, and two text
  /// fields, all of them on screen at once and all of them optional. Which
  /// meant the top of the room was a form somebody had to get past before it
  /// would show them a single person — and the chips meant *who plays this*
  /// under one tab and *who needs this* under another, with nothing on screen
  /// saying which way they pointed.
  ///
  /// Now the room shows the answer and keeps the controls behind it. See
  /// [OpenMicQuery] and [showWhatAreYouAfter].
  OpenMicQuery _query = const OpenMicQuery();

  List<Musician>? _found;
  List<ShowcaseSong>? _finished;

  /// Your own songs out on the Open Mic. Loaded once, beside the first
  /// search, because it does not change while somebody is filtering.
  List<OpenMicStatus> _mine = const <OpenMicStatus>[];
  List<OpenMicSong>? _songs;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_search());
    unawaited(_loadMine());
    unawaited(_loadMe());
  }

  Future<void> _loadMine() async {
    try {
      final mine = await widget.repository.myOpenMic();
      if (mounted) setState(() => _mine = mine);
    } catch (_) {
      // The strip is news about your own songs. Failing to fetch it is not
      // a reason to put an error across a screen somebody came to browse.
    }
  }

  /// Whether you are one of the people not in the room.
  ///
  /// An empty room reads as broken. This one is not broken — being findable
  /// is off until somebody turns it on, and in production exactly one real
  /// account has — but that is only *legible* if the screen knows which of
  /// the two empties it is looking at, and it cannot infer that from the
  /// list. Inferring would tell somebody who is listed and plays keys that
  /// they are invisible, on a search for bass players.
  ///
  /// Null while the answer is still coming, and the empty state says less
  /// while it is. Same rule as the audience dial: never guess about
  /// somebody's own visibility.
  Musician? _me;

  Future<void> _loadMe() async {
    try {
      final me =
          await widget.repository.loadMusician(widget.repository.currentUserId);
      if (mounted) setState(() => _me = me);
    } catch (_) {
      // Unknown stays unknown.
    }
  }

  /// Being the first person in the room, from the place that says to be.
  ///
  /// The empty state has told people to list themselves since it was written
  /// and offered no way to do it: the switch lives on your own profile page
  /// and behind [_narrow], and neither is where somebody reading that
  /// sentence is standing. Naming an action and not offering it is most of
  /// the difference between a young room and a broken one.
  Future<void> _listMe() async {
    final changed = await BeFound.offer(
      context,
      widget.repository,
      becauseTheyAsked: true,
    );
    if (!changed || !mounted) return;
    unawaited(_loadMe());
    unawaited(_search());
  }

  /// Listed, and the only one. Worth saying out loud rather than leaving
  /// somebody to wonder why the room contains exactly themselves.
  bool _aloneInTheRoom(List<Musician> found) =>
      found.length == 1 && found.single.id == widget.repository.currentUserId;

  Future<void> _search() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    if (_query.isFinished) {
      try {
        final done = await widget.repository.showcase();
        if (mounted) setState(() => _finished = done);
      } catch (error) {
        if (!mounted) return;
        setState(() {
          _finished = const <ShowcaseSong>[];
          _error = reportAndDescribe(
            error,
            service: 'app',
            stage: 'showcase',
            route: 'Open Mic',
          );
        });
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    if (_query.isSongs) {
      try {
        // Songs still take one part: a song asks for a bass player, not for
        // three things at once. The first ticked is the one it uses.
        final songs = await widget.repository
            .openMicSongs(
              part: _query.parts.isEmpty ? null : _query.parts.first,
              limit: 40);
        if (mounted) setState(() => _songs = songs);
      } catch (error) {
        if (!mounted) return;
        setState(() {
          _songs = const <OpenMicSong>[];
          _error = reportAndDescribe(
            error,
            service: 'app',
            stage: 'open_mic_songs',
            route: 'Open Mic',
          );
        });
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    try {
      final found = await widget.repository.findMusicians(
        parts: _query.parts.toList(growable: false),
        city: _query.city,
        soundsLike: _query.sounds,
        limit: 40,
      );
      if (mounted) setState(() => _found = found);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _found = const <Musician>[];
        _error = reportAndDescribe(
          error,
          service: 'app',
          stage: 'find_musicians',
          route: 'Open Mic',
        );
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openSong(OpenMicSong song) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'Open Mic song'),
      builder: (_) => OpenMicSongScreen(
        projectId: song.id,
        repository: widget.repository,
        initial: song,
      ),
    ));
    if (mounted) CurrentRoute.enter('Open Mic');
  }

  /// Sitting down in front of the whole room, one song at a time.
  Future<void> _listen() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'Listen'),
      builder: (_) => ListenScreen(
        repository: widget.repository,
        // The stage plays one filter at a time; the first ticked is the one
        // it takes.
        part: _query.parts.isEmpty ? null : _query.parts.first,
      ),
    ));
    if (mounted) CurrentRoute.enter('Open Mic');
  }

  Future<void> _openProfile(Musician musician) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: RouteSettings(name: AppRoutes.musician(musician.id)),
        builder:
            (_) => MusicianProfileScreen(
              profileId: musician.id,
              repository: widget.repository,
              initial: musician,
              // Only when the room was narrowed to one thing. Somebody who
              // opened a whole door — five kinds of voice at once — has not
              // said which they want, and guessing the first of five would
              // put a word in their mouth they never said.
              lookingFor:
                  _query.parts.length == 1 ? _query.parts.first : null,
            ),
      ),
    );
    if (mounted) CurrentRoute.enter('Open Mic');
  }

  /// Whether the reciprocity question has been put this session.
  ///
  /// Once, and only after somebody has actually narrowed the room — asking
  /// on arrival would be a permission prompt on a launch screen, which is
  /// the thing every other part of this app has been careful not to be.
  bool _askedToBeFound = false;

  /// Reaching past the edge of the room.
  ///
  /// The room can only offer the people already in it, and at four accounts
  /// that is nobody — but everybody looking for a bass player already knows
  /// one. Carries what they were looking for, so the message writes itself.
  Future<void> _askSomebodyNotHere() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.raised,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => AskSomebodyNotHere(
        repository: widget.repository,
        myName: widget.displayName.isEmpty ? 'Somebody' : widget.displayName,
        about: _query.parts.length == 1 ? _query.parts.first : null,
      ),
    );
  }

  /// Opening the trail.
  ///
  /// Applied as it is chosen rather than on a Done button, so the list behind
  /// the sheet re-sorts while somebody is still deciding. Narrowing is
  /// something you watch happen, not something you submit.
  Future<void> _narrow() async {
    await showWhatAreYouAfter(
      context,
      query: _query,
      onChanged: (next) {
        setState(() {
          _query = next;
          _error = null;
        });
        unawaited(_search());
      },
    );
    // The one moment it is fair to ask. Somebody is standing in the room
    // looking for people, and nobody can look for them — one real account of
    // four in production is findable, so the room they are searching is very
    // nearly empty and they are not in it.
    if (_askedToBeFound || !mounted || _query.isFinished) return;
    _askedToBeFound = true;
    final changed = await BeFound.offer(context, widget.repository);
    if (changed && mounted) unawaited(_search());
  }

  @override
  Widget build(BuildContext context) {
    final found = _found;
    // A tab now, not a pushed route, so it wears the same inline header the
    // other tabs do rather than an AppBar. It reached the third slot when the
    // Studio and the Control Room stopped being destinations: three tabs were
    // three filters on one library, and the freed one goes to the part of the
    // app that is supposed to grow.
    return Column(
      children: <Widget>[
        // The same corner as the other tab, in the same place. Home used to
        // be the only screen carrying the bell and the avatar, so when it
        // stopped being a tab they had to live somewhere both tabs could
        // reach — which is here, identically positioned, so it is a place
        // people learn once.
        if (widget.showTopBar &&
            widget.onOpenAccount != null &&
            widget.onOpenNotifications != null)
          AppTopBar(
            displayName: widget.displayName,
            onOpenAccount: widget.onOpenAccount!,
            onOpenNotifications: widget.onOpenNotifications!,
          ),
        // Above the filters, because it is about you rather than about the
        // room, and somebody opening this tab wants to know what came back
        // before they start looking outward again.
        OutThere(
          mine: _mine,
          onOpen: (song) => unawaited(_openSong(OpenMicSong(
            id: song.id,
            title: song.title,
            ownerName: '',
            putUpAt: song.putUpAt,
            askingFor: song.askingFor,
            storagePath: song.storagePath,
          ))),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Expanded(
                child: Text(
                  'Open Mic',
                  style: Theme.of(context).textTheme.displaySmall,
                ),
              ),
              // The stage is a mode, not a fourth tab.
              //
              // Browsing and listening are two ways of using the same room,
              // and a separate destination would have made them two rooms
              // holding the same songs — the exact duplication the audit
              // spent two screens undoing. Here the filter you already chose
              // carries straight through: pick Bass, press Listen, and you
              // are hearing songs that need a bass player.
              FilledButton.icon(
                key: const Key('open_mic_listen'),
                onPressed: () => unawaited(_listen()),
                icon: const Icon(Icons.play_arrow_rounded, size: 19),
                label: const Text('Listen'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.cyan,
                  foregroundColor: AppColors.ink,
                  padding: const EdgeInsets.symmetric(horizontal: 15),
                  textStyle: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
        ),
        _Statement(query: _query, onTap: _busy ? null : _narrow),
        const Divider(height: 1),
        if (_query.isFinished)
          Expanded(
            child: _FinishedList(
              songs: _finished,
              error: _error,
              onOpen: (song) => unawaited(_openSong(OpenMicSong(
                id: song.id,
                title: song.title,
                ownerId: song.ownerId,
                ownerName: song.ownerName,
                putUpAt: song.shownAt,
                storagePath: song.storagePath,
                durationMs: song.durationMs,
                musicalKey: song.musicalKey,
              ))),
            ),
          )
        else if (_query.isSongs)
          Expanded(child: _SongList(
            songs: _songs,
            error: _error,
            onOpen: _openSong,
          ))
        else
        Expanded(
          child:
              found == null
                  ? const Center(
                    child: CircularProgressIndicator(color: AppColors.gold),
                  )
                  : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                    children: <Widget>[
                      if (_error != null) ...<Widget>[
                        ProblemNote(_error!, fontSize: 13),
                        const SizedBox(height: 14),
                      ],
                      if (found.isEmpty)
                        _Empty(
                          listed: _me?.discoverable,
                          narrowed: _query.isNarrowed,
                          onListMe: _listMe,
                          onAskSomebody: _askSomebodyNotHere,
                        )
                      else ...<Widget>[
                        if (_aloneInTheRoom(found))
                          _OnlyYou(onAskSomebody: _askSomebodyNotHere),
                        for (final musician in found)
                          _MusicianCard(
                            musician: musician,
                            isYou:
                                musician.id == widget.repository.currentUserId,
                            filter: null,
                            onTap: () => _openProfile(musician),
                          ),
                      ],
                    ],
                  ),
        ),
      ],
    );
  }

}

/// The songs half of the Open Mic.
///
/// Cards lead with what a song is *asking for*, because that is the one thing
/// that decides whether somebody taps. A list of titles is a list nobody can
/// act on: you cannot tell from "Ladder Of Life" whether it wants a bass
/// player, and playing all of them to find out is exactly the friction that
/// makes a pile of audio go unlistened to.
class _SongList extends StatelessWidget {
  const _SongList({
    required this.songs,
    required this.error,
    required this.onOpen,
  });

  final List<OpenMicSong>? songs;
  final String? error;
  final ValueChanged<OpenMicSong> onOpen;

  @override
  Widget build(BuildContext context) {
    final found = songs;
    if (found == null) {
      return const Center(child: CircularProgressIndicator(color: AppColors.gold));
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: <Widget>[
        if (error != null) ...<Widget>[
          Text(error!,
              style: const TextStyle(color: AppColors.orange, fontSize: 13)),
          const SizedBox(height: 14),
        ],
        if (found.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 40),
            child: Column(
              children: <Widget>[
                Icon(Icons.library_music_outlined,
                    size: 34, color: AppColors.line),
                SizedBox(height: 12),
                Text(
                  'Nobody needs anything right now',
                  style: TextStyle(
                    color: AppColors.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: 6),
                // Names the action rather than describing the mechanism.
                // The old copy explained how a song gets here, which is a
                // sentence about the app; this is one about them.
                // A noticeboard with nothing on it means everybody is sorted.
                // A feed with nothing in it is broken. They read completely
                // differently to a person, and this is the first one.
                Text(
                  'This is where songs come to find the part they are '
                  'missing. Ask for one on a song of yours and it shows up '
                  'here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: AppColors.muted, fontSize: 12.5, height: 1.45),
                ),
              ],
            ),
          )
        else
          for (final song in found) _SongCard(song: song, onTap: () => onOpen(song)),
      ],
    );
  }
}

/// A song you can hear without leaving the list.
///
/// It used to end on the line "3 parts to listen to" and offer no way to
/// listen to any of them — you tapped through to a page that could not play
/// them either. The decision this card exists to support is made by ear in
/// about ten seconds, and it was asking people to make it by reading a
/// title.
class _SongCard extends StatelessWidget {
  const _SongCard({required this.song, required this.onTap});

  final OpenMicSong song;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppColors.raised,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: song.isAsking
                ? AppColors.cyan.withValues(alpha: 0.45)
                : AppColors.line,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // Outside the InkWell's text column and first in the row:
                // playing is not the same gesture as opening, and the two
                // must not be a millimetre apart or one becomes the other.
                Padding(
                  padding: const EdgeInsets.only(top: 2, right: 12),
                  child: PlayButton(
                    storagePath: song.storagePath,
                    durationMs: song.durationMs,
                    title: song.title,
                    byline: song.ownerName,
                    songId: song.id,
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.text,
                          fontSize: 15.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        song.ownerName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppColors.muted, fontSize: 12.5),
                      ),
                      if (song.isAsking) ...<Widget>[
                        const SizedBox(height: 9),
                        Text(
                          song.askingFor.isEmpty
                              ? 'Asking for help'
                              : 'Asking for ${song.askingFor.join(', ')}',
                          style: const TextStyle(
                            color: AppColors.cyan,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Text(
                        song.canPlay
                            ? '${song.takeCount} '
                                '${song.takeCount == 1 ? "part" : "parts"} on it'
                            : 'Nothing recorded on it yet',
                        style: const TextStyle(
                            color: AppColors.muted, fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The one line where the filters used to be.
///
/// It says what you are looking at, not what you last pressed — "Bass players
/// near Leeds" rather than a chip reading "Bass" — and it is the door to
/// everything that used to be laid out above it.
///
/// **A phone's settings list has worked this way for fifteen years.** A row
/// carries its own value on the right, so the answer is readable without
/// opening it, and opening it costs nothing because back is free. The Open
/// Mic had the opposite: four controls permanently on screen, none of them
/// showing an answer, all of them between somebody and the first person in
/// the room.
class _Statement extends StatelessWidget {
  const _Statement({required this.query, required this.onTap});

  final OpenMicQuery query;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const Key('open_mic_statement'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    query.sentence,
                    style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    query.caption,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.muted, fontSize: 11.5),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(left: 8, top: 4),
              child: Icon(Icons.expand_more_rounded,
                  size: 22, color: AppColors.cyan),
            ),
          ],
        ),
      ),
    );
  }
}

class _MusicianCard extends StatelessWidget {
  const _MusicianCard({
    required this.musician,
    required this.filter,
    required this.onTap,
    this.isYou = false,
  });

  final Musician musician;

  /// Whether this card is the person reading it.
  ///
  /// `find_musicians` does not filter you out, which is right — you should be
  /// able to see what you look like in the room. Unmarked, though, your own
  /// card is a stranger with your name on it, and in a room of one it is the
  /// entire result.
  final bool isYou;
  final String? filter;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final top = musician.topParts;
    // Material rather than a decorated Container, so the tap is visible. An
    // InkWell paints its splash on the nearest Material ancestor, and an
    // opaque box in between hides it — the card would take the tap and look
    // like it had not.
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppColors.raised,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppColors.line),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    // Hear them without leaving the list.
                    //
                    // Deciding whether to work with somebody is done by ear
                    // in about ten seconds, and this card carried a name, a
                    // city, what they play and what you have in common —
                    // everything except the only thing anybody judges a
                    // musician on.
                    if (musician.canBeHeard) ...<Widget>[
                      PlayButton(
                        storagePath: musician.heardPath,
                        durationMs: musician.heardDurationMs,
                        title: musician.heardTitle ?? musician.displayName,
                        byline: musician.displayName,
                        songId: musician.heardSongId,
                        size: 34,
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Text(
                        musician.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.text,
                          fontSize: 15.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (isYou) ...<Widget>[
                      const SizedBox(width: 6),
                      Container(
                        key: const Key('open_mic_you_chip'),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.cyan.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Text(
                          'You',
                          style: TextStyle(
                            color: AppColors.cyan,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ),
                    ],
                    if (musician.isDemo) ...<Widget>[
                      const SizedBox(width: 6),
                      const DemoChip(compact: true),
                    ],
                    if (musician.city != null) ...<Widget>[
                      const Icon(
                        Icons.place_outlined,
                        size: 13,
                        color: AppColors.muted,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        musician.city!,
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ],
                ),
                // What you have in common, before anything they have done.
                //
                // The line that turns a directory into a room: not "this
                // person is good" but "this person is making what you are
                // making". It is the only thing on the card that is about
                // the two of you rather than about them.
                // What of your list they actually do. Without this the
                // order is a mystery: somebody near the top looks preferred
                // rather than closer to what was asked for.
                if (musician.matchedParts.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      const Icon(Icons.check_circle_outline_rounded,
                          size: 13, color: AppColors.cyan),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Does ${musician.matchedParts.join(', ')}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.cyan,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                if (musician.sharedSounds.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      const Icon(Icons.graphic_eq_rounded,
                          size: 13, color: AppColors.gold),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Both into ${musician.sharedSounds.join(', ')}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.gold,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 8),

                // What they have actually played, first and in the app's own colour.
                // A recording is a fact; the list below it is a hope, and the two
                // are never merged into one impression.
                if (top.isNotEmpty)
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      for (final entry in top)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.cyan.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            '${entry.key} · ${entry.value}',
                            style: TextStyle(
                              color:
                                  entry.key == filter
                                      ? AppColors.cyan
                                      : AppColors.text,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                    ],
                  )
                else
                  Text(
                    musician.plays.isEmpty
                        ? 'Has not recorded anything here yet'
                        : 'Says they play ${musician.plays.join(', ')} · '
                            'nothing recorded here yet',
                    style: const TextStyle(
                      color: AppColors.muted,
                      fontSize: 12,
                    ),
                  ),

                if (musician.hasRecord) ...<Widget>[
                  const SizedBox(height: 9),
                  Text(
                    '${musician.songsPlayedOn} '
                    '${musician.songsPlayedOn == 1 ? 'song' : 'songs'} · '
                    '${musician.peopleWorkedWith} '
                    '${musician.peopleWorkedWith == 1 ? 'person' : 'people'}',
                    style: const TextStyle(
                      color: AppColors.muted,
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({
    this.listed,
    this.narrowed = false,
    this.onListMe,
    this.onAskSomebody,
  });

  /// Whether *you* are findable. Null until the answer arrives.
  ///
  /// The whole point of this widget is the difference between a room nobody
  /// has walked into and a room nobody has switched a light on in, and only
  /// this tells them apart. While it is null the copy claims neither.
  final bool? listed;

  /// Whether anything was asked for. "Nobody here plays that" and "nobody is
  /// here" are different pieces of news.
  final bool narrowed;

  /// The action the copy has always named and never offered.
  final VoidCallback? onListMe;

  /// The one useful thing to do when the room cannot help.
  ///
  /// An empty room used to end the conversation: it said nobody was here and
  /// left somebody exactly where it found them. But nobody looking for a
  /// bass player has run out of bass players — they have run out of bass
  /// players *on this app*, and they almost certainly know one.
  final VoidCallback? onAskSomebody;

  /// Nothing here is hidden and nothing is broken — say which.
  ///
  /// "Nobody *else*" is a claim that you are in the room, so it waits until
  /// that is known. Until then the old sentence, which claims nothing.
  String get _headline {
    if (listed == false) return 'Nobody has listed themselves yet';
    if (narrowed) return 'Nobody here plays that yet';
    return listed == true ? 'Nobody else here yet' : 'Nobody here yet';
  }

  String get _body {
    if (listed == false) {
      return 'Being findable is off until you turn it on — for everybody, '
          'including you. Be the first, and people looking for what you play '
          'will find you.';
    }
    if (listed == true) {
      return narrowed
          ? 'You are listed, so somebody searching can find you. Nobody '
              'matching this is here yet.'
          : 'You are listed, so somebody searching can find you. Nobody else '
              'is here yet.';
    }
    // Still loading. True of everybody, and a claim about nobody.
    return 'Nobody is findable here until they say so.';
  }

  @override
  Widget build(BuildContext context) {
    final canList = listed == false && onListMe != null;
    return Padding(
      padding: const EdgeInsets.only(top: 40),
      child: Column(
        children: <Widget>[
          Icon(
            listed == false
                ? Icons.mic_external_off_rounded
                : Icons.person_search_outlined,
            size: 34,
            color: AppColors.line,
          ),
          const SizedBox(height: 12),
          Text(
            _headline,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          // Offers instead of explaining. The old copy was three accurate
          // sentences about why the list was empty, which left somebody
          // exactly where they found them. Nobody is listed by default and
          // that stays true — but the useful thing to tell the first person
          // here is that they can be first, and then to let them be.
          Text(
            _body,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.muted,
              fontSize: 12.5,
              height: 1.45,
            ),
          ),
          if (canList) ...<Widget>[
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('open_mic_list_me'),
              onPressed: onListMe,
              icon: const Icon(Icons.podcasts_rounded, size: 18),
              label: const Text('List me on the Open Mic'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.cyan,
                foregroundColor: AppColors.ink,
              ),
            ),
          ],
          if (onAskSomebody != null) ...<Widget>[
            SizedBox(height: canList ? 4 : 16),
            // Demoted to a text button once there is something better above
            // it. Reaching outside the app is the right move when the room
            // cannot help, and the wrong first move when the reason it cannot
            // help is that you have not joined it yet.
            canList
                ? TextButton.icon(
                    key: const Key('open_mic_ask_somebody_not_here'),
                    onPressed: onAskSomebody,
                    icon: const Icon(Icons.person_add_alt_rounded, size: 17),
                    label: const Text('Ask somebody you know'),
                    style:
                        TextButton.styleFrom(foregroundColor: AppColors.muted),
                  )
                : FilledButton.icon(
                    key: const Key('open_mic_ask_somebody_not_here'),
                    onPressed: onAskSomebody,
                    icon: const Icon(Icons.person_add_alt_rounded, size: 18),
                    label: const Text('Ask somebody you know'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.cyan,
                      foregroundColor: AppColors.ink,
                    ),
                  ),
          ],
        ],
      ),
    );
  }
}

/// A room containing exactly you.
///
/// The state right after somebody presses the button on [_Empty], and the one
/// most likely to be read as a bug: you asked to see musicians and the app
/// returned you. Said out loud it is the opposite — proof the switch worked,
/// and a look at what a stranger sees. `find_musicians` deliberately does not
/// filter you out, and being able to see your own card is how you find out
/// what you look like from the other side.
class _OnlyYou extends StatelessWidget {
  const _OnlyYou({required this.onAskSomebody});

  final VoidCallback onAskSomebody;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      decoration: BoxDecoration(
        color: AppColors.raised,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'You are the only one listed so far',
            style: TextStyle(
              color: AppColors.text,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 5),
          const Text(
            'That card is how you look to somebody searching for what you '
            'play. A room fills one person at a time.',
            style: TextStyle(
              color: AppColors.muted,
              fontSize: 12.5,
              height: 1.45,
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('open_mic_only_you_ask'),
              onPressed: onAskSomebody,
              icon: const Icon(Icons.person_add_alt_rounded, size: 17),
              label: const Text('Ask somebody you know'),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.cyan,
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Finished work, newest first.
///
/// Newest and nothing else. The moment this is ordered by listens it is a
/// chart, and this app does not rank people — somebody's first finished song
/// sits above a record with a thousand plays if they finished it this
/// morning, which is right for a room and wrong for a league.
class _FinishedList extends StatelessWidget {
  const _FinishedList({
    required this.songs,
    required this.error,
    required this.onOpen,
  });

  final List<ShowcaseSong>? songs;
  final String? error;
  final ValueChanged<ShowcaseSong> onOpen;

  @override
  Widget build(BuildContext context) {
    final found = songs;
    if (found == null) {
      return const Center(
          child: CircularProgressIndicator(color: AppColors.gold));
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: <Widget>[
        if (error != null) ...<Widget>[
          Text(error!,
              style: const TextStyle(color: AppColors.orange, fontSize: 13)),
          const SizedBox(height: 14),
        ],
        if (found.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 40),
            child: Column(
              children: <Widget>[
                Icon(Icons.workspace_premium_outlined,
                    size: 34, color: AppColors.line),
                SizedBox(height: 12),
                Text(
                  'Nothing finished yet',
                  style: TextStyle(
                    color: AppColors.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  'This is where songs go when they are done. Finish one of '
                  'yours and show it, and it will be the first thing here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: AppColors.muted, fontSize: 12.5, height: 1.45),
                ),
              ],
            ),
          )
        else
          for (final song in found)
            _FinishedCard(song: song, onTap: () => onOpen(song)),
      ],
    );
  }
}

class _FinishedCard extends StatelessWidget {
  const _FinishedCard({required this.song, required this.onTap});

  final ShowcaseSong song;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final together = song.together;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppColors.raised,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            // Gold only when two people who met here made it. That is the
            // app's whole argument, and it is worth nothing if everything
            // wears the colour.
            color: song.metHere
                ? AppColors.gold.withValues(alpha: 0.5)
                : AppColors.line,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 2, right: 12),
                  child: PlayButton(
                    storagePath: song.storagePath,
                    durationMs: song.durationMs,
                    title: song.title,
                    byline: song.ownerName,
                    songId: song.id,
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.text,
                          fontSize: 15.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        song.ownerName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppColors.muted, fontSize: 12.5),
                      ),
                      if (together != null) ...<Widget>[
                        const SizedBox(height: 9),
                        Row(
                          children: <Widget>[
                            Icon(
                              song.metHere
                                  ? Icons.handshake_rounded
                                  : Icons.group_rounded,
                              size: 13,
                              color: song.metHere
                                  ? AppColors.gold
                                  : AppColors.muted,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                together,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: song.metHere
                                      ? AppColors.gold
                                      : AppColors.muted,
                                  fontSize: 12,
                                  fontWeight: song.metHere
                                      ? FontWeight.w800
                                      : FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
