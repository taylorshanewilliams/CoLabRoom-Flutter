import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/sealed_take.dart';

/// Putting a take away until a day of your choosing.
///
/// Every Musician, Same Song, 17 September 2026, from the big swings worth
/// keeping: somebody records an idea and seals it, and the app offers it
/// back a year on -- "A year ago tonight you sealed this. Play it now?"
/// Sealing is one action on a take. It is asked about first because it is
/// the one thing on the takes screen that makes a take disappear without
/// deleting it, and somebody who mis-tapped should not spend a year
/// wondering where their chorus went.
///
/// Kept out of the screen so the words can be read in a test, the way
/// sending_a_take.dart keeps its own.

/// What the action is called, on the take's own sheet.
const String sealItLabel = 'Seal it for later';

/// What the takes screen says once it is done.
String sealedUntilWords(DateTime opens) =>
    'Sealed until ${dayInWords(opens)}.';

/// Asks when the take should come back, and answers with that moment, or
/// null if they thought better of it.
///
/// A year unless they say otherwise, at the same time of day as now: a take
/// sealed late one evening comes back late one evening. The day can be any
/// from tomorrow to just short of ten years, which is as far as the table
/// lets a seal go (0158).
Future<DateTime?> askWhenToOpen(BuildContext context, {DateTime? now}) {
  final asked = now ?? DateTime.now();
  var opens = aYearOn(asked);
  return showDialog<DateTime>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        backgroundColor: AppColors.raised,
        // Scrolls rather than overflowing at the largest text sizes: there
        // are three sentences and a date in here, not one line.
        scrollable: true,
        title: const Text('Seal this take?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'It is put away until the day you choose. Nobody else can see '
              'it, and it is not deleted. On that day you are offered it '
              'back, once.',
            ),
            const SizedBox(height: 14),
            Text(
              'Opens ${dayInWords(opens)}',
              key: const Key('seal_opens_on'),
              style: const TextStyle(
                color: AppColors.text,
                fontWeight: FontWeight.w800,
              ),
            ),
            TextButton(
              key: const Key('seal_another_day'),
              onPressed: () async {
                final picked = await showDatePicker(
                  context: dialogContext,
                  initialDate: opens,
                  firstDate: earliestSealDay(asked),
                  lastDate: latestSealDay(asked),
                  helpText: 'Open it on',
                );
                if (picked == null) return;
                setDialogState(() => opens = onTheDay(picked, asked));
              },
              style: TextButton.styleFrom(
                foregroundColor: AppColors.cyan,
                padding: EdgeInsets.zero,
                alignment: Alignment.centerLeft,
              ),
              child: const Text('Another day'),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Not yet'),
          ),
          FilledButton(
            key: const Key('seal_it'),
            onPressed: () => Navigator.pop(dialogContext, opens),
            child: const Text('Seal it'),
          ),
        ],
      ),
    ),
  );
}
