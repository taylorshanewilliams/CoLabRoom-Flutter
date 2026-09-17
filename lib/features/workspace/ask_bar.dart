import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/musical_roles.dart';
import '../../data/music_repository.dart';
import '../../domain/music_models.dart';
import '../../services/push_registration.dart';
import '../../services/user_facing_error.dart';
import '../../widgets/ask_terms_picker.dart';
import 'ask_thread_sheet.dart';

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
    final choice = await showModalBottomSheet<_AskChoice?>(
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
        part: choice.part.isEmpty ? null : choice.part,
        terms: choice.terms,
      );
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(choice.part.isEmpty
            ? 'Asked the room what it needs.'
            : 'Asked the room for ${choice.part}.'),
      ));
      await _offerNotifications();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(reportAndDescribe(error, service: 'app', stage: 'ask')),
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The moment notifications have earned the right to ask.
  ///
  /// Somebody who has just asked their room for a bridge has an obvious
  /// reason to want to know when one arrives. That is a completely different
  /// question from the same dialog on a launch screen, before they know what
  /// the app is or why it would interrupt them.
  ///
  /// Our own dialog comes first, and the system one is only reached through a
  /// yes. On iOS the permission prompt can be shown exactly once for the life
  /// of an install — a "no" there is permanent and can only be undone in
  /// Settings, which nobody does. So the cheap, reversible question gets asked
  /// first, and the expensive irreversible one is spent only on people who
  /// have already said they want it.
  Future<void> _offerNotifications() async {
    if (!PushRegistration.isAvailable) return;
    if (await PushRegistration.isAllowed()) return;
    if (!mounted) return;

    final wants = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.raised,
        title: const Text('Tell you when somebody answers?'),
        content: const Text(
          "Your room has been asked. We can let you know on your phone when "
          "a take lands, instead of you having to come back and check.",
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Yes, tell me'),
          ),
        ],
      ),
    );
    if (wants != true) return;
    await PushRegistration.enable();
  }

  /// The thread on an ask, then the bar again with its counts current.
  Future<void> _openThread(SongAsk ask) async {
    await showAskThread(
      context,
      repository: widget.repository,
      askId: ask.id,
      headline: ask.headline,
      note: ask.note,
    );
    if (mounted) await _load();
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
    // The sentence is about the terms rather than about a part, so it is said
    // once under the row rather than copied under every chip. What it must
    // never do is point at the wrong ask: a song can hold an open ask for
    // bass and another for a topline at the same time (0049 forbids only two
    // open asks for the same part), and one line under both would tell the
    // bass player they are a writer. So the writing chips name themselves,
    // and the line underneath says what that word costs.
    final writing = asks.any((ask) => ask.terms == AskTerms.write);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              for (final ask in asks)
                _AskChip(
                  key: Key('ask_chip_${ask.id}'),
                  label: ask.replyCount > 0
                      ? '${ask.label} · ${ask.replyCount}'
                      : ask.label,
                  specific: ask.isSpecific,
                  writing: ask.terms == AskTerms.write,
                  writingKey: Key('ask_chip_writing_${ask.id}'),
                  onOpen: () => unawaited(_openThread(ask)),
                  onClose: _busy ? null : () => unawaited(_close(ask)),
                ),
              // Labelled, always. The failure this app keeps repeating is a
              // good feature behind a glyph nobody recognises.
              TextButton.icon(
                onPressed: _busy ? null : () => unawaited(_ask()),
                icon: const Icon(Icons.campaign_outlined, size: 17),
                label: Text(
                  asks.isEmpty ? 'Ask the room' : 'Ask for something else',
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w700),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.gold,
                  disabledForegroundColor: AppColors.line,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
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
                // A count, not a score: it says somebody listened, and it
                // stops being interesting long before it becomes a number to
                // chase.
                label: Text(
                  _iHaveNodded
                      ? (heard > 1 ? 'Heard it · $heard' : 'Heard it')
                      : (heard > 0 ? '$heard heard it' : 'Heard it'),
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w700),
                ),
                style: TextButton.styleFrom(
                  foregroundColor:
                      _iHaveNodded ? AppColors.cyan : AppColors.muted,
                  disabledForegroundColor: AppColors.line,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
              ),
            ],
          ),
          if (writing) ...<Widget>[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                AskTerms.write.notice!,
                key: const Key('ask_bar_writing_terms'),
                style: const TextStyle(
                    color: AppColors.muted, fontSize: 11.5, height: 1.35),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AskChip extends StatelessWidget {
  const _AskChip({
    required this.label,
    required this.specific,
    required this.writing,
    required this.writingKey,
    required this.onOpen,
    required this.onClose,
    super.key,
  });

  final String label;
  final bool specific;

  /// Whether answering this one means writing on the song.
  ///
  /// The chip says so itself rather than leaving it to the line under the
  /// row. A song can be asking for bass to play and a topline to write on at
  /// the same time, and a single sentence under both chips would be read as
  /// covering both — which is the two-honest-memories argument this slice
  /// exists to prevent, made by the surface that reports it.
  final bool writing;
  final Key writingKey;

  /// The thread. The chip used to be a label with an X on it; now the label
  /// is the way in to what people have said about the ask.
  final VoidCallback onOpen;
  final VoidCallback? onClose;

  /// How far in from the chip's right edge the close button reaches: the 40
  /// pixels the button lays out as, the chip's 4 of padding beside it, and the
  /// 1 of border outside that.
  static const double _closeWidth = 45;

  @override
  Widget build(BuildContext context) {
    // The two shapes are told apart by colour as well as words, because at a
    // glance down a list of songs "open to ideas" and "needs drums" are
    // different invitations.
    final tint = specific ? AppColors.gold : AppColors.green;
    final chip = Container(
      padding: const EdgeInsets.fromLTRB(0, 0, 4, 0),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: tint.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // Flexible, so a chip too wide for a narrow phone gives way instead
          // of overflowing: "needs a topline · writing" is already 0.25px too
          // wide for a 390pt screen.
          Flexible(
            child: InkWell(
              onTap: onOpen,
              borderRadius: BorderRadius.circular(20),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 5, 4, 5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    // The part gives way and the terms never do. If something
                    // has to be cut it is the name of the instrument, which
                    // the thread behind the chip repeats; cutting "writing"
                    // would hide the one word that changes what answering
                    // this ask is worth.
                    Flexible(
                      child: Text(
                        label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: tint,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    // A plain word in the same phrase, not a badge on top of
                    // one: it names the terms this ask was sent under, so the
                    // sentence under the row can only be read as belonging to
                    // the chips that say the word.
                    if (writing)
                      Text(
                        ' · writing',
                        key: writingKey,
                        style: TextStyle(
                          color: tint,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
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

    // The chip stays the height it is — 40 pixels, set by its close button's
    // compact density, and a chip the size of a button would read as one —
    // but 40 is eight short of what a touch wants (audit, 17 September 2026).
    // So the chip sits in a box 48 tall and the close button's share of that
    // box runs from the top of it to the bottom, four pixels above the chip
    // and four below. The row costs nothing: the two buttons beside these
    // chips are ordinary Material ones, already padded to 48 on a phone, so
    // the line was 48 tall with the chips centred in it either way.
    return SizedBox(
      height: 48,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          // Behind the chip, so a tap on the button itself still reaches the
          // button, with its ripple and its "Stop asking". This catches only
          // what lands above or below.
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            width: _closeWidth,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onClose,
              excludeFromSemantics: true,
            ),
          ),
          chip,
        ],
      ),
    );
  }
}

/// What the sheet hands back: what the song is asking for, and what
/// answering it means.
class _AskChoice {
  const _AskChoice(this.part, this.terms);

  /// Empty for "I don't know what this needs", which is the open ask.
  final String part;
  final AskTerms terms;
}

/// The sheet that asks what you're asking for.
///
/// The open ask is first, biggest, and needs no decision — because "I don't
/// know what this needs" is the honest state of most unfinished songs, and a
/// control that made you name a part before you could ask would turn the
/// commonest case into homework. The named parts underneath are one tap each
/// and no typing, for when you do know.
///
/// The terms sit above both, because tapping a part sends the ask: a control
/// underneath would be one somebody read after the sheet had already closed.
class _AskSheet extends StatefulWidget {
  const _AskSheet({
    required this.alreadyAsked,
    required this.openAskStanding,
  });

  final Set<String> alreadyAsked;
  final bool openAskStanding;

  @override
  State<_AskSheet> createState() => _AskSheetState();
}

class _AskSheetState extends State<_AskSheet> {
  /// Playing, until somebody says otherwise. Every ask this app has ever made
  /// is one of these (Every Musician, Same Song, 17 September 2026).
  AskTerms _terms = AskTerms.play;

  /// The one list, and a bug fixed by using it.
  ///
  /// This was its own vocabulary — 'vocals', 'guitar', 'a bridge' — and none
  /// of those are the words the rest of the app stores. An ask made from this
  /// bar could never be matched by the Open Mic's filter, because the filter
  /// looks for 'vocal' and this wrote 'vocals'. Nobody would have seen that
  /// happen; the ask simply never reached anybody.
  static List<MusicalRole> get _parts => MusicalRole.offered;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
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
            const SizedBox(height: 12),
            AskTermsPicker(
              terms: _terms,
              onChanged: (chosen) => setState(() => _terms = chosen),
            ),
            const SizedBox(height: 14),
            if (!widget.openAskStanding)
              FilledButton(
                onPressed: () =>
                    Navigator.pop(context, _AskChoice('', _terms)),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.green,
                  foregroundColor: AppColors.ink,
                  minimumSize: const Size.fromHeight(52),
                ),
                child: const Text(
                  "I don't know — what do you hear?",
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
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
                  if (!widget.alreadyAsked.contains(part.value))
                    OutlinedButton(
                      onPressed: () =>
                          Navigator.pop(context, _AskChoice(part.value, _terms)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.gold,
                        side: BorderSide(
                          color: AppColors.gold.withValues(alpha: 0.35),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                      ),
                      child: Text(
                        part.label,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
