import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../../app/routes.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/colabroom_theme.dart';
import '../../data/music_repository.dart';
import '../../domain/music_models.dart';
import '../../domain/musical_roles.dart';
import '../../services/current_route.dart';
import '../../services/user_facing_error.dart';
import '../../widgets/demo_chip.dart';
import '../../widgets/offer_notifications.dart';
import '../../widgets/play_button.dart';
import 'ask_musician_sheet.dart';
import 'invite_to_room_sheet.dart';
import 'open_mic_song_screen.dart';
import 'report_sheet.dart';
import '../workspace/song_workspace_screen.dart';
import 'the_app_noticed.dart';
import '../../widgets/profile_face.dart';

/// Somebody's own room.
///
/// Three kinds of thing about a musician, and the page keeps them apart on
/// purpose, because each is worth a different amount:
///
///   * **Played here** — counted from takes a room actually kept. Nobody
///     declared it and nobody can inflate it. It is the record.
///   * **Also plays** — what they would like to be asked for. Aspiration is
///     welcome, and it is a hope rather than a fact.
///   * **Elsewhere** — a link to work they made somewhere else. Shown and
///     never counted, because anybody can paste a link to anything. It says
///     what somebody sounds like, not what they have done.
///
/// Every profile design that goes wrong goes wrong by averaging those into one
/// impression — a star rating, a score, a level. Kept apart, a beginner with
/// four honest takes and a session player with two hundred both have a page
/// worth reading, and neither has to lose to the other.
class MusicianProfileScreen extends StatefulWidget {
  const MusicianProfileScreen({
    required this.profileId,
    required this.repository,
    this.initial,
    this.lookingFor,
    super.key,
  });

  final String profileId;
  final MusicRepository repository;

  /// What the room was narrowed to when this person was tapped.
  ///
  /// Carried through to the ask sheet so somebody who searched for a bass
  /// player is not asked, one screen later, what they want. Null when this
  /// page was opened from somewhere with no search behind it — a song's
  /// credits, a notification — because there is nothing to carry then.
  final String? lookingFor;

  /// The row Open Mic already had. Drawn immediately so that tapping a card
  /// does not open an empty screen with a spinner in it; replaced by the full
  /// load a moment later.
  final Musician? initial;

  @override
  State<MusicianProfileScreen> createState() => _MusicianProfileScreenState();
}

class _MusicianProfileScreenState extends State<MusicianProfileScreen> {
  Musician? _musician;
  List<ShowcaseLink>? _links;
  List<OpenMicSong>? _songs;
  String? _sharedCity;
  String? _error;
  bool _missing = false;
  List<Noticed> _noticed = const <Noticed>[];
  bool _starting = false;
  String? _claiming;

  bool get _isMe => widget.repository.currentUserId == widget.profileId;

  @override
  void initState() {
    super.initState();
    _musician = widget.initial;
    CurrentRoute.enter('Profile');
    unawaited(_load());
  }

  /// Their picture, once it has been fetched.
  ///
  /// This page had no avatar on it at all — not a small one, not a fallback,
  /// nothing. A musician's profile that never shows their face is a database
  /// row with headings, and it is the first thing anybody deciding whether to
  /// work with a stranger looks for.
  Uint8List? _face;

  Future<void> _load() async {
    try {
      final musician = await widget.repository.loadMusician(widget.profileId);
      unawaited(_loadFace(musician?.avatarPath ?? widget.initial?.avatarPath));
      final links = await widget.repository.loadShowcase(widget.profileId);
      final songs = await widget.repository.songsBy(widget.profileId);
      // Only about yourself. What the app has worked out about somebody else
      // is not a thing to show anybody, including them.
      final noticed = _isMe
          ? await widget.repository.thingsWeNoticed()
          : const <Noticed>[];
      String? shared;
      if (!_isMe) {
        // Only ever a nice surprise, never a filter. Null is the normal answer
        // and is not worth putting an error on the page for.
        try {
          shared = await widget.repository.sharedCityWith(widget.profileId);
        } catch (_) {
          shared = null;
        }
      }
      if (!mounted) return;
      setState(() {
        _missing = musician == null && widget.initial == null;
        if (musician != null) _musician = musician;
        _links = links;
        _songs = songs;
        _noticed = noticed;
        _sharedCity = shared;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _links = const <ShowcaseLink>[];
        _error = reportAndDescribe(
          error,
          service: 'app',
          stage: 'load_profile',
          route: 'Profile',
        );
      });
    }
  }

  /// Best effort, and silent.
  ///
  /// A picture that will not load is a page with initials on it, which is a
  /// perfectly good page. Putting an error on the screen because somebody's
  /// avatar 404'd would be the tail wagging the dog.
  Future<void> _loadFace(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final bytes = await widget.repository.loadAvatar(path);
      if (!mounted) return;
      setState(() => _face = bytes);
    } catch (_) {
      // Initials, then.
    }
  }

  /// Writing the one thing on this page nobody counted.
  Future<void> _editBio() async {
    final current = _musician?.bio ?? '';
    final written = await showDialog<String>(
      context: context,
      builder: (_) => _BioDialog(initial: current),
    );
    if (written == null || !mounted) return;
    try {
      await widget.repository.setBio(written);
      if (!mounted) return;
      // Shown immediately rather than after a reload. Somebody who has just
      // written a sentence about themselves should see it on their page, not
      // a spinner where it will eventually be.
      final me = _musician;
      if (me != null) {
        setState(() => _musician = Musician(
              id: me.id,
              displayName: me.displayName,
              avatarPath: me.avatarPath,
              city: me.city,
              bio: written.trim().isEmpty ? null : written.trim(),
              plays: me.plays,
              soundsLike: me.soundsLike,
              partsRecorded: me.partsRecorded,
              songsPlayedOn: me.songsPlayedOn,
              peopleWorkedWith: me.peopleWorkedWith,
              discoverable: me.discoverable,
              locationVisibility: me.locationVisibility,
              isDemo: me.isDemo,
            ));
      }
      unawaited(_load());
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = reportAndDescribe(
            error,
            service: 'app',
            stage: 'set_bio',
            route: 'Profile',
          ));
    }
  }

  Future<void> _open(ShowcaseLink link) async {
    final uri = Uri.tryParse(link.url);
    if (uri == null) return;
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened) {
        throw StateError('nothing on this phone opened ${uri.host}');
      }
    } catch (error) {
      if (!mounted) return;
      _say(reportAndDescribe(
        error,
        service: 'app',
        stage: 'open_showcase_link',
        route: 'Profile',
      ));
    }
  }

  void _say(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _add() async {
    final result = await showModalBottomSheet<({String url, String title})>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.deepNavy,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
        ),
        child: const _AddLinkSheet(),
      ),
    );
    if (result == null || result.url.isEmpty || !mounted) return;
    try {
      await widget.repository
          .addShowcaseLink(url: result.url, title: result.title);
      await _load();
    } catch (error) {
      if (!mounted) return;
      _say(reportAndDescribe(
        error,
        service: 'app',
        stage: 'add_showcase_link',
        route: 'Profile',
      ));
    }
  }

  Future<void> _remove(ShowcaseLink link) async {
    try {
      await widget.repository.removeShowcaseLink(link.id);
      await _load();
    } catch (error) {
      if (!mounted) return;
      _say(reportAndDescribe(
        error,
        service: 'app',
        stage: 'remove_showcase_link',
        route: 'Profile',
      ));
    }
  }

  /// The verb this page did not have.
  ///
  /// Open Mic could find you a bass player in your city and then the app
  /// stopped — you could look at somebody and do nothing about it, which made
  /// the whole feature a browsing exercise and is why nobody had turned
  /// themselves on. There was nothing on the other side of being listed.
  Future<void> _ask() async {
    final musician = _musician;
    if (musician == null) return;
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.deepNavy,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
        ),
        child: AskMusicianSheet(
          musician: musician,
          repository: widget.repository,
          suggestedPart: widget.lookingFor,
        ),
      ),
    );
    if (sent == true && mounted) {
      _say('Asked ${musician.displayName}. They will hear about it, and '
          'nothing of yours opens up unless they say yes.');
      // Waiting on one particular person, which is the sharpest version of
      // the condition a notification is for.
      await offerNotifications(
        context,
        title: 'Tell you when they answer?',
        because: 'We can let you know on your phone when they say yes or no, '
            'instead of you having to come back and check.',
      );
    }
  }

  /// The bigger of the two doors: a whole room rather than one song.
  ///
  /// Both exist because they are genuinely different sizes, and an app with
  /// only the big one would make every "want to try this?" into "here is my
  /// band's entire library".
  Future<void> _invite() async {
    final musician = _musician;
    if (musician == null) return;
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.deepNavy,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
        ),
        child: InviteToRoomSheet(
          musician: musician,
          repository: widget.repository,
        ),
      ),
    );
    if (sent == true && mounted) {
      _say('Invited ${musician.displayName}. They see nothing until they '
          'say yes.');
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
    if (mounted) CurrentRoute.enter('Profile');
  }

  Future<void> _report() async {
    final musician = _musician;
    if (musician == null) return;
    final sent = await showReportSheet(
      context,
      repository: widget.repository,
      kind: 'profile',
      about: musician.displayName,
      profileId: musician.id,
    );
    if (sent && mounted) {
      _say('Report sent. Thank you — somebody reads every one of these.');
    }
  }

  /// Blocking, and saying what it does before it does it.
  ///
  /// Quiet on their side and symmetric on both: after this neither of you
  /// turns up in the other's Open Mic, and nobody is told. It stops new
  /// contact rather than tearing up a room you are both already in —
  /// wanting out of a room is a different action, and it has its own.
  Future<void> _block() async {
    final musician = _musician;
    if (musician == null) return;
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.raised,
        title: Text('Block ${musician.displayName}?'),
        content: const Text(
          'They will not be able to find you, ask you, or invite you to '
          'anything, and you will not see them either. They are not told.'
          '\n\n'
          'If you are in a room together this does not remove either of '
          'you from it. You can undo this in Account.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.orange),
            child: const Text('Block'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    try {
      await widget.repository.blockUser(musician.id);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      _say(reportAndDescribe(
        error,
        service: 'app',
        stage: 'block_user',
        route: 'Profile',
      ));
    }
  }

  /// Writing down one thing the app spotted.
  ///
  /// Reloaded afterwards rather than patched locally, because accepting one
  /// suggestion usually removes it and can change the others — claiming a
  /// part is exactly the thing that stops it being suggested.
  Future<void> _claim(String part) async {
    if (_claiming != null) return;
    setState(() => _claiming = part);
    try {
      await widget.repository.claimPart(part);
      await _load();
      if (!mounted) return;
      setState(() => _claiming = null);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('$part added to what you play.')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _claiming = null);
      _say(reportAndDescribe(
        error,
        service: 'app',
        stage: 'claim_part',
        route: 'Profile',
      ));
    }
  }

  /// Meeting somebody, and being at work with them a second later.
  ///
  /// Everything this does was already possible and took six steps: go back,
  /// make a room, name it, make a song, name that, invite them. Six
  /// deliberate acts to act on an impulse, which is how an impulse dies.
  Future<void> _startSomething() async {
    final musician = _musician;
    if (musician == null || _starting) return;
    setState(() => _starting = true);
    try {
      final made = await widget.repository.startSomethingWith(musician.id);
      if (!mounted) return;
      setState(() => _starting = false);
      // Straight into the song, because the point is to be working rather
      // than to be told a room exists.
      await Navigator.of(context).push(MaterialPageRoute<void>(
        settings: RouteSettings(name: AppRoutes.song(made.projectId)),
        builder: (_) => SongWorkspaceScreen(projectId: made.projectId),
      ));
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(
            '${musician.displayName} has been invited. They see it when '
            'they say yes.',
          ),
        ));
      if (!mounted) return;
      await offerNotifications(
        context,
        title: 'Tell you when they join?',
        because: 'We can let you know on your phone the moment they accept, '
            'so you are both in the room at the same time.',
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _starting = false);
      _say(reportAndDescribe(
        error,
        service: 'app',
        stage: 'start_something_with',
        route: 'Profile',
      ));
    }
  }

  Future<void> _editPresence() async {
    final me = _musician;
    if (me == null) return;
    final changed = await showModalBottomSheet<_Presence>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.deepNavy,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
        ),
        child: _PresenceSheet(me: me),
      ),
    );
    if (changed == null || !mounted) return;
    try {
      await widget.repository.setOpenMicPresence(
        discoverable: changed.discoverable,
        city: changed.city,
        locationVisibility: changed.locationVisibility,
        plays: changed.plays,
        soundsLike: changed.soundsLike,
      );
      await _load();
    } catch (error) {
      if (!mounted) return;
      _say(reportAndDescribe(
        error,
        service: 'app',
        stage: 'set_open_mic_presence',
        route: 'Profile',
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final musician = _musician;
    return Scaffold(
      backgroundColor: AppColors.deepNavy,
      appBar: AppBar(
        backgroundColor: AppColors.deepNavy,
        title: Text(
          _isMe ? 'Your profile' : (musician?.displayName ?? 'Profile'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 17),
        ),
        actions: <Widget>[
          if (_isMe)
            IconButton(
              tooltip: 'Open Mic settings',
              onPressed:
                  musician == null ? null : () => unawaited(_editPresence()),
              icon: const Icon(Icons.tune_rounded),
            )
          // On every page but your own, and in the overflow rather than
          // beside the friendly buttons — reachable in two taps from the
          // thing being complained about, which is what makes it usable, and
          // not so prominent that it reads as the expected response to a
          // stranger.
          else if (musician != null)
            PopupMenuButton<String>(
              tooltip: 'More',
              onSelected: (value) => unawaited(
                  value == 'block' ? _block() : _report()),
              itemBuilder: (_) => const <PopupMenuEntry<String>>[
                PopupMenuItem<String>(
                  value: 'report',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.flag_outlined, size: 19),
                    title: Text('Report'),
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'block',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.block_rounded, size: 19),
                    title: Text('Block'),
                  ),
                ),
              ],
            ),
        ],
      ),
      body: SafeArea(
        child: musician == null
            ? Center(
                child: _missing
                    ? const Padding(
                        padding: EdgeInsets.all(28),
                        child: Text(
                          'There is no profile here to show you.',
                          textAlign: TextAlign.center,
                          style:
                              TextStyle(color: AppColors.muted, fontSize: 13.5),
                        ),
                      )
                    : const CircularProgressIndicator(color: AppColors.gold),
              )
            : _Body(
                musician: musician,
                links: _links,
                songs: _songs,
                onOpenSong: (song) => unawaited(_openSong(song)),
                sharedCity: _sharedCity,
                error: _error,
                face: _face,
                onEditBio: () => unawaited(_editBio()),
                isMe: _isMe,
                noticed: _noticed,
                claiming: _claiming,
                onClaim: (part) => unawaited(_claim(part)),
                onAdd: () => unawaited(_add()),
                onRemove: (link) => unawaited(_remove(link)),
                onOpen: (link) => unawaited(_open(link)),
                onEditPresence: () => unawaited(_editPresence()),
                onAsk: _isMe ? null : () => unawaited(_ask()),
                onStartSomething:
                    _isMe ? null : () => unawaited(_startSomething()),
                onInvite: _isMe ? null : () => unawaited(_invite()),
              ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.musician,
    required this.links,
    required this.songs,
    required this.onOpenSong,
    required this.sharedCity,
    required this.error,
    required this.face,
    required this.onEditBio,
    required this.isMe,
    required this.noticed,
    required this.claiming,
    required this.onClaim,
    required this.onAdd,
    required this.onRemove,
    required this.onOpen,
    required this.onEditPresence,
    required this.onAsk,
    required this.onInvite,
    required this.onStartSomething,
  });

  final Musician musician;

  /// Their picture, or null while it is still coming — or for good, if they
  /// have not set one.
  final Uint8List? face;

  final VoidCallback onEditBio;

  /// Only ever non-empty on your own page.
  final List<Noticed> noticed;
  final String? claiming;
  final ValueChanged<String> onClaim;

  final List<ShowcaseLink>? links;
  final List<OpenMicSong>? songs;
  final ValueChanged<OpenMicSong> onOpenSong;
  final String? sharedCity;
  final String? error;
  final bool isMe;
  final VoidCallback onAdd;
  final ValueChanged<ShowcaseLink> onRemove;
  final ValueChanged<ShowcaseLink> onOpen;
  final VoidCallback onEditPresence;

  /// Null on your own page, where asking yourself is not a thing.
  final VoidCallback? onAsk;
  final VoidCallback? onInvite;

  /// A room, a first song and an invitation, in one press.
  final VoidCallback? onStartSomething;

  @override
  Widget build(BuildContext context) {
    final top = musician.topParts;
    final shown = links;
    final heard = songs ?? const <OpenMicSong>[];

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 40),
      children: <Widget>[
        // Above the name, because it is news rather than description — and
        // because somebody who has just recorded something should meet the
        // app noticing before they meet a form.
        if (isMe && noticed.isNotEmpty)
          TheAppNoticed(
            noticed: noticed,
            busy: claiming,
            onClaim: onClaim,
            onOpenSettings: onEditPresence,
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            ProfileFace(
              name: musician.displayName,
              bytes: face,
              seed: musician.id,
              size: 78,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          musician.displayName,
                          style: const TextStyle(
                            color: AppColors.text,
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                            height: 1.15,
                          ),
                        ),
                      ),
                      if (musician.isDemo) ...<Widget>[
                        const SizedBox(width: 9),
                        const DemoChip(),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        if (musician.isDemo) ...<Widget>[
          const SizedBox(height: 6),
          const Text(
            'A seeded account, here so the app can be tested with a crowd '
            'in it. Not a real person, and not somebody to ask.',
            style: TextStyle(
                color: AppColors.muted, fontSize: 12, height: 1.4),
          ),
        ],
        if (sharedCity != null || musician.city != null) ...<Widget>[
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              Icon(
                Icons.place_outlined,
                size: 14,
                color: sharedCity != null ? AppColors.green : AppColors.muted,
              ),
              const SizedBox(width: 4),
              // The nicest thing this app can say, and it appears only after
              // two people have actually made something together. Discovery
              // that comes after the music beats a postcode filter, and it is
              // safer: nobody's city is offered to a stranger browsing.
              Expanded(
                child: Text(
                  sharedCity != null
                      ? '$sharedCity — same city as you'
                      : musician.city!,
                  style: TextStyle(
                    color:
                        sharedCity != null ? AppColors.green : AppColors.muted,
                    fontSize: 12.5,
                    fontWeight:
                        sharedCity != null ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ],
        // What they said about themselves, above the buttons.
        //
        // This is the context for the decision the buttons ask for. Somebody
        // about to ask a stranger onto their song wants to know who they are
        // before they are offered three ways to contact them, and every other
        // thing on this page is either a number the app worked out or a chip
        // somebody tapped.
        if (musician.bio != null && musician.bio!.trim().isNotEmpty) ...<Widget>[
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Text(
                  musician.bio!,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 14.5,
                    height: 1.5,
                  ),
                ),
              ),
              if (isMe)
                IconButton(
                  onPressed: onEditBio,
                  tooltip: 'Edit what you said',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.edit_outlined,
                      size: 17, color: AppColors.muted),
                ),
            ],
          ),
        ] else if (isMe) ...<Widget>[
          const SizedBox(height: 14),
          // Only ever offered to you, and only when it is empty. A stranger's
          // page with a "no bio yet" line on it says nothing except that the
          // app was expecting more.
          TextButton.icon(
            onPressed: onEditBio,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.cyan,
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 36),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Say something about yourself'),
          ),
        ],
        if (error != null) ...<Widget>[
          const SizedBox(height: 14),
          Text(
            error!,
            style: const TextStyle(color: AppColors.orange, fontSize: 12.5),
          ),
        ],
        if (onStartSomething != null) ...<Widget>[
          const SizedBox(height: 18),
          // First, and gold, because it is the thing this whole surface
          // exists for. Asking somebody onto a song you already have is the
          // right move when you have one; this is the move for "I like this
          // person, let us make something", which had no button at all and
          // took six deliberate steps.
          FilledButton.icon(
            key: const Key('start_something_with'),
            onPressed: onStartSomething,
            icon: const Icon(Icons.auto_awesome_rounded, size: 18),
            label: const Text(
              'Start something together',
              style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800),
            ),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              backgroundColor: AppColors.gold,
              foregroundColor: AppColors.ink,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Makes a room with a first song in it, and invites them. '
            'Nothing of yours opens up until they say yes.',
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: AppColors.muted, fontSize: 11.5, height: 1.35),
          ),
        ],
        if (onAsk != null) ...<Widget>[
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: onAsk,
            icon: const Icon(Icons.piano_rounded, size: 18),
            label: const Text(
              'Ask them to play on…',
              style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800),
            ),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              backgroundColor: AppColors.cyan,
              foregroundColor: AppColors.ink,
            ),
          ),
          const SizedBox(height: 8),
          // Secondary on purpose. One song is the right size for meeting
          // somebody; a whole room is what you offer once you know them,
          // so the small door is the loud one.
          if (onInvite != null)
            OutlinedButton.icon(
              onPressed: onInvite,
              icon: const Icon(Icons.library_music_outlined, size: 17),
              label: const Text(
                'Invite to a room',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(44),
                foregroundColor: AppColors.text,
                side: const BorderSide(color: AppColors.line),
              ),
            ),
          const SizedBox(height: 7),
          // Said before they tap, not after. Somebody about to contact a
          // stranger about their unfinished song wants to know what it costs
          // them, and the answer is nothing.
          const Text(
            'Either way, they hear about it and nothing of yours opens up '
            'unless they say yes.',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: AppColors.muted, fontSize: 11.5, height: 1.4),
          ),
        ],
        if (isMe && musician.discoverable == false) ...<Widget>[
          const SizedBox(height: 16),
          _NotListedYet(onEdit: onEditPresence),
        ],
        const SizedBox(height: 24),
        const _Heading('Played here', note: 'counted, not claimed'),
        const SizedBox(height: 9),
        if (musician.partsRecorded.isNotEmpty) ...<Widget>[
          // The same numbers as the chips below, as a shape.
          //
          // Under the name it was two thin marks with no heading over them and
          // read as a glitch; here the section says what it is, so it can be
          // the thing you see first and the chips can be the detail you read
          // second. It is also the one element on this page that could not
          // belong to any other directory of people.
          PartsSignature(parts: musician.partsRecorded, seed: musician.id),
          const SizedBox(height: 12),
        ],
        if (top.isEmpty)
          Text(
            isMe
                ? 'Nothing of yours has been shared to a room yet. This fills '
                    'itself in as you record.'
                : 'Nothing recorded here yet.',
            style: const TextStyle(
                color: AppColors.muted, fontSize: 12.5, height: 1.45),
          )
        else ...<Widget>[
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: <Widget>[
              for (final entry in top)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.cyan.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${entry.key} · ${entry.value}',
                    style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '${musician.songsPlayedOn} '
            '${musician.songsPlayedOn == 1 ? 'song' : 'songs'} · '
            'with ${musician.peopleWorkedWith} '
            '${musician.peopleWorkedWith == 1 ? 'person' : 'people'}',
            style: const TextStyle(color: AppColors.muted, fontSize: 12.5),
          ),
        ],
        // Between the record and the wish list, and deliberately there.
        //
        // The page reads: what they have done, what it sounds like, what they
        // would like to be asked for, where else to find them. The sound goes
        // straight after the count because a number is what makes somebody
        // trust a profile and a song is what makes them tap.
        if (heard.isNotEmpty) ...<Widget>[
          const SizedBox(height: 28),
          _Heading('Listen', note: isMe ? 'anybody can hear these' : null),
          const SizedBox(height: 9),
          for (final song in heard)
            _SongOnProfile(
              song: song,
              onTap: () => onOpenSong(song),
            ),
        ],
        if (musician.soundsLike.isNotEmpty) ...<Widget>[
          const SizedBox(height: 28),
          const _Heading('Sounds like', note: 'their own words'),
          const SizedBox(height: 9),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final tag in musician.soundsLike)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.gold.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: AppColors.gold.withValues(alpha: 0.4)),
                  ),
                  child: Text(
                    tag,
                    style: const TextStyle(
                      color: AppColors.gold,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
        ],
        if (musician.plays.isNotEmpty) ...<Widget>[
          const SizedBox(height: 28),
          const _Heading('Also plays', note: 'their own words'),
          const SizedBox(height: 9),
          Text(
            musician.plays.join(' · '),
            style: const TextStyle(color: AppColors.text, fontSize: 13.5),
          ),
        ],
        const SizedBox(height: 28),
        Row(
          children: <Widget>[
            const Expanded(
              child: _Heading('Elsewhere', note: 'linked, not hosted'),
            ),
            if (isMe)
              TextButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add_rounded, size: 17),
                label: const Text(
                  'Add',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.cyan,
                  visualDensity: VisualDensity.compact,
                ),
              ),
          ],
        ),
        const SizedBox(height: 9),
        if (shown == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(minHeight: 2),
          )
        else if (shown.isEmpty)
          Text(
            isMe
                ? 'Link a track from SoundCloud, Spotify, YouTube or Bandcamp '
                    'so people can hear what you sound like before they ask '
                    'you to play on something.'
                : 'Nothing linked yet.',
            style: const TextStyle(
                color: AppColors.muted, fontSize: 12.5, height: 1.45),
          )
        else
          for (final link in shown)
            _LinkRow(
              link: link,
              onOpen: () => onOpen(link),
              onRemove: isMe ? () => onRemove(link) : null,
            ),
      ],
    );
  }
}

/// A song of theirs you can actually play.
///
/// The strongest thing a profile can hold, and the last thing it got. A
/// counted part is evidence; a link is a claim; a song is the sound, which is
/// what a musician was trying to judge all along.
class _SongOnProfile extends StatelessWidget {
  const _SongOnProfile({required this.song, required this.onTap});

  final OpenMicSong song;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Empty means the song is theirs. Otherwise it is somebody else's song
    // they played on, and saying which part is the difference between showing
    // your work and claiming their song.
    final theirs = song.theirParts.isEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.raised,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.line),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(13, 11, 12, 11),
            child: Row(
              children: <Widget>[
                // A real one. This was a play-circle icon that did nothing —
                // on the row whose whole argument is that a song is the
                // sound, which is what a musician was trying to judge all
                // along.
                PlayButton(
                  storagePath: song.storagePath,
                  durationMs: song.durationMs,
                  title: song.title,
                  byline: song.ownerName,
                  songId: song.id,
                  size: 34,
                ),
                const SizedBox(width: 11),
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
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _subtitle(song, theirs),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppColors.muted, fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded,
                    size: 18, color: AppColors.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _subtitle(OpenMicSong song, bool theirs) {
  if (theirs) {
    final parts = song.takeCount == 1 ? "part" : "parts";
    return "Their song · ${song.takeCount} $parts";
  }
  return "Played ${song.theirParts.join(", ")} on ${song.ownerName}'s song";
}

/// Your own page, before anybody else can see it.
///
/// Said here rather than buried in settings, because the profile is where you
/// find out whether it is worth turning on — and because somebody who does not
/// know they are invisible will conclude the feature is broken.
class _NotListedYet extends StatelessWidget {
  const _NotListedYet({required this.onEdit});

  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.raised,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'Only you can see this page',
            style: TextStyle(
              color: AppColors.text,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 5),
          const Text(
            'You are not listed in Open Mic. Turn it on when the page looks '
            'like you — and turn it off again whenever you like.',
            style:
                TextStyle(color: AppColors.muted, fontSize: 12.5, height: 1.45),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: onEdit,
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              child: const Text(
                'Open Mic settings',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text, {this.note});

  final String text;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        Flexible(
          child: Text(
            text.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 11,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.3,
            ),
          ),
        ),
        if (note != null) ...<Widget>[
          const SizedBox(width: 8),
          // The label that keeps the three sections from blurring together.
          // "Counted, not claimed" beside a number is the whole difference
          // between a record and a boast.
          Flexible(
            child: Text(
              note!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.muted, fontSize: 10.5),
            ),
          ),
        ],
      ],
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({
    required this.link,
    required this.onOpen,
    required this.onRemove,
  });

  final ShowcaseLink link;
  final VoidCallback onOpen;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    // Material rather than a decorated Container. A ListTile paints its ink
    // on the nearest Material ancestor, so a coloured box between the two
    // hides every splash — the row would look dead on a real phone, and
    // Flutter asserts about it in debug.
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.raised,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.line),
        ),
        child: ListTile(
          onTap: onOpen,
          leading:
              const Icon(Icons.play_circle_outline_rounded, color: AppColors.cyan),
          title: Text(
            link.displayTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          // The platform is said out loud. Tapping this leaves the app, and
          // somebody is entitled to know where they are about to be sent.
          subtitle: Text(
            link.platform,
            style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
          ),
          trailing: onRemove == null
              ? const Icon(Icons.open_in_new_rounded,
                  size: 16, color: AppColors.muted)
              : IconButton(
                  tooltip: 'Remove',
                  onPressed: onRemove,
                  icon: const Icon(Icons.close_rounded,
                      size: 17, color: AppColors.muted),
                ),
        ),
      ),
    );
  }
}

class _AddLinkSheet extends StatefulWidget {
  const _AddLinkSheet();

  @override
  State<_AddLinkSheet> createState() => _AddLinkSheetState();
}

class _AddLinkSheetState extends State<_AddLinkSheet> {
  final TextEditingController _url = TextEditingController();
  final TextEditingController _title = TextEditingController();

  @override
  void dispose() {
    _url.dispose();
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              'Link something you made',
              style: TextStyle(
                color: AppColors.text,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 5),
            // Said before the field rather than after a rejection. Naming what
            // is allowed is friendlier than an error explaining what was not.
            const Text(
              'SoundCloud, Spotify, YouTube, Bandcamp, Apple Music, Vimeo or '
              'Audiomack. We only link to it — the audio stays where you put '
              'it, and stays yours.',
              style:
                  TextStyle(color: AppColors.muted, fontSize: 12, height: 1.45),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _url,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Link',
                hintText: 'https://…',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _title,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'What to call it (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                (url: _url.text.trim(), title: _title.text.trim()),
              ),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
              ),
              child: const Text('Add it'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Presence {
  const _Presence({
    required this.discoverable,
    required this.city,
    required this.locationVisibility,
    required this.plays,
    required this.soundsLike,
  });

  final bool discoverable;
  final String city;
  final String locationVisibility;
  final List<String> plays;
  final List<String> soundsLike;
}

class _PresenceSheet extends StatefulWidget {
  const _PresenceSheet({required this.me});

  final Musician me;

  @override
  State<_PresenceSheet> createState() => _PresenceSheetState();
}

class _PresenceSheetState extends State<_PresenceSheet> {
  /// The same vocabulary Open Mic filters on, so what you tick is exactly what
  /// somebody searching sees. Free text on one side and a fixed list of chips
  /// on the other is how a search quietly stops matching.
  /// The same list the Open Mic filters on, which is now the only list.
  ///
  /// It was eight instruments here too, so a rapper, a beat maker or a
  /// lyricist could not tick anything true about themselves — and what you
  /// tick is exactly what somebody searching sees.
  static List<MusicalRole> get _parts => MusicalRole.offered;

  static const List<({String value, String label, String why})> _visibilities =
      <({String value, String label, String why})>[
    (
      value: 'nobody',
      label: 'Keep it to myself',
      why: 'Nobody sees your city. You can still be found by what you play.',
    ),
    (
      value: 'collaborators',
      label: 'People I have made something with',
      why: 'They find out you are in the same city after the music, which is '
          'the better order.',
    ),
    (
      value: 'public',
      label: 'Anybody in Open Mic',
      why: 'You turn up when somebody browses your city.',
    ),
  ];

  /// Somewhere to start, not the whole world.
  ///
  /// Deliberately wide and deliberately not a fixed vocabulary: the field
  /// takes whatever somebody types, and a closed list would be wrong for most
  /// of the planet before it was wrong for anybody else. These are the
  /// starting points that save typing, spread across traditions rather than
  /// ranked by any of them.
  static const List<String> _suggestions = <String>[
    'singer-songwriter', 'folk', 'rock', 'indie', 'pop', 'punk', 'metal',
    'blues', 'jazz', 'soul', 'r&b', 'hip hop', 'country', 'americana',
    'bluegrass', 'gospel', 'worship', 'electronic', 'ambient', 'house',
    'reggae', 'afrobeats', 'latin', 'k-pop', 'classical', 'experimental',
  ];

  static const int _maxSounds = 5;

  late bool _discoverable;
  late String _visibility;
  late final TextEditingController _city;
  late final Set<String> _plays;
  late final Set<String> _soundsLike;
  final TextEditingController _ownWords = TextEditingController();

  /// For a role the list does not have. Somebody plays the sitar, somebody
  /// runs front of house, somebody writes string arrangements — a fixed list
  /// is a promise this app cannot keep, and the column is free text anyway.
  final TextEditingController _ownRole = TextEditingController();

  @override
  void initState() {
    super.initState();
    _discoverable = widget.me.discoverable ?? false;
    _visibility = widget.me.locationVisibility ?? 'nobody';
    _city = TextEditingController(text: widget.me.city ?? '');
    _plays = widget.me.plays.toSet();
    _soundsLike = widget.me.soundsLike.toSet();
  }

  /// Adds whatever somebody typed, in their words.
  ///
  /// Lower-cased and trimmed to match what the server stores, so a tag typed
  /// as "Folk" and one picked as "folk" are the same tag rather than two that
  /// never match each other.
  /// Adds a role in somebody's own words.
  ///
  /// Lower-cased and trimmed to match what the server stores, so a role
  /// typed as "Fiddle" and one picked from a list are the same thing rather
  /// than two that never match each other.
  void _addOwnRole() {
    final typed = _ownRole.text.trim().toLowerCase();
    if (typed.isEmpty || typed.length > 40) return;
    setState(() {
      _plays.add(typed);
      _ownRole.clear();
    });
  }

  void _addOwnWords() {
    final typed = _ownWords.text.trim().toLowerCase();
    if (typed.isEmpty || typed.length > 40) return;
    if (_soundsLike.length >= _maxSounds) return;
    setState(() {
      _soundsLike.add(typed);
      _ownWords.clear();
    });
  }

  @override
  void dispose() {
    _ownRole.dispose();
    _ownWords.dispose();
    _city.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Open Mic settings',
              style: TextStyle(
                color: AppColors.text,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _discoverable,
              onChanged: (on) => setState(() => _discoverable = on),
              title: const Text(
                'List me in Open Mic',
                style: TextStyle(
                  color: AppColors.text,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              subtitle: const Text(
                'Off by default. Nobody appears there without choosing to.',
                style: TextStyle(color: AppColors.muted, fontSize: 12),
              ),
            ),
            const SizedBox(height: 14),
            const _SheetHeading('What you do'),
            const SizedBox(height: 4),
            const Text(
              'How people find you for work you actually want. Tick what you '
              'would like to be asked for, not only what you have done — and '
              'it is not only instruments: rapping, beats, lyrics and mixing '
              'are all things somebody is looking for.',
              style:
                  TextStyle(color: AppColors.muted, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: <Widget>[
                // Anything they typed themselves first, so a role that is
                // not on the list does not look second-class.
                for (final own in _plays.where(
                    (p) => !_parts.any((role) => role.value == p)))
                  FilterChip(
                    label: Text(own),
                    selected: true,
                    onSelected: (_) => setState(() => _plays.remove(own)),
                    showCheckmark: false,
                    selectedColor: AppColors.cyan.withValues(alpha: 0.18),
                    backgroundColor: AppColors.raised,
                    side: const BorderSide(color: AppColors.cyan),
                    labelStyle: const TextStyle(
                      color: AppColors.cyan,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                for (final entry in _parts)
                  FilterChip(
                    label: Text(entry.label),
                    // The ones whose name does not carry the meaning say so.
                    // "Topline" is nothing to somebody who has never worked
                    // over a beat, and it is exactly who this is for.
                    tooltip: entry.note,
                    selected: _plays.contains(entry.value),
                    onSelected: (on) => setState(() {
                      if (on) {
                        _plays.add(entry.value);
                      } else {
                        _plays.remove(entry.value);
                      }
                    }),
                    showCheckmark: false,
                    selectedColor: AppColors.cyan.withValues(alpha: 0.18),
                    backgroundColor: AppColors.raised,
                    side: BorderSide(
                      color: _plays.contains(entry.value)
                          ? AppColors.cyan
                          : AppColors.line,
                    ),
                    labelStyle: TextStyle(
                      color: _plays.contains(entry.value)
                          ? AppColors.cyan
                          : AppColors.text,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _ownRole,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _addOwnRole(),
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Something else you do',
                prefixIcon: const Icon(Icons.add_rounded, size: 18),
                suffixIcon: TextButton(
                  onPressed: _addOwnRole,
                  child: const Text('Add'),
                ),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Sitar, front of house, string arrangements — whatever it is. '
              'The list above is a shortcut, not the whole world.',
              style: TextStyle(color: AppColors.muted, fontSize: 11.5),
            ),
            const SizedBox(height: 20),
            const _SheetHeading('What you sound like'),
            const SizedBox(height: 4),
            // Says what it is for, and says the thing that makes it safe to
            // answer honestly: it moves you sideways, never up or down.
            const Text(
              'The one thing that makes "people like me" mean anything — '
              '"guitarist" does not tell anybody whether you play metal or '
              'jazz. Nobody is ranked by this. It only points you towards '
              'people making the same kind of music.',
              style:
                  TextStyle(color: AppColors.muted, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: <Widget>[
                // Whatever they typed themselves comes first, so a word that
                // is not on the list does not look second-class.
                for (final tag in <String>[
                  ..._soundsLike.where((t) => !_suggestions.contains(t)),
                  ..._suggestions,
                ])
                  FilterChip(
                    label: Text(tag),
                    selected: _soundsLike.contains(tag),
                    onSelected: (on) => setState(() {
                      if (on) {
                        if (_soundsLike.length < _maxSounds) {
                          _soundsLike.add(tag);
                        }
                      } else {
                        _soundsLike.remove(tag);
                      }
                    }),
                    showCheckmark: false,
                    selectedColor: AppColors.gold.withValues(alpha: 0.18),
                    backgroundColor: AppColors.raised,
                    side: BorderSide(
                      color: _soundsLike.contains(tag)
                          ? AppColors.gold
                          : AppColors.line,
                    ),
                    labelStyle: TextStyle(
                      color: _soundsLike.contains(tag)
                          ? AppColors.gold
                          : AppColors.text,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _ownWords,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _addOwnWords(),
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Or your own words',
                prefixIcon: const Icon(Icons.add_rounded, size: 18),
                suffixIcon: TextButton(
                  onPressed: _addOwnWords,
                  child: const Text('Add'),
                ),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _soundsLike.length >= _maxSounds
                  ? 'Five is the most. Take one off to add another — a '
                      'profile listing everything has said nothing.'
                  : '${_maxSounds - _soundsLike.length} more if you want '
                      'them. Fewer and sharper beats more.',
              style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
            ),
            const SizedBox(height: 20),
            const _SheetHeading('Where you are'),
            const SizedBox(height: 4),
            // Says the limit out loud. A location field that could mean a
            // street address is one people fill in and then worry about; a
            // field that says "a city, nothing finer" is one they can answer
            // without thinking twice.
            const Text(
              'A city, nothing finer. We never ask your phone where you are.',
              style:
                  TextStyle(color: AppColors.muted, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _city,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'City',
                hintText: 'Glasgow',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            for (final option in _visibilities)
              InkWell(
                onTap: () => setState(() => _visibility = option.value),
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(
                        _visibility == option.value
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_unchecked_rounded,
                        size: 19,
                        color: _visibility == option.value
                            ? AppColors.cyan
                            : AppColors.muted,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              option.label,
                              style: const TextStyle(
                                color: AppColors.text,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              option.why,
                              style: const TextStyle(
                                color: AppColors.muted,
                                fontSize: 11.5,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                _Presence(
                  discoverable: _discoverable,
                  city: _city.text.trim(),
                  locationVisibility: _visibility,
                  plays: _plays.toList(growable: false),
                  soundsLike: _soundsLike.toList(growable: false),
                ),
              ),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
              ),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetHeading extends StatelessWidget {
  const _SheetHeading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        color: AppColors.text,
        fontSize: 11,
        fontWeight: FontWeight.w900,
        letterSpacing: 1.3,
      ),
    );
  }
}

/// Writing the one thing on a profile nobody counted.
///
/// Three hundred characters, and the counter is visible from the first
/// keystroke rather than appearing at the limit — a field that only tells you
/// about its cap once you have hit it has already wasted somebody's sentence.
class _BioDialog extends StatefulWidget {
  const _BioDialog({required this.initial});

  final String initial;

  @override
  State<_BioDialog> createState() => _BioDialogState();
}

class _BioDialogState extends State<_BioDialog> {
  late final TextEditingController _text =
      TextEditingController(text: widget.initial);

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final left = 300 - _text.text.characters.length;
    return AlertDialog(
      backgroundColor: AppColors.raised,
      title: const Text('About you'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'Whatever you would tell somebody who asked what you play.',
            style: TextStyle(color: AppColors.muted, fontSize: 12.5),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _text,
            autofocus: true,
            maxLines: 5,
            minLines: 3,
            maxLength: 300,
            // The counter is the whole point of maxLength here; hiding it and
            // then silently refusing the 301st character is the version of
            // this that annoys people.
            style: const TextStyle(color: AppColors.text, fontSize: 15),
            decoration: const InputDecoration(
              hintText: 'Sing mostly, write when nobody is listening…',
              hintStyle: TextStyle(color: AppColors.muted),
            ),
          ),
          if (left < 0)
            const Text(
              'A bit long — it will be cut at 300.',
              style: TextStyle(color: AppColors.orange, fontSize: 12),
            ),
        ],
      ),
      actions: <Widget>[
        // Clearing it is a first-class action rather than "delete all the
        // text and save". A field you can fill in and not empty is not a
        // field.
        if (widget.initial.trim().isNotEmpty)
          TextButton(
            onPressed: () => Navigator.pop(context, ''),
            style: TextButton.styleFrom(foregroundColor: AppColors.muted),
            child: const Text('Take it down'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _text.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
