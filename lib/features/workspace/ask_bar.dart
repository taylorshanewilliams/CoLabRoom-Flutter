import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../data/music_repository.dart';
import '../../domain/music_models.dart';
import '../../services/user_facing_error.dart';

/// What this song is asking for, and whether anybody has heard it.
///
/// Two controls, and between them they answer the two things a song can want
/// from the people who can see it.
///
/// **Asking** is opt-in and deliberately cheap. Most songs in a band room are
/// not requests — somebody put an idea up, which is the creative process
/// working — so nothing here nags, and a song that says nothing is the normal
/// case. But when a song *does* want something, the app has to say so, because
/// the reason a room of willing people leaves a song untouched is almost never
/// unwillingness. It is that nobody knew it was wanted.
///
/// **Heard it** is the other half, and it is the cheaper one. Until now the
/// only response this app offered was a take, which costs real effort — so an
/// idea somebody shared came back as silence, and silence reads as
/// indifference even when everyone liked it.
class AskBar extends StatefulWidget {
  const AskBar({
    required this.projectId,
    required this.repository,
    super.key,
  });

  final String projectId;
  final MusicRepository repository;

  @override
  State<AskBar> createState() => _AskBarState();
}

class _AskBarState extends State<AskBar> {
  List<SongAsk>? _asks;
  Set<String> _nods = <String>{};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(AskBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.projectId != widget.projectId) unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final asks = await widget.repository.loadAsks(widget.projectId);
      final nods = await widget.repository.loadNods(widget.projectId);
      if (!mounted) return;
      setState(() {
        _asks = asks;
        _nods = nods.toSet();
      });
    } catch (_) {
      // A song whose asks will not load is still a song worth opening. The
      // bar draws nothing rather than putting an error across the top of
      // somebody's lyrics.
      if (mounted) setState(() => _asks = const <SongAsk>[]);
    }
  }

  bool get _iHaveNodded =>
      _nods.contains(widget.repository.currentUserId);

  Future<void> _toggleNod() async {
    if (_busy) return;
    final wants = !_iHaveNodded;
    // Optimistic, because this is a one-tap gesture and a spinner on it would
    // cost more than the gesture is worth. Put back if the write fails.
    setState(() {
      _busy = true;
      if (wants) {
        _nods.add(widget.repository.currentUserId);
      } else {
        _nods.remove(widget.repository.currentUserId);
      }
    });
    try {
      await widget.repository
          .setNod(projectId: widget.projectId, heard: wants);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        if (wants) {
          _nods.remove(widget.repository.currentUserId);
        } else {
          _nods.add(widget.repository.currentUserId);
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(reportAndDescribe(error, service: 'app', stage: 'nod')),
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _ask() async {
    if (_busy) return;
    final choice = await showModalBottomSheet<String?>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.deepNavy,
      builder: (sheetContext) => _AskSheet(
        alreadyAsked: <String>{
          for (final ask in _asks ?? const <SongAsk>[])
            if (ask.isSpecific) ask.part!.trim().toLowerCase(),
        },
        openAskStanding:
            (_asks ?? const <SongAsk>[]).any((ask) => !ask.isSpecific),
      ),
    );
    if (choice == null || !mounted) return;

    setState(() => _busy = true);
    try {
      // The sheet hands back an empty string for "I don't know what it needs",
      // which is the open ask. A named part comes back as itself.
      await widget.repository.askFor(
        projectId: widget.projectId,
        part: choice.isEmpty ? null : choice,
      );
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(choice.isEmpty
            ? 'Asked the room what it needs.'
            : 'Asked the room for $choice.'),
      ));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(reportAndDescribe(error, service: 'app', stage: 'ask')),
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _close(SongAsk ask) async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.raised,
        title: Text(ask.isSpecific
            ? 'Stop asking for ${ask.part}?'
            : 'Stop asking for ideas?'),
        content: const Text(
          'The song stays exactly as it is. It just stops saying it wants '
          'something.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep asking'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Stop'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await widget.repository.closeAsk(ask);
      await _load();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text(reportAndDescribe(error, service: 'app', stage: 'ask_close')),
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final asks = _asks;
    // Nothing at all until the first load lands. A bar that appears empty and
    // then fills in is worse than one that arrives finished.
    if (asks == null) return const SizedBox.shrink();

    final heard = _nods.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          for (final ask in asks)
            _AskChip(
              label: ask.label,
              specific: ask.isSpecific,
              onClose: _busy ? null : () => unawaited(_close(ask)),
            ),
          // Labelled, always. The failure this app keeps repeating is a good
          // feature behind a glyph nobody recognises.
          TextButton.icon(
            onPressed: _busy ? null : () => unawaited(_ask()),
            icon: const Icon(Icons.campaign_outlined, size: 17),
            label: Text(asks.isEmpty ? 'Ask the room' : 'Ask for something else'),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.gold,
              disabledForegroundColor: AppColors.line,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              textStyle:
                  const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
            ),
          ),
          TextButton.icon(
            onPressed: _busy ? null : () => unawaited(_toggleNod()),
            icon: Icon(
              _iHaveNodded
                  ? Icons.hearing_rounded
                  : Icons.hearing_outlined,
              size: 17,
            ),
            // A count, not a score: it says somebody listened, and it stops
            // being interesting long before it becomes a number to chase.
            label: Text(
              _iHaveNodded
                  ? (heard > 1 ? 'Heard it · $heard' : 'Heard it')
                  : (heard > 0 ? '$heard heard it' : 'Heard it'),
            ),
            style: TextButton.styleFrom(
              foregroundColor:
                  _iHaveNodded ? AppColors.cyan : AppColors.muted,
              disabledForegroundColor: AppColors.line,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              textStyle:
                  const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _AskChip extends StatelessWidget {
  const _AskChip({
    required this.label,
    required this.specific,
    required this.onClose,
  });

  final String label;
  final bool specific;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    // The two shapes are told apart by colour as well as words, because at a
    // glance down a list of songs "open to ideas" and "needs drums" are
    // different invitations.
    final tint = specific ? AppColors.gold : AppColors.green;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 5, 4, 5),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: tint.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            label,
            style: TextStyle(
              color: tint,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
          IconButton(
            onPressed: onClose,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            padding: EdgeInsets.zero,
            tooltip: 'Stop asking',
            icon: Icon(Icons.close_rounded, size: 14, color: tint),
          ),
        ],
      ),
    );
  }
}

/// The sheet that asks what you're asking for.
///
/// The open ask is first, biggest, and needs no decision — because "I don't
/// know what this needs" is the honest state of most unfinished songs, and a
/// control that made you name a part before you could ask would turn the
/// commonest case into homework. The named parts underneath are one tap each
/// and no typing, for when you do know.
class _AskSheet extends StatelessWidget {
  const _AskSheet({
    required this.alreadyAsked,
    required this.openAskStanding,
  });

  final Set<String> alreadyAsked;
  final bool openAskStanding;

  static const List<String> _parts = <String>[
    'vocals',
    'harmony',
    'drums',
    'bass',
    'guitar',
    'keys',
    'a bridge',
    'lyrics',
  ];

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
              'What does this song need?',
              style: TextStyle(
                color: AppColors.text,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 14),
            if (!openAskStanding)
              FilledButton(
                onPressed: () => Navigator.pop(context, ''),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.green,
                  foregroundColor: AppColors.ink,
                  minimumSize: const Size.fromHeight(52),
                  textStyle: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                child: const Text("I don't know — what do you hear?"),
              )
            else
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.raised,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  "You've already asked the room what this needs.",
                  style: TextStyle(color: AppColors.muted, fontSize: 12.5),
                ),
              ),
            const SizedBox(height: 18),
            const Text(
              'OR ASK FOR SOMETHING IN PARTICULAR',
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final part in _parts)
                  if (!alreadyAsked.contains(part.toLowerCase()))
                    OutlinedButton(
                      onPressed: () => Navigator.pop(context, part),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.gold,
                        side: BorderSide(
                          color: AppColors.gold.withValues(alpha: 0.35),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        textStyle: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      child: Text(part),
                    ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
