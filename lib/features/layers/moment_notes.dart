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
  const NoteTarget({required this.id, required this.label});

  final String? id;
  final String label;
}

/// What somebody typed, and which recording they typed it about.
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
Future<MomentNoteDraft?> showMomentNoteSheet(
  BuildContext context, {
  required int atMs,
  required List<NoteTarget> on,
  String? initialLayerId,
}) {
  if (on.isEmpty) return Future<MomentNoteDraft?>.value();
  var chosen = on.any((target) => target.id == initialLayerId)
      ? initialLayerId
      : on.first.id;
  final typed = TextEditingController();
  return showModalBottomSheet<MomentNoteDraft>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: AppColors.deepNavy,
    builder: (sheetContext) => StatefulBuilder(
      builder: (builderContext, setSheetState) {
        void pin() {
          final body = typed.text.trim();
          if (body.isEmpty) return;
          Navigator.pop(
            sheetContext,
            MomentNoteDraft(layerId: chosen, body: body),
          );
        }

        return Padding(
          padding: EdgeInsets.fromLTRB(
              18, 0, 18, MediaQuery.of(builderContext).viewInsets.bottom + 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Note at ${MomentNote.clockOf(atMs)}',
                style: const TextStyle(
                  color: AppColors.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Only the person who played it is told.',
                style: TextStyle(color: AppColors.muted, fontSize: 12.5),
              ),
              if (on.length > 1) ...<Widget>[
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final target in on)
                      ChoiceChip(
                        label: Text(target.label),
                        selected: target.id == chosen,
                        backgroundColor: AppColors.raised,
                        selectedColor: AppColors.cyan.withValues(alpha: 0.22),
                        labelStyle: const TextStyle(
                            color: AppColors.text, fontSize: 13),
                        side:
                            BorderSide(color: AppColors.cyan.withValues(alpha: 0.25)),
                        onSelected: (_) =>
                            setSheetState(() => chosen = target.id),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 14),
              SendOnEnter(
                onSend: pin,
                child: TextField(
                  key: const Key('moment_note_body'),
                  controller: typed,
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
              Row(
                children: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.pop(sheetContext),
                    child: const Text('Not now'),
                  ),
                  const Spacer(),
                  FilledButton(
                    key: const Key('moment_note_pin'),
                    onPressed: pin,
                    child: const Text('Pin it'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    ),
  );
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
    super.key,
  });

  final List<MomentNote> notes;

  /// Plays from three seconds before, looping the moment.
  final ValueChanged<MomentNote> onOpen;

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
            onOpen: () => onOpen(note),
            onDelete: onDelete == null ? null : () => onDelete!(note),
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
    this.on,
    this.onDelete,
  });

  final MomentNote note;
  final String? on;
  final bool focused;
  final bool mine;
  final VoidCallback onOpen;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final author = (note.authorName ?? '').trim();
    final said = <String>[
      if (!mine && author.isNotEmpty) author,
      if (on != null) on!,
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
