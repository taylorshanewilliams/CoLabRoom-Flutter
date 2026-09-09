import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../data/music_repository.dart';
import '../../domain/music_models.dart';
import '../../services/current_route.dart';
import '../../services/now_playing.dart';
import '../../services/user_facing_error.dart';
import '../../widgets/player_face.dart';
import 'ask_musician_sheet.dart';
import 'report_sheet.dart';

/// Somewhere to sit.
///
/// Every other surface in this app asks you to decide something first: which
/// room, which song, which filter. This one asks nothing. It plays, and
/// you swipe when you have heard enough — which is the only browsing gesture
/// that works for audio, because you cannot skim a recording the way you skim
/// a list of titles.
///
/// **One song at a time, filling the screen.** A scrolling list of cards that
/// autoplay gives you overlapping tracks and no idea what you are hearing.
/// Full-screen makes "this is playing now" unambiguous, which is the whole
/// reason the pattern works everywhere else it is used.
///
/// **And it is not an infinite feed.** At eight songs an endless scroll runs
/// out in thirty seconds and reads as broken. This is a session with an end,
/// which is an honest thing to be at any size — and it becomes endless on its
/// own when there is enough, with no change here.
class ListenScreen extends StatefulWidget {
  const ListenScreen({required this.repository, this.part, super.key});

  final MusicRepository repository;

  /// Narrows to songs asking for one thing, when somebody arrived from a
  /// filter. Null is everything.
  final String? part;

  @override
  State<ListenScreen> createState() => _ListenScreenState();
}

class _ListenScreenState extends State<ListenScreen> {
  final PageController _pages = PageController();

  /// The app's one player, not a second one.
  ///
  /// This screen had its own, which was fine while it was the only thing
  /// that could make a sound. Now that every list has a play button, a
  /// private player here would mean a row still playing underneath the
  /// stage — two songs at once, and no way for either to know.
  final NowPlaying _now = NowPlaying.instance;

  List<FeedTrack> _tracks = const <FeedTrack>[];
  int _index = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    CurrentRoute.enter('Listen');
    _now.addListener(_onPlayerChanged);
    // On to the next one rather than silence. Somebody who let a song finish
    // has said they liked it enough to hear all of it, and stopping there
    // would end the session at exactly the wrong moment.
    _now.onFinished = _next;
    unawaited(_load());
  }

  void _onPlayerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _now.removeListener(_onPlayerChanged);
    // Only if it is still ours. Leaving the stage should stop the music, but
    // not if something else has already taken the player over.
    if (_now.onFinished == _next) _now.onFinished = null;
    unawaited(_now.stop());
    _pages.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final tracks =
          await widget.repository.openMicFeed(limit: 12, part: widget.part);
      // The whole page signed at once. Twelve requests instead of one is the
      // difference between a swipe that plays and a swipe that waits.
      await _now.streams.urlsFor(
        tracks.map((t) => t.storagePath).where((p) => p.isNotEmpty),
      );
      if (!mounted) return;
      setState(() {
        _tracks = tracks;
        _loading = false;
      });
      if (tracks.isNotEmpty) unawaited(_playAt(0));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = reportAndDescribe(
          error,
          service: 'app',
          stage: 'open_mic_feed',
          route: 'Listen',
        );
      });
    }
  }

  Future<void> _playAt(int index) async {
    if (index < 0 || index >= _tracks.length) return;
    final track = _tracks[index];
    if (track.storagePath.isEmpty) return;
    await _now.play(
      track.storagePath,
      knownLength: track.durationMs != null
          ? Duration(milliseconds: track.durationMs!)
          : null,
      // So leaving the stage leaves the bar behind with the song still in
      // it, rather than a bar that cannot say what it is playing.
      title: track.title,
      byline: track.ownerName,
      songId: track.id,
    );
  }

  void _next() {
    if (_index + 1 >= _tracks.length) return;
    _pages.animateToPage(
      _index + 1,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _onPage(int index) async {
    setState(() => _index = index);
    await _playAt(index);
  }

  Future<void> _offer(FeedTrack track) async {
    final me =
        await widget.repository.loadMusician(widget.repository.currentUserId);
    if (!mounted || me == null) return;
    await _now.pause();
    if (!mounted) return;
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.deepNavy,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
        ),
        child: AskMusicianSheet(musician: me, repository: widget.repository),
      ),
    );
    if (!mounted) return;
    if (sent == true) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('Sent. ${track.ownerName} will hear about it.'),
        ));
    }
    await _now.resume();
  }

  Future<void> _report(FeedTrack track) async {
    await _now.pause();
    if (!mounted) return;
    final sent = await showReportSheet(
      context,
      repository: widget.repository,
      kind: 'song',
      about: track.title,
      projectId: track.id,
    );
    if (!mounted) return;
    if (sent) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('Report sent. Thank you — somebody reads every one.'),
        ));
    }
    await _now.resume();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.ink,
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: AppColors.gold))
            : _tracks.isEmpty
                ? _NothingUp(error: _error)
                : Stack(
                    children: <Widget>[
                      PageView.builder(
                        controller: _pages,
                        scrollDirection: Axis.vertical,
                        onPageChanged: (i) => unawaited(_onPage(i)),
                        itemCount: _tracks.length,
                        itemBuilder: (context, i) => _TrackPage(
                          track: _tracks[i],
                          playing: i == _index && _now.playing,
                          played: i == _index ? _now.position : Duration.zero,
                          onPlayPause: () => unawaited(
                            _now.toggle(_tracks[i].storagePath),
                          ),
                          onOffer: () => unawaited(_offer(_tracks[i])),
                          onReport: () => unawaited(_report(_tracks[i])),
                        ),
                      ),
                      Positioned(
                        top: 4,
                        left: 4,
                        child: IconButton(
                          tooltip: 'Back',
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close_rounded,
                              color: AppColors.muted),
                        ),
                      ),
                      // Where you are in the session, not in the song. It
                      // says the room has an end, which is the honest thing
                      // to say when there are eight songs in it.
                      Positioned(
                        top: 14,
                        right: 16,
                        child: Text(
                          '${_index + 1} of ${_tracks.length}',
                          style: const TextStyle(
                              color: AppColors.muted, fontSize: 11.5),
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }
}

/// One song, filling the screen.
class _TrackPage extends StatelessWidget {
  const _TrackPage({
    required this.track,
    required this.playing,
    required this.played,
    required this.onPlayPause,
    required this.onOffer,
    required this.onReport,
  });

  final FeedTrack track;
  final bool playing;
  final Duration played;
  final VoidCallback onPlayPause;
  final VoidCallback onOffer;
  final VoidCallback onReport;

  @override
  Widget build(BuildContext context) {
    final total = track.durationMs ?? 0;
    final progress = total > 0
        ? (played.inMilliseconds / total).clamp(0.0, 1.0).toDouble()
        : 0.0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 56, 24, 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Spacer(),
          // Why this one reached you, before anything else on the card.
          //
          // A feed that orders itself and does not say so is one nobody can
          // trust or argue with — and the wildcards especially read as
          // random until the screen admits that is exactly what they are.
          if (track.reason.isNotEmpty) ...<Widget>[
            Text(
              track.reason.toUpperCase(),
              style: TextStyle(
                color: track.reason.startsWith('Needs')
                    ? AppColors.cyan
                    : AppColors.muted,
                fontSize: 10.5,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.1,
              ),
            ),
            const SizedBox(height: 14),
          ],
          // The only moving thing on the screen, and it moves because the
          // song is playing. A still page with audio coming out of it feels
          // broken in a way that is hard to name and easy to notice.
          //
          // Tapping it stops and starts. The gesture everybody already tries
          // on a waveform, and without it the screen has no pause at all —
          // you could only silence a song by swiping away from it.
          Semantics(
            button: true,
            label: playing ? 'Pause' : 'Play',
            child: GestureDetector(
              onTap: onPlayPause,
              behavior: HitTestBehavior.opaque,
              child: _Bars(progress: progress, alive: playing),
            ),
          ),
          const SizedBox(height: 34),
          Text(
            track.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 30,
              fontWeight: FontWeight.w900,
              height: 1.1,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              PlayerFace(name: track.ownerName, size: 26),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  track.ownerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AppColors.muted, fontSize: 14),
                ),
              ),
              if (track.musicalKey != null)
                Text(
                  track.musicalKey!,
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
          // The line that makes this feed this app's and nobody else's. Every
          // other feed shows you what a thing *is*; this one shows you what it
          // is missing, which is an invitation rather than a broadcast.
          if (track.wants.isNotEmpty) ...<Widget>[
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.cyan.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.cyan.withValues(alpha: 0.5)),
              ),
              child: Text(
                track.wants,
                style: const TextStyle(
                  color: AppColors.cyan,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
          if (track.askNote.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              '“${track.askNote.trim()}”',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.muted,
                fontSize: 14,
                height: 1.45,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          const Spacer(),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton.icon(
                  onPressed: onOffer,
                  icon: const Icon(Icons.pan_tool_alt_outlined, size: 18),
                  label: Text(
                    track.isAsking ? 'I could play that' : 'Offer to play',
                    style: const TextStyle(
                        fontSize: 14.5, fontWeight: FontWeight.w800),
                  ),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                    backgroundColor: AppColors.cyan,
                    foregroundColor: AppColors.ink,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Report this song',
                onPressed: onReport,
                icon: const Icon(Icons.flag_outlined,
                    size: 19, color: AppColors.muted),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Center(
            child: Text(
              'Swipe up for the next one',
              style: TextStyle(color: AppColors.line, fontSize: 11.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// A row of bars that fills as the song plays.
///
/// Not a real waveform — the audio is streaming and never decoded on the
/// phone, so drawing its actual shape would mean downloading the thing this
/// whole screen exists to avoid downloading. This is honest about what it is:
/// a fixed pattern that fills with the playhead, so the screen moves and the
/// position is legible without pretending to describe the sound.
class _Bars extends StatelessWidget {
  const _Bars({required this.progress, required this.alive});

  final double progress;
  final bool alive;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 78,
      child: LayoutBuilder(
        builder: (context, constraints) {
          const count = 44;
          final width = constraints.maxWidth / count;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              for (var i = 0; i < count; i += 1)
                SizedBox(
                  width: width,
                  child: Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      width: math.max(2, width - 3),
                      // A fixed pseudo-random shape, so it reads as a
                      // waveform rather than a progress bar, and is the same
                      // every time the same song is on screen.
                      height: 10 +
                          52 *
                              (0.35 +
                                  0.65 *
                                      (0.5 +
                                          0.5 *
                                              math.sin(i * 1.7) *
                                              math.cos(i * 0.6))),
                      decoration: BoxDecoration(
                        color: i / count <= progress
                            ? AppColors.cyan
                            : AppColors.line,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _NothingUp extends StatelessWidget {
  const _NothingUp({required this.error});

  final String? error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.graphic_eq_rounded, size: 38, color: AppColors.line),
            const SizedBox(height: 14),
            const Text(
              'Nothing to listen to yet',
              style: TextStyle(
                color: AppColors.text,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Songs turn up here when somebody puts one on the Open Mic. '
              'Yours can be the first.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: AppColors.muted, fontSize: 13.5, height: 1.5),
            ),
            if (error != null) ...<Widget>[
              const SizedBox(height: 14),
              Text(
                error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.orange, fontSize: 12.5),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
