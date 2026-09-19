import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import 'practice_rules.dart';

/// What a long press on a chord offers: that one change, on repeat, slowed.
///
/// Every Musician, Same Song, 17 September 2026. A beginner does not stall on
/// a chorus, they stall on one change — the bar where the hand has to get
/// somewhere it cannot get in time. The bars have been loopable since #362
/// and the speeds since then too; this is the gesture that asks for the two
/// bars either side of the chord you are looking at without counting them
/// first.
///
/// A sheet with one thing on it, like the bar-1 offer the chart already has
/// (see chord_chart_view.dart), and for the same reasons: a long press that
/// silently changed what the song is doing would be a gesture nobody could
/// check, and one that says what it will do teaches itself the first time
/// somebody's thumb rests on a chord.
Future<void> showLoopThisChange(
  BuildContext context, {
  required PracticeLoop loop,
  required String detail,
  required VoidCallback onLoop,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.deepNavy,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ListTile(
            key: const Key('loop_this_change'),
            leading: const Icon(Icons.repeat_rounded,
                size: 20, color: AppColors.text),
            title: const Text(
              'Loop this change',
              style: TextStyle(color: AppColors.text, fontSize: 14),
            ),
            subtitle: Text(
              detail,
              style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
            ),
            onTap: () {
              Navigator.of(sheetContext).pop();
              onLoop();
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// "Bars 3–4 at 60%": what the offer will put on repeat, and how slowly.
///
/// The speed is said in the same mixed labels the practice row uses, so one
/// speed is one word everywhere (see [rateLabel]).
String loopThisChangeDetail(PracticeLoop loop) =>
    '${loop.label} at ${rateLabel(changeLoopRate)}';
