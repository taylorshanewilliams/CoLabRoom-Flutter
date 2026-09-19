import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/colabroom_theme.dart';
import '../../data/music_repository.dart';
import '../../domain/moment_note.dart';
import '../../domain/sent_take.dart';
import '../../services/now_playing.dart';
import '../../services/user_facing_error.dart';
import '../../widgets/send_on_enter.dart';
import '../layers/moment_notes.dart';

/// What came in: the takes students have sent, in one pass.
///
/// Every Musician, Same Song, 17 September 2026, build-order slice 22. "Mr.
/// Okafor opens What came in. Only sent takes appear. Space plays, N pins a
/// note at the playhead, Enter moves to the next take." A teacher with nine
/// students has been opening nine rooms to hear nine hand-ins; this is the
/// same hand-ins, read once, in the order they arrived.
///
/// What a row says is the whole of what a row says: who played it, and what
/// the song is. No date — the server sends none, so there is nothing here to
/// print. No count of what has come in, no list of who has not sent
/// anything, no duration, and nowhere to put a mark. Every one of those is
/// forbidden by the plan, and the way to go on forbidding them is to have
/// nowhere to put one.
///
/// The row in hand carries one control that is not a fact about the take:
/// the note button, which is the second half of the slice. Without it a
/// phone can listen and cannot answer, and answering is the point.
///
/// Web first, because the pass is a desk job, and it works on a phone
/// because a teacher between lessons has one in their hand.

/// What the desk plays takes through.
///
/// [NowPlaying] in the app. A seam, because the real player reaches for a
/// platform audio player that a widget test has not got — and the keyboard
/// is the feature here, so it has to be possible to press Space in a test
/// and see what happened.
abstract class ListeningToTakes implements Listenable {
  /// Plays [take], or pauses it when it is the one already loaded.
  Future<void> toggle(SentTake take);

  /// Starts [take] from its beginning, whatever was sounding before.
  Future<void> play(SentTake take);

  Future<void> pause();

  /// Which take is loaded, playing or paused, or null when none is.
  String? get playingPath;

  bool get playing;

  /// Where the playhead is, which is what a note is pinned at.
  int get atMs;
}

/// The app's one player, as the desk needs it.
class _ThroughNowPlaying implements ListeningToTakes {
  const _ThroughNowPlaying();

  NowPlaying get _now => NowPlaying.instance;

  @override
  void addListener(VoidCallback listener) => _now.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _now.removeListener(listener);

  @override
  Future<void> toggle(SentTake take) => _now.toggle(
        take.storagePath,
        title: take.songTitle,
        byline: take.studentName,
        songId: take.projectId,
      );

  @override
  Future<void> play(SentTake take) => _now.play(
        take.storagePath,
        title: take.songTitle,
        byline: take.studentName,
        songId: take.projectId,
      );

  @override
  Future<void> pause() => _now.pause();

  @override
  String? get playingPath => _now.path;

  @override
  bool get playing => _now.playing;

  @override
  int get atMs => _now.position.inMilliseconds;
}

class WhatCameInScreen extends StatefulWidget {
  const WhatCameInScreen({
    required this.repository,
    this.listening = const _ThroughNowPlaying(),
    this.onKeyboard,
    super.key,
  });

  final MusicRepository repository;

  /// What plays the takes.
  final ListeningToTakes listening;

  /// Whether this device types on a keyboard. A test passes it.
  final bool? onKeyboard;

  @override
  State<WhatCameInScreen> createState() => _WhatCameInScreenState();
}

class _WhatCameInScreenState extends State<WhatCameInScreen> {
  List<SentTake> _came = const <SentTake>[];
  bool _loading = true;
  String? _error;

  /// The one in hand: what Space plays, what N pins a note on, and what
  /// Enter moves off.
  int _at = 0;

  @override
  void initState() {
    super.initState();
    widget.listening.addListener(_playerMoved);
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.listening.removeListener(_playerMoved);
    super.dispose();
  }

  /// What the screen last drew of the player, so a position tick four times
  /// a second does not rebuild a list that has not changed.
  String? _drawnPath;
  bool _drawnPlaying = false;

  /// The player is the one that knows what is sounding, so the row in hand
  /// follows it rather than keeping a second opinion. Tapping a row down the
  /// list and then pressing N pins the note on what is playing, which is
  /// what the teacher is listening to.
  void _playerMoved() {
    if (!mounted) return;
    final path = widget.listening.playingPath;
    final playing = widget.listening.playing;
    var at = _at;
    if (path != null) {
      final index = _came.indexWhere((take) => take.storagePath == path);
      if (index >= 0) at = index;
    }
    if (path == _drawnPath && playing == _drawnPlaying && at == _at) return;
    setState(() {
      _drawnPath = path;
      _drawnPlaying = playing;
      _at = at;
    });
  }

  Future<void> _load() async {
    try {
      final came = await widget.repository.takesSentToMe();
      if (!mounted) return;
      setState(() {
        _came = came;
        _at = _at < came.length ? _at : 0;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = reportAndDescribe(
          error,
          service: 'app',
          stage: 'what_came_in.load',
          route: 'What came in',
        );
      });
    }
  }

  SentTake? get _inHand =>
      _at >= 0 && _at < _came.length ? _came[_at] : null;

  bool _isSounding(SentTake take) =>
      widget.listening.playingPath == take.storagePath;

  /// Space, and a tap on a row: this one, playing or paused.
  Future<void> _hear(int index) async {
    if (index < 0 || index >= _came.length) return;
    final take = _came[index];
    if (index != _at) setState(() => _at = index);
    await widget.listening.toggle(take);
  }

  /// Enter: the next one, playing.
  ///
  /// Playing rather than merely selected, because this screen is one pass
  /// through what arrived and the only reason to move on is to hear the next
  /// one. The last take is the last: Enter on it stays there rather than
  /// starting the queue again.
  Future<void> _next() async {
    if (_at + 1 >= _came.length) return;
    final take = _came[_at + 1];
    setState(() => _at += 1);
    await widget.listening.play(take);
  }

  /// N, and the note button: words at this moment of this take (0141).
  ///
  /// Playback stops first, so the moment stays where the teacher heard it
  /// while they are typing — and so the thing they are writing about is not
  /// still going in their ear.
  ///
  /// The moment is put on the song's clock before anything else happens. The
  /// desk plays the take's own file; a moment note is a place in the song,
  /// which is what the Takes screen draws marks against and what the student
  /// will tap to hear it again. A take punched in at the last chorus starts
  /// at 1:30 of the song and at 0:00 of its file, so "five seconds in" is
  /// 1:35 of the song and not 0:05 of it. See [SentTake.songMsFor].
  Future<void> _pinNote() async {
    final take = _inHand;
    if (take == null) return;
    final at = take.songMsFor(_isSounding(take) ? widget.listening.atMs : 0);
    if (widget.listening.playing) await widget.listening.pause();
    if (!mounted) return;
    final draft = await showMomentNoteSheet(
      context,
      atMs: at,
      on: <NoteTarget>[
        NoteTarget(id: take.takeId, label: '${take.studentName} · ${take.songTitle}'),
      ],
      initialLayerId: take.takeId,
    );
    if (draft == null || !mounted) return;
    try {
      await widget.repository.addMomentNote(
        projectId: take.projectId,
        layerId: take.takeId,
        atMs: at,
        body: draft.body,
      );
      if (!mounted) return;
      // Said once, and then gone. The note is on the take, where the student
      // reads it; nothing on this screen counts how many there are.
      _say('Noted at ${MomentNote.clockOf(at)}.');
    } catch (error) {
      if (!mounted) return;
      _say(reportAndDescribe(
        error,
        service: 'app',
        stage: 'what_came_in.note',
        route: 'What came in',
        projectId: take.projectId,
      ));
    }
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('What came in'),
      ),
      body: SafeArea(
        child: ListeningDeskKeys(
          onKeyboard: widget.onKeyboard,
          onPlayPause: () => unawaited(_hear(_at)),
          onPinNote: () => unawaited(_pinNote()),
          onNext: () => unawaited(_next()),
          child: _body(),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final error = _error;
    if (error != null) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(22, 24, 22, 32),
        children: <Widget>[
          Text(error, style: const TextStyle(color: AppColors.muted, fontSize: 14, height: 1.45)),
          const SizedBox(height: 16),
          OutlinedButton(
            key: const Key('what_came_in_retry'),
            onPressed: () {
              setState(() => _loading = true);
              unawaited(_load());
            },
            child: const Text('Try again'),
          ),
        ],
      );
    }
    if (_came.isEmpty) {
      return ListView(
        key: const Key('what_came_in_list'),
        padding: const EdgeInsets.fromLTRB(22, 24, 22, 32),
        children: const <Widget>[
          Text(
            'Nothing has come in yet',
            key: Key('what_came_in_nothing'),
            style: TextStyle(
              color: AppColors.text,
              fontSize: 20,
              fontWeight: FontWeight.w800,
              height: 1.25,
            ),
          ),
          SizedBox(height: 10),
          Text(
            'When a student sends you a take it turns up here, with the '
            'newest at the bottom.',
            style: TextStyle(color: AppColors.muted, fontSize: 14, height: 1.45),
          ),
        ],
      );
    }
    final keys = widget.onKeyboard ?? typesOnAKeyboard;
    return ListView(
      key: const Key('what_came_in_list'),
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 32),
      children: <Widget>[
        if (keys) ...<Widget>[
          const Text(
            'Space plays. N pins a note where you are. Enter moves on.',
            key: Key('what_came_in_keys'),
            style: TextStyle(color: AppColors.muted, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 14),
        ],
        for (var index = 0; index < _came.length; index += 1) ...<Widget>[
          _TakeRow(
            take: _came[index],
            inHand: index == _at,
            sounding: _isSounding(_came[index]),
            playing: _isSounding(_came[index]) && widget.listening.playing,
            onTap: () => unawaited(_hear(index)),
            // The answer, on the row it is about. On a phone there is no N
            // to press, and a teacher between lessons with the app in their
            // hand is exactly who this page is for — without this they can
            // hear Maya's take and then have to leave, find her room among
            // nine, open the song and find the moment again. One control,
            // on the one row in hand, so the list stays a list.
            onNote: index == _at ? () => unawaited(_pinNote()) : null,
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

/// Space, N and Enter, where there is a keyboard.
///
/// The same rule as [SendOnEnter] and [PinAtPlayheadKey]: a desk gets the
/// keys somebody going through fifteen takes would want, and a phone's own
/// keyboard is left alone. Every Musician, Same Song, 17 September 2026 —
/// the teacher's pass is Space, N, Enter.
class ListeningDeskKeys extends StatelessWidget {
  const ListeningDeskKeys({
    required this.onPlayPause,
    required this.onPinNote,
    required this.onNext,
    required this.child,
    this.onKeyboard,
    super.key,
  });

  final VoidCallback onPlayPause;
  final VoidCallback onPinNote;
  final VoidCallback onNext;
  final Widget child;

  /// Whether this device types on a keyboard. A test passes it.
  final bool? onKeyboard;

  @override
  Widget build(BuildContext context) {
    if (!(onKeyboard ?? typesOnAKeyboard)) return child;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.space): onPlayPause,
        const SingleActivator(LogicalKeyboardKey.keyN): onPinNote,
        const SingleActivator(LogicalKeyboardKey.enter): onNext,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): onNext,
      },
      // Shortcuts only fire inside the focused subtree, and this screen has
      // nothing else that wants the keyboard: the one text field is in the
      // note sheet, which is a route of its own above this one.
      child: Focus(autofocus: true, child: child),
    );
  }
}

/// One take that came in: who played it, and what the song is.
class _TakeRow extends StatelessWidget {
  const _TakeRow({
    required this.take,
    required this.inHand,
    required this.sounding,
    required this.playing,
    required this.onTap,
    required this.onNote,
  });

  final SentTake take;

  /// The one the keys are about, drawn so that Space and N are obviously
  /// about this row and not the one somebody last tapped.
  final bool inHand;

  final bool sounding;
  final bool playing;
  final VoidCallback onTap;

  /// Words at this moment, for the row in hand. Null on every other row:
  /// one answer at a time, because there is one playhead.
  final VoidCallback? onNote;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: inHand ? AppColors.raised : AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: Key('came_in_${take.takeId}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: inHand ? AppColors.cyan.withValues(alpha: 0.55) : AppColors.line,
            ),
          ),
          child: Row(
            children: <Widget>[
              // Drawn, not pressed: the whole row is the button, so a
              // second tap target inside it would be two ways to do one
              // thing and two things for a screen reader to read out.
              ExcludeSemantics(
                child: Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: sounding ? AppColors.cyan : AppColors.cyan.withValues(alpha: 0.14),
                  ),
                  child: Icon(
                    playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: 20,
                    color: sounding ? AppColors.ink : AppColors.cyan,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      take.studentName,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      take.songTitle,
                      style: const TextStyle(color: AppColors.muted, fontSize: 13.5),
                    ),
                  ],
                ),
              ),
              if (onNote != null)
                IconButton(
                  key: Key('came_in_note_${take.takeId}'),
                  onPressed: onNote,
                  tooltip: 'Note at this moment',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(
                    Icons.edit_note_rounded,
                    size: 22,
                    color: AppColors.muted,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
