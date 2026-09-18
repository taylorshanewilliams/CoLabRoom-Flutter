import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/moment_note.dart';
import '../../widgets/send_on_enter.dart';

/// Pinning words to a moment of a recording, and reading the ones already
/// there.
///
/// Every Musician, Same Song, 17 September 2026. The note is the point, so
/// this is deliberately plain: a moment, what was said, and who said it. No
/// count of how many notes a take has, no dates, and nothing about how long
/// anybody spent.

/// One recording a note can be pinned to.
///
/// A null [id] is the song's own recording, which is not a take.
@immutable
class NoteTarget {
  const NoteTarget({
    required this.id,
    required this.label,
    this.yoursAlone = false,
  });

  final String? id;
  final String label;

  /// A take of your own that nobody has been shared with.
  ///
  /// Words pinned on one are read by you and by nobody else — now, and after
  /// you share the take, because 0141 freezes a note's audience when it is
  /// written. The sheet says so rather than leaving somebody to find out.
  final bool yoursAlone;
}

/// What somebody typed, and which recording they typed it about.
///
/// For a note that was said rather than typed, [body] is empty: the
/// recording is already in the screen's hands and the sheet only decides
/// which take it is about and whether to keep it.
@immutable
class MomentNoteDraft {
  const MomentNoteDraft({required this.layerId, required this.body});

  final String? layerId;
  final String body;
}

/// Asks for the words, at a moment already decided.
///
/// The moment is in the title rather than in a field: the playhead said when,
/// which is the whole difference between this and a comment. Choosing the
/// recording is only offered when there is more than one to choose from.
///
/// With [spoken], the words have already been said (0152): the sheet asks
/// which recording they were about and whether to keep them, and nothing
/// else. Asked after the hold rather than before it, because the moment to
/// throw away a fluffed sentence is right after saying it, and there is no
/// proofreading a recording.
Future<MomentNoteDraft?> showMomentNoteSheet(
  BuildContext context, {
  required int atMs,
  required List<NoteTarget> on,
  String? initialLayerId,
  bool spoken = false,
}) {
  if (on.isEmpty) return Future<MomentNoteDraft?>.value();
  return showModalBottomSheet<MomentNoteDraft>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: AppColors.deepNavy,
    builder: (sheetContext) => _MomentNoteSheet(
      atMs: atMs,
      on: on,
      initialLayerId: initialLayerId,
      spoken: spoken,
    ),
  );
}

/// The sheet itself, which owns its controller.
///
/// A widget rather than a [StatefulBuilder] for the same reason every other
/// sheet in this app is one (ask_musician_sheet, heard_it_sheet): a
/// controller made in a function has no dispose to be hung on, and a teacher
/// going through fifteen takes opens this fifteen times.
class _MomentNoteSheet extends StatefulWidget {
  const _MomentNoteSheet({
    required this.atMs,
    required this.on,
    this.initialLayerId,
    this.spoken = false,
  });

  final int atMs;
  final List<NoteTarget> on;
  final String? initialLayerId;
  final bool spoken;

  @override
  State<_MomentNoteSheet> createState() => _MomentNoteSheetState();
}

class _MomentNoteSheetState extends State<_MomentNoteSheet> {
  final TextEditingController _typed = TextEditingController();
  String? _chosen;

  @override
  void initState() {
    super.initState();
    _chosen = widget.on.any((target) => target.id == widget.initialLayerId)
        ? widget.initialLayerId
        : widget.on.first.id;
  }

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  NoteTarget get _target => widget.on.firstWhere(
        (target) => target.id == _chosen,
        orElse: () => widget.on.first,
      );

  void _pin() {
    if (widget.spoken) {
      Navigator.pop(context, MomentNoteDraft(layerId: _chosen, body: ''));
      return;
    }
    final body = _typed.text.trim();
    if (body.isEmpty) return;
    Navigator.pop(context, MomentNoteDraft(layerId: _chosen, body: body));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          18, 0, 18, MediaQuery.of(context).viewInsets.bottom + 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '${widget.spoken ? 'Said' : 'Note'} at ${MomentNote.clockOf(widget.atMs)}',
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          // Said before the words are typed, because it cannot be taken back
          // afterwards: a note on a take nobody has heard stays yours even
          // once you send the take (0141).
          Text(
            _target.yoursAlone
                ? 'Only you can read this one, even after you share the take.'
                : 'Only the person who played it is told.',
            key: const Key('moment_note_who'),
            style: const TextStyle(color: AppColors.muted, fontSize: 12.5),
          ),
          if (widget.on.length > 1) ...<Widget>[
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final target in widget.on)
                  ChoiceChip(
                    label: Text(target.label),
                    selected: target.id == _chosen,
                    backgroundColor: AppColors.raised,
                    selectedColor: AppColors.cyan.withValues(alpha: 0.22),
                    labelStyle:
                        const TextStyle(color: AppColors.text, fontSize: 13),
                    side: BorderSide(
                        color: AppColors.cyan.withValues(alpha: 0.25)),
                    onSelected: (_) => setState(() => _chosen = target.id),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          // Nothing to type for a spoken note: what was said is already in
          // hand, and a box here would be a box for a second note.
          if (!widget.spoken) ...<Widget>[
            SendOnEnter(
              onSend: _pin,
              child: TextField(
                key: const Key('moment_note_body'),
                controller: _typed,
                autofocus: true,
                minLines: 2,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                inputFormatters: <TextInputFormatter>[
                  LengthLimitingTextInputFormatter(MomentNote.bodyLimit),
                ],
                decoration: const InputDecoration(
                  hintText: 'What happens here',
                ),
              ),
            ),
            const SizedBox(height: 14),
          ],
          Row(
            children: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context),
                // Said plainly for a recording, because there is no draft
                // to come back to: leaving the sheet is losing it.
                child: Text(widget.spoken ? 'Throw it away' : 'Not now'),
              ),
              const Spacer(),
              FilledButton(
                key: const Key('moment_note_pin'),
                onPressed: _pin,
                child: const Text('Pin it'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The notes on one song, in the order they happen.
///
/// Under the timeline rather than under each lane: the lanes sit inside one
/// drag target, and a tappable row inside a scrubbing gesture is a row that
/// sometimes scrubs instead. Which recording a note is on is said on the row
/// when there is more than one.
class MomentNoteList extends StatelessWidget {
  const MomentNoteList({
    required this.notes,
    required this.onOpen,
    required this.currentUserId,
    this.labelFor,
    this.focusedId,
    this.onDelete,
    this.onListen,
    this.listeningTo,
    super.key,
  });

  final List<MomentNote> notes;

  /// Plays from three seconds before, looping the moment.
  final ValueChanged<MomentNote> onOpen;

  /// Plays what was said, for a spoken note (0152). Pressed again on the
  /// note that is playing, it stops.
  final ValueChanged<MomentNote>? onListen;

  /// The spoken note playing now, so its row offers Stop rather than Listen.
  final String? listeningTo;

  /// Which recording the note is on, or null to leave it unsaid — which is
  /// right when the song has only one.
  final String Function(MomentNote note)? labelFor;

  final String? focusedId;
  final String currentUserId;

  /// Only ever offered on your own words.
  final ValueChanged<MomentNote>? onDelete;

  @override
  Widget build(BuildContext context) {
    if (notes.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Text(
          'Notes',
          style: TextStyle(
            color: AppColors.text,
            fontSize: 15,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 8),
        for (final note in notes) ...<Widget>[
          _NoteRow(
            note: note,
            on: labelFor?.call(note),
            focused: note.id == focusedId,
            mine: note.authorId == currentUserId,
            listening: note.id == listeningTo,
            onOpen: () => onOpen(note),
            onDelete: onDelete == null ? null : () => onDelete!(note),
            onListen: onListen == null ? null : () => onListen!(note),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _NoteRow extends StatelessWidget {
  const _NoteRow({
    required this.note,
    required this.focused,
    required this.mine,
    required this.onOpen,
    this.listening = false,
    this.on,
    this.onDelete,
    this.onListen,
  });

  final MomentNote note;
  final String? on;
  final bool focused;
  final bool mine;
  final bool listening;
  final VoidCallback onOpen;
  final VoidCallback? onDelete;
  final VoidCallback? onListen;

  @override
  Widget build(BuildContext context) {
    final author = (note.authorName ?? '').trim();
    final said = <String>[
      if (!mine && author.isNotEmpty) author,
      if (on != null) on!,
      // The same two words the lane uses for a take nobody has been sent.
      // Without it a note you wrote to yourself on a draft sits in the list
      // looking exactly like one the band can read.
      if (!note.onSharedTake) 'only you',
    ].join(' · ');

    return InkWell(
      key: Key('moment_note_${note.id}'),
      onTap: onOpen,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 9, 6, 9),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: focused
                ? AppColors.gold.withValues(alpha: 0.55)
                : AppColors.line,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // The moment, first and in the font a transport uses, because it
            // is what the note is for.
            SizedBox(
              width: 52,
              child: Text(
                note.isRange
                    ? '${note.clock}–${MomentNote.clockOf(note.loopEndMs)}'
                    : note.clock,
                style: const TextStyle(
                  color: AppColors.gold,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // A spoken note has nothing to read, so the row is the
                  // one button that plays it. Plain on purpose: no length,
                  // no waveform, just the way to hear it (0152).
                  if (note.isSpoken)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: Key('listen_moment_note_${note.id}'),
                        onPressed: onListen,
                        icon: Icon(
                          listening
                              ? Icons.stop_rounded
                              : Icons.play_arrow_rounded,
                          size: 16,
                        ),
                        label: Text(
                          listening ? 'Stop' : 'Listen',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.cyan,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(0, 30),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    )
                  else
                    Text(
                      note.body,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                  if (said.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 3),
                    Text(
                      said,
                      style: const TextStyle(
                          color: AppColors.muted, fontSize: 10.5),
                    ),
                  ],
                ],
              ),
            ),
            if (mine && onDelete != null)
              IconButton(
                onPressed: onDelete,
                tooltip: 'Take this note back',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close_rounded,
                    size: 15, color: AppColors.muted),
              ),
          ],
        ),
      ),
    );
  }
}

/// Hold to say a note at the playhead; let go to stop (0152).
///
/// A [Listener] rather than a long press. A long press waits half a second
/// before it fires, and the first word is said in that half second: the
/// finger going down has to be the start and the finger coming up the end,
/// which is what "hold" means to the person holding it. The label says so,
/// because a gesture nobody is told about is a feature nobody has.
///
/// The elapsed clock is shown while holding, the way the record button
/// shows it for a take, so nobody is surprised by the one-minute cap. It
/// is never shown afterwards.
class SayItButton extends StatelessWidget {
  const SayItButton({
    required this.saying,
    required this.elapsed,
    required this.onDown,
    required this.onUp,
    this.enabled = true,
    super.key,
  });

  final bool saying;
  final Duration elapsed;

  /// The finger went down. The screen decides whether that opens the
  /// microphone; it may be busy, or still asking for permission.
  final VoidCallback onDown;

  /// The finger came up, or the touch was taken away. Always delivered,
  /// even when the button is disabled, so a hold that outlives its button
  /// still ends.
  final VoidCallback onUp;

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFFF718B);
    final ink = saying
        ? red
        : enabled
            ? AppColors.gold
            : AppColors.line;
    return Semantics(
      button: true,
      label: 'Hold to say a note at this moment',
      child: Listener(
        onPointerDown: enabled ? (_) => onDown() : null,
        onPointerUp: (_) => onUp(),
        onPointerCancel: (_) => onUp(),
        child: Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: saying ? red.withValues(alpha: 0.16) : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: saying ? red : ink.withValues(alpha: 0.5),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.mic_rounded, size: 17, color: ink),
              const SizedBox(width: 6),
              Text(
                saying
                    ? 'Saying it  ${MomentNote.clockOf(elapsed.inMilliseconds)}'
                    : 'Hold to say it',
                style: TextStyle(
                  color: ink,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// N pins a note at the playhead, where there is a keyboard.
///
/// The same rule as [SendOnEnter]: a phone's keyboard is left alone, and a
/// desk gets the key somebody listening through fifteen takes would want.
/// Every Musician, Same Song, 17 September 2026 -- the teacher's pass is
/// Space, J, K, N.
class PinAtPlayheadKey extends StatelessWidget {
  const PinAtPlayheadKey({
    required this.onPin,
    required this.child,
    this.onKeyboard,
    super.key,
  });

  final VoidCallback onPin;
  final Widget child;

  /// Whether this device types on a keyboard. A test passes it.
  final bool? onKeyboard;

  @override
  Widget build(BuildContext context) {
    if (!(onKeyboard ?? typesOnAKeyboard)) return child;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyN): onPin,
      },
      // Shortcuts only fire inside the focused subtree, and this screen has
      // nothing else that wants the keyboard.
      child: Focus(autofocus: true, child: child),
    );
  }
}
