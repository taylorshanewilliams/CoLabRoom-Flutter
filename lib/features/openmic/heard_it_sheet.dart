import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';

/// What somebody chose to say when they said they heard a song. An empty
/// [note] is the nod on its own, which is most of them.
class HeardItChoice {
  const HeardItChoice(this.note);

  final String note;
}

/// Asks whether to add one line to the nod, and returns what was chosen --
/// or null when the sheet was dismissed, which is "never mind" rather than
/// a nod.
///
/// Two buttons and a box that can stay empty. The cheap answer has to stay
/// cheap: "Just heard it" is one tap, and the box is there for the person
/// who has a sentence and nowhere to put it, not as a form to fill in.
Future<HeardItChoice?> showHeardItSheet(
  BuildContext context, {
  required String ownerName,
}) {
  return showModalBottomSheet<HeardItChoice>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.deepNavy,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: HeardItSheet(ownerName: ownerName),
    ),
  );
}

class HeardItSheet extends StatefulWidget {
  const HeardItSheet({required this.ownerName, super.key});

  final String ownerName;

  @override
  State<HeardItSheet> createState() => _HeardItSheetState();
}

class _HeardItSheetState extends State<HeardItSheet> {
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
              'Tell ${widget.ownerName} you heard it',
              style: const TextStyle(
                color: AppColors.text,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'They see your name. Add a line if something stayed with you.',
              style: TextStyle(color: AppColors.muted, fontSize: 12.5, height: 1.4),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const Key('heard_it_note'),
              controller: _note,
              maxLength: 140,
              minLines: 1,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(color: AppColors.text, fontSize: 14.5),
              decoration: const InputDecoration(
                hintText: 'One line, if you like',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                TextButton(
                  key: const Key('heard_it_plain'),
                  onPressed: () =>
                      Navigator.pop(context, const HeardItChoice('')),
                  style: TextButton.styleFrom(foregroundColor: AppColors.muted),
                  child: const Text('Just heard it'),
                ),
                const Spacer(),
                FilledButton(
                  key: const Key('heard_it_send'),
                  onPressed: () =>
                      Navigator.pop(context, HeardItChoice(_note.text.trim())),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.cyan,
                    foregroundColor: AppColors.ink,
                  ),
                  child: const Text('Send'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
