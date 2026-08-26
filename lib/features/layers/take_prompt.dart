import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../services/take_naming.dart';
/// Asks what the take was, in the second after recording stops.
 
///
/// Dismissable. Somebody who does not care gets a generic name and can rename
/// it later — a sheet that cannot be escaped mid-session is worse than an
/// unnamed part.
Future<({TakePart part, String? performer})?> askWhatThatWas(
  BuildContext context, {
  String? performer,
}) {
  var name = performer ?? '';
  return showModalBottomSheet<({TakePart part, String? performer})>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: AppColors.deepNavy,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.fromLTRB(
          18, 0, 18, MediaQuery.of(sheetContext).viewInsets.bottom + 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'What was that?',
            style: TextStyle(
              color: AppColors.text,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'So the band can tell the takes apart.',
            style: TextStyle(color: AppColors.muted, fontSize: 12.5),
          ),
          const SizedBox(height: 14),
          TextFormField(
            initialValue: name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Who played it',
              hintText: 'Dylan',
            ),
            onChanged: (value) => name = value,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final part in TakePart.values)
                ActionChip(
                  label: Text(part.label),
                  backgroundColor: AppColors.raised,
                  labelStyle:
                      const TextStyle(color: AppColors.text, fontSize: 13),
                  side: BorderSide(color: AppColors.cyan.withValues(alpha: 0.25)),
                  onPressed: () => Navigator.pop(
                    sheetContext,
                    (
                      part: part,
                      performer: name.trim().isEmpty ? null : name.trim(),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => Navigator.pop(sheetContext),
            child: const Text('Skip'),
          ),
        ],
      ),
    ),
  );
}
