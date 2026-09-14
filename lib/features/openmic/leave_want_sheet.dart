import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';

/// What somebody chose to leave behind when the room could not help: a note
/// that they would like to meet a [label], with a line if they had one.
class LeaveWantChoice {
  const LeaveWantChoice(this.note);

  final String note;
}

/// Asks whether to leave the note, and returns what was chosen -- or null
/// when the sheet was dismissed.
///
/// The shallowest ask there is, and it has to stay that shallow: one tap
/// leaves it, the box is there for whoever has a sentence, and the sheet
/// says out loud how long it lasts, because a note nobody remembers leaving
/// is how a room fills with ghosts.
Future<LeaveWantChoice?> showLeaveWantSheet(
  BuildContext context, {
  required String label,
}) {
  return showModalBottomSheet<LeaveWantChoice>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.deepNavy,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: LeaveWantSheet(label: label),
    ),
  );
}

class LeaveWantSheet extends StatefulWidget {
  const LeaveWantSheet({required this.label, super.key});

  /// What they were looking for, in a person's words: "a singer".
  final String label;

  @override
  State<LeaveWantSheet> createState() => _LeaveWantSheetState();
}

class _LeaveWantSheetState extends State<LeaveWantSheet> {
  final TextEditingController _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
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
            Text(
              'Leave a note: you would like to meet ${widget.label}',
              style: const TextStyle(
                color: AppColors.text,
                fontSize: 17,
                fontWeight: FontWeight.w800,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'When somebody who plays that turns up on the Open Mic, you '
              'hear about it. The note lasts a month, then it is gone.',
              style: TextStyle(color: AppColors.muted, fontSize: 12.5, height: 1.4),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const Key('leave_want_note'),
              controller: _note,
              maxLength: 140,
              minLines: 1,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(color: AppColors.text, fontSize: 14.5),
              decoration: const InputDecoration(
                hintText: 'A line for yourself, if you like',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton(
              key: const Key('leave_want_send'),
              onPressed: () =>
                  Navigator.pop(context, LeaveWantChoice(_note.text.trim())),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
                backgroundColor: AppColors.cyan,
                foregroundColor: AppColors.ink,
              ),
              child: const Text('Leave the note'),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => Navigator.pop(context),
              style: TextButton.styleFrom(
                minimumSize: const Size.fromHeight(40),
                foregroundColor: AppColors.muted,
              ),
              child: const Text('Never mind'),
            ),
          ],
        ),
      ),
    );
  }
}
