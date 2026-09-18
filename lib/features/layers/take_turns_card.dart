import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/loop_round.dart';
import '../../domain/music_models.dart' show RoomMember;
import '../../domain/song_analysis_models.dart' show StructureSection;
import '../../services/audio_source_for.dart';
import '../../services/song_layer_service.dart' show SharedLayer;
import '../workspace/practice_rules.dart';
import 'take_turns.dart';

/// A round on the takes screen: the passage, the order, whose turn it is,
/// and the conversation so far.
///
/// Every Musician, Same Song, 17 September 2026, slice 33. The card says who
/// is in and who is up, in names and words. It never says how many have
/// played, how long anybody has had, or who has not: "Skip me" is free and
/// silent, and a card that kept a tally would be the announcement the skip
/// was promised not to be. A seat that went quiet is simply not in the list
/// the database sends, so there is nothing here that could show it.
///
/// Hearing it back is this card's own business. It writes the turns end to
/// end as one file and plays that on a player of its own, clear of the mix,
/// the way a spoken note plays: the takes screen's transport, playhead and
/// mix are left exactly as they were.
class TakeTurnsCard extends StatefulWidget {
  const TakeTurnsCard({
    required this.round,
    required this.passage,
    required this.me,
    required this.conversation,
    required this.draft,
    required this.canSit,
    required this.canRecordHere,
    required this.canHear,
    required this.canEnd,
    required this.busy,
    required this.onRecord,
    required this.onHandIn,
    required this.onSkip,
    required this.onJoin,
    required this.onEnd,
    required this.writeConversation,
    this.onWillHear,
    this.hush,
    super.key,
  });

  final LoopRound round;

  /// The passage as this phone names it (TakeTurns.passageOf).
  final PracticeLoop passage;
  final String? me;

  /// The turns that can be heard here, in order (TakeTurns.conversation).
  final List<LoopSeat> conversation;

  /// The take this person recorded for their turn and has not handed in.
  final SharedLayer? draft;

  /// Whether this person can put a take on the song at all, and so sit in a
  /// round. A viewer reads the round and hears it, and is offered nothing
  /// else.
  final bool canSit;

  /// False in a browser, where a take cannot be recorded. Skipping, joining
  /// and handing in a draft recorded on the phone are rows, and still work.
  final bool canRecordHere;

  /// False in a browser, where there is no mix to build the file from.
  final bool canHear;

  /// Whoever started it, or the room's owner.
  final bool canEnd;

  /// True while the screen is recording, saving or loading.
  final bool busy;

  final VoidCallback onRecord;
  final ValueChanged<SharedLayer> onHandIn;
  final VoidCallback onSkip;
  final VoidCallback onJoin;
  final VoidCallback onEnd;

  /// Writes the conversation and says where. The screen does it, because
  /// the screen holds the takes and the folder the mixes live in.
  final Future<TurnsTrack> Function() writeConversation;

  /// Called before the conversation plays, so the screen can pause its own.
  final Future<void> Function()? onWillHear;

  /// Told when the screen is about to play or record, so the conversation
  /// stops first: one thing sounding at a time, and never this going down
  /// the microphone under somebody's turn.
  final Listenable? hush;

  @override
  State<TakeTurnsCard> createState() => _TakeTurnsCardState();
}

class _TakeTurnsCardState extends State<TakeTurnsCard> {
  AudioPlayer? _player;
  StreamSubscription<void>? _done;
  StreamSubscription<Duration>? _moved;

  /// The conversation while it plays, and whose turn is sounding.
  TurnsTrack? _track;
  LoopSeat? _sounding;
  bool _writing = false;
  String? _problem;

  @override
  void initState() {
    super.initState();
    widget.hush?.addListener(_hushed);
  }

  @override
  void didUpdateWidget(TakeTurnsCard old) {
    super.didUpdateWidget(old);
    if (old.hush != widget.hush) {
      old.hush?.removeListener(_hushed);
      widget.hush?.addListener(_hushed);
    }
  }

  void _hushed() {
    if (_track != null) unawaited(_stop());
  }

  @override
  void dispose() {
    widget.hush?.removeListener(_hushed);
    unawaited(_done?.cancel());
    unawaited(_moved?.cancel());
    unawaited(_player?.dispose());
    super.dispose();
  }

  Future<void> _hearIt() async {
    if (_writing) return;
    if (_track != null) {
      await _stop();
      return;
    }
    setState(() {
      _writing = true;
      _problem = null;
    });
    try {
      await widget.onWillHear?.call();
      final track = await widget.writeConversation();
      if (!mounted) return;
      final player = _player ??= AudioPlayer();
      _done ??= player.onPlayerComplete.listen((_) {
        if (mounted) {
          setState(() {
            _track = null;
            _sounding = null;
          });
        }
      });
      _moved ??= player.onPositionChanged.listen((position) {
        final playing = _track;
        if (!mounted || playing == null) return;
        final seat = playing.turnAt(position.inMilliseconds);
        if (seat?.userId != _sounding?.userId) setState(() => _sounding = seat);
      });
      setState(() {
        _track = track;
        _sounding = track.turns.isEmpty ? null : track.turns.first;
        _writing = false;
      });
      await player.setReleaseMode(ReleaseMode.release);
      await player.play(audioSourceFor(track.path));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _track = null;
        _sounding = null;
        _writing = false;
        _problem = 'That would not play. Try it again in a moment.';
      });
    }
  }

  Future<void> _stop() async {
    try {
      await _player?.stop();
    } catch (_) {
      // Already stopped, or never started. Either way it is over.
    }
    if (!mounted) return;
    setState(() {
      _track = null;
      _sounding = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final round = widget.round;
    final me = widget.me;
    final mine = round.seatOf(me);
    final up = round.isUp(me);
    final draft = widget.draft;
    final blocked = widget.busy || _writing;
    // The order as everybody reads it. Your own quiet seat is yours to see,
    // and is said in its own line rather than left in the list.
    final order = <LoopSeat>[
      for (final seat in round.seats)
        if (seat.state != SeatState.out) seat,
    ];
    final sittingOut = mine != null && mine.state == SeatState.out;

    return Container(
      key: Key('take_turns_${round.id}'),
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: AppColors.raised,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cyan.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '${round.ended ? 'Took turns' : 'Taking turns'} · '
                  '${widget.passage.label}',
                  style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (widget.canEnd && !round.ended)
                PopupMenuButton<void>(
                  key: const Key('take_turns_more'),
                  tooltip: 'More',
                  padding: EdgeInsets.zero,
                  color: AppColors.surface,
                  icon: const Icon(Icons.more_horiz_rounded,
                      size: 20, color: AppColors.muted),
                  itemBuilder: (_) => <PopupMenuEntry<void>>[
                    PopupMenuItem<void>(
                      onTap: widget.onEnd,
                      child: const Text('End this round'),
                    ),
                  ],
                )
              else
                const SizedBox(width: 6, height: 36),
            ],
          ),
          if (order.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text.rich(
                key: const Key('take_turns_order'),
                TextSpan(
                  children: <InlineSpan>[
                    for (var i = 0; i < order.length; i += 1) ...<InlineSpan>[
                      // Said the way a band sorts it out in a room, and in
                      // words: an arrow is a glyph some phones do not have.
                      if (i > 0) const TextSpan(text: ', then '),
                      TextSpan(
                        text: order[i].userId != me
                            ? order[i].name
                            : i == 0
                                ? 'You'
                                : 'you',
                        style: round.upId == order[i].userId && !round.ended
                            ? const TextStyle(
                                color: AppColors.cyan,
                                fontWeight: FontWeight.w800,
                              )
                            : null,
                      ),
                    ],
                  ],
                ),
                style: const TextStyle(
                    color: AppColors.text, fontSize: 12.5, height: 1.5),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 6),
            child: Text(
              _sounding != null
                  ? (_sounding!.userId == me ? 'You' : _sounding!.name)
                  : sittingOut && !round.ended
                      ? 'You are sitting this one out.'
                      : draft != null && up
                          ? 'Only you can hear your turn until you hand it in.'
                          : TakeTurns.lineFor(round, me: me),
              key: const Key('take_turns_line'),
              style: const TextStyle(
                  color: AppColors.muted, fontSize: 11.5, height: 1.4),
            ),
          ),
          if (_problem != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 6),
              child: Text(
                _problem!,
                style: const TextStyle(
                    color: AppColors.orange, fontSize: 11.5, height: 1.4),
              ),
            ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 4,
            runSpacing: 0,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              if (!round.ended && widget.canSit) ...<Widget>[
                if (up && draft != null) ...<Widget>[
                  _Action(
                    key: const Key('take_turns_hand_in'),
                    label: 'Hand it in',
                    filled: true,
                    onTap: blocked ? null : () => widget.onHandIn(draft),
                  ),
                  if (widget.canRecordHere)
                    _Action(
                      key: const Key('take_turns_again'),
                      label: 'Go again',
                      onTap: blocked ? null : widget.onRecord,
                    ),
                ] else if (up && widget.canRecordHere)
                  _Action(
                    key: const Key('take_turns_record'),
                    label: 'Record my turn',
                    filled: true,
                    onTap: blocked ? null : widget.onRecord,
                  ),
                if (mine != null && mine.state == SeatState.waiting)
                  _Action(
                    key: const Key('take_turns_skip'),
                    label: 'Skip me',
                    onTap: blocked ? null : widget.onSkip,
                  ),
                if (mine == null)
                  _Action(
                    key: const Key('take_turns_join'),
                    label: "I'm in",
                    onTap: blocked ? null : widget.onJoin,
                  ),
                if (sittingOut)
                  _Action(
                    key: const Key('take_turns_back_in'),
                    label: 'Count me back in',
                    onTap: blocked ? null : widget.onJoin,
                  ),
              ],
              if (widget.canHear && widget.conversation.isNotEmpty)
                _Action(
                  key: const Key('take_turns_hear'),
                  label: _track != null ? 'Stop' : 'Hear it',
                  icon: _track != null
                      ? Icons.stop_rounded
                      : Icons.play_arrow_rounded,
                  onTap: widget.busy ? null : () => unawaited(_hearIt()),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.label,
    required this.onTap,
    this.filled = false,
    this.icon,
    super.key,
  });

  final String label;
  final VoidCallback? onTap;
  final bool filled;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      label,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
    );
    if (filled) {
      return Padding(
        padding: const EdgeInsets.only(right: 4),
        child: FilledButton(
          onPressed: onTap,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.cyan,
            foregroundColor: AppColors.ink,
            visualDensity: VisualDensity.compact,
          ),
          child: text,
        ),
      );
    }
    final style = TextButton.styleFrom(
      foregroundColor: AppColors.cyan,
      disabledForegroundColor: AppColors.line,
      visualDensity: VisualDensity.compact,
    );
    final glyph = icon;
    return glyph == null
        ? TextButton(onPressed: onTap, style: style, child: text)
        : TextButton.icon(
            onPressed: onTap,
            style: style,
            icon: Icon(glyph, size: 18),
            label: text,
          );
  }
}

/// What somebody chose when starting a round.
class TurnsToStart {
  const TurnsToStart({required this.passage, required this.order});

  final PracticeLoop passage;

  /// Whoever wants in, first to last.
  final List<String> order;
}

/// Asks for the passage and the order, and returns them, or null when the
/// sheet is dismissed.
///
/// The passage is a part of the song or a run of bars, offered from where
/// the playhead is. The order is built by tapping names, in the order
/// somebody taps them -- the way a band sorts it out in a room ("you, then
/// me, then Sam") -- and is shown as names in a row, never as numbers
/// against people. Everybody else can join themselves afterwards.
Future<TurnsToStart?> askForTurns(
  BuildContext context, {
  required PracticeLoop offered,
  required List<RoomMember> people,
  required String? me,
  List<StructureSection> sections = const <StructureSection>[],
  List<int> downbeatsMs = const <int>[],
  int? songEndMs,
}) {
  return showModalBottomSheet<TurnsToStart>(
    context: context,
    backgroundColor: AppColors.deepNavy,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => _StartTurnsSheet(
      offered: offered,
      people: people,
      me: me,
      sections: sections,
      downbeatsMs: downbeatsMs,
      songEndMs: songEndMs,
    ),
  );
}

class _StartTurnsSheet extends StatefulWidget {
  const _StartTurnsSheet({
    required this.offered,
    required this.people,
    required this.me,
    required this.sections,
    required this.downbeatsMs,
    required this.songEndMs,
  });

  final PracticeLoop offered;
  final List<RoomMember> people;
  final String? me;
  final List<StructureSection> sections;
  final List<int> downbeatsMs;
  final int? songEndMs;

  @override
  State<_StartTurnsSheet> createState() => _StartTurnsSheetState();
}

class _StartTurnsSheetState extends State<_StartTurnsSheet> {
  late PracticeLoop _passage = widget.offered;
  late final List<String> _order = <String>[
    // The person starting it goes first until they say otherwise.
    if (widget.me != null &&
        widget.people.any((person) => person.userId == widget.me))
      widget.me!,
  ];

  bool get _hasBars => widget.downbeatsMs.length >= 2;

  void _setBars(int first, int last) {
    final count = widget.downbeatsMs.length;
    final from = first.clamp(1, count).toInt();
    final to = last.clamp(from, count).toInt();
    final bars = barLoop(
      firstBar: from,
      lastBar: to,
      downbeatsMs: widget.downbeatsMs,
      songEndMs: widget.songEndMs,
    );
    if (bars == null) return;
    setState(() {
      // Named the way it will be named when it comes back from the server,
      // so bars that happen to be exactly the chorus say Chorus here too.
      _passage = loopFor(
            bars.startMs,
            bars.endMs,
            sections: widget.sections,
            downbeatsMs: widget.downbeatsMs,
          ) ??
          bars;
    });
  }

  String _nameOf(String id) {
    if (id == widget.me) return 'You';
    for (final person in widget.people) {
      if (person.userId == id) return person.displayName;
    }
    return 'Somebody';
  }

  @override
  Widget build(BuildContext context) {
    final parts = sectionLoops(widget.sections);
    // The bars the passage covers, for the two steppers. A part of the song
    // is a run of bars too, so picking "Chorus" moves them with it.
    final covered = loopFor(
      _passage.startMs,
      _passage.endMs,
      downbeatsMs: widget.downbeatsMs,
    );
    final first = covered?.firstBar ?? 1;
    final last = covered?.lastBar ?? first;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
          20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            TakeTurns.startLabel,
            style: TextStyle(
                color: AppColors.text,
                fontSize: 18,
                fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          const Text(
            'Everybody records over the same bars, one after the other, and '
            'it plays back as one conversation.',
            style: TextStyle(color: AppColors.muted, fontSize: 12.5, height: 1.45),
          ),
          const SizedBox(height: 16),
          Text(
            _passage.label,
            key: const Key('start_turns_passage'),
            style: const TextStyle(
                color: AppColors.cyan,
                fontSize: 15,
                fontWeight: FontWeight.w800),
          ),
          if (parts.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 2,
              children: <Widget>[
                for (final part in parts)
                  ChoiceChip(
                    label: Text(part.label),
                    selected: part == _passage,
                    backgroundColor: AppColors.raised,
                    selectedColor: AppColors.cyan.withValues(alpha: 0.22),
                    labelStyle:
                        const TextStyle(color: AppColors.text, fontSize: 12.5),
                    side: BorderSide(
                        color: AppColors.cyan.withValues(alpha: 0.25)),
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => setState(() => _passage = part),
                  ),
              ],
            ),
          ],
          if (_hasBars) ...<Widget>[
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                _BarStepper(
                  label: 'From bar',
                  value: first,
                  keyPrefix: 'start_turns_from',
                  onChanged: (value) =>
                      _setBars(value, value > last ? value : last),
                ),
                const SizedBox(width: 16),
                _BarStepper(
                  label: 'to bar',
                  value: last,
                  keyPrefix: 'start_turns_to',
                  onChanged: (value) =>
                      _setBars(value < first ? value : first, value),
                ),
              ],
            ),
          ],
          const SizedBox(height: 18),
          const Text(
            "Who's in, in order",
            style: TextStyle(
                color: AppColors.text,
                fontSize: 13,
                fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(
            _order.isEmpty
                ? 'Tap names in the order you will go.'
                // In words, the way it is said in a room: "you, then Sam".
                : <String>[
                    for (var i = 0; i < _order.length; i += 1)
                      i > 0 && _order[i] == widget.me
                          ? 'you'
                          : _nameOf(_order[i]),
                  ].join(', then '),
            key: const Key('start_turns_order'),
            style: const TextStyle(
                color: AppColors.muted, fontSize: 12.5, height: 1.45),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 2,
            children: <Widget>[
              for (final person in widget.people)
                FilterChip(
                  key: Key('start_turns_person_${person.userId}'),
                  label: Text(_nameOf(person.userId)),
                  selected: _order.contains(person.userId),
                  showCheckmark: false,
                  backgroundColor: AppColors.raised,
                  selectedColor: AppColors.cyan.withValues(alpha: 0.22),
                  labelStyle:
                      const TextStyle(color: AppColors.text, fontSize: 12.5),
                  side:
                      BorderSide(color: AppColors.cyan.withValues(alpha: 0.25)),
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => setState(() {
                    // Tapped again, they are out; tapped back in, they go
                    // to the end -- the order is the order of the taps.
                    if (!_order.remove(person.userId)) {
                      _order.add(person.userId);
                    }
                  }),
                ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'Anybody can join later, and anybody can skip. Skipping is free, '
            'and nobody is told.',
            style: TextStyle(color: AppColors.muted, fontSize: 11.5, height: 1.4),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const Key('start_turns_go'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.cyan,
                foregroundColor: AppColors.ink,
              ),
              onPressed: _order.isEmpty
                  ? null
                  : () => Navigator.of(context).pop(
                        TurnsToStart(
                          passage: _passage,
                          order: List<String>.unmodifiable(_order),
                        ),
                      ),
              child: const Text('Start'),
            ),
          ),
        ],
      ),
    );
  }
}

class _BarStepper extends StatelessWidget {
  const _BarStepper({
    required this.label,
    required this.value,
    required this.keyPrefix,
    required this.onChanged,
  });

  final String label;
  final int value;
  final String keyPrefix;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(label,
            style: const TextStyle(color: AppColors.muted, fontSize: 12.5)),
        IconButton(
          key: Key('${keyPrefix}_down'),
          tooltip: '$label, one earlier',
          visualDensity: VisualDensity.compact,
          onPressed: value > 1 ? () => onChanged(value - 1) : null,
          icon: const Icon(Icons.remove_rounded, size: 18),
          color: AppColors.cyan,
        ),
        Text('$value',
            style: const TextStyle(
                color: AppColors.text,
                fontSize: 14,
                fontWeight: FontWeight.w800)),
        IconButton(
          key: Key('${keyPrefix}_up'),
          tooltip: '$label, one later',
          visualDensity: VisualDensity.compact,
          onPressed: () => onChanged(value + 1),
          icon: const Icon(Icons.add_rounded, size: 18),
          color: AppColors.cyan,
        ),
      ],
    );
  }
}
