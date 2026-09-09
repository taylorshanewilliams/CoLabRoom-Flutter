import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';

/// What the app worked out, offered rather than asked.
///
/// The profile sheet is a form — tick your instruments, tick your genres,
/// type your city — and a form is the least interesting thing an app can hand
/// somebody who has just made music. It also asks at the worst possible
/// moment: before there is anything to say.
///
/// By the time anybody has recorded a few takes the app already knows what
/// they play, because every take carries a part. So it says so. "You have
/// recorded bass on four songs — add it?" is the app having paid attention,
/// and one tap instead of a sheet.
///
/// **Nothing here is a guess.** Every line is countable: shared takes with a
/// part on them, songs on the Open Mic, a field left empty. The app does not
/// infer anybody's taste or ability, because nothing in it supports inferring
/// either and a wrong guess about who somebody is as a musician is far worse
/// than no guess at all.
class TheAppNoticed extends StatelessWidget {
  const TheAppNoticed({
    required this.noticed,
    required this.onClaim,
    required this.onOpenSettings,
    this.busy,
    super.key,
  });

  final List<Noticed> noticed;

  /// Adds one part to what they play.
  final ValueChanged<String> onClaim;

  /// For the two that are not one-tap: being findable, and saying what you
  /// sound like. Both are decisions rather than facts, so both open the sheet
  /// rather than happening to somebody.
  final VoidCallback onOpenSettings;

  /// The part currently being added, so its button can say so.
  final String? busy;

  @override
  Widget build(BuildContext context) {
    if (noticed.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 22),
      padding: const EdgeInsets.fromLTRB(15, 14, 15, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: AppColors.gold.withValues(alpha: 0.32)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            AppColors.gold.withValues(alpha: 0.08),
            AppColors.raised,
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(
                Icons.auto_awesome_rounded,
                size: 15,
                color: AppColors.gold,
              ),
              const SizedBox(width: 7),
              // Expanded, because a heading beside an icon is a fixed row and
              // this app clamps text at 1.3x — where "A few things we
              // noticed" is 34 pixels wider than the space it was given.
              Expanded(
                child: Text(
                  noticed.length == 1
                      ? 'One thing we noticed'
                      : 'A few things we noticed',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.gold,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.9,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final item in noticed)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _One(
                item: item,
                busy: busy == item.subject,
                onClaim: onClaim,
                onOpenSettings: onOpenSettings,
              ),
            ),
        ],
      ),
    );
  }
}

class _One extends StatelessWidget {
  const _One({
    required this.item,
    required this.busy,
    required this.onClaim,
    required this.onOpenSettings,
  });

  final Noticed item;
  final bool busy;
  final ValueChanged<String> onClaim;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          item.detail,
          style: const TextStyle(
            color: AppColors.text,
            fontSize: 13.5,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            if (item.kind == NoticedKind.plays)
              Flexible(
                child: FilledButton(
                  key: Key('claim_${item.subject}'),
                  onPressed: busy ? null : () => onClaim(item.subject),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.gold,
                    foregroundColor: AppColors.ink,
                    visualDensity: VisualDensity.compact,
                  ),
                  // Named, because "Add" beside a sentence about bass is a
                  // button that could be doing anything.
                  child: Text(
                    busy ? 'Adding…' : 'Add ${item.subject}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              )
            else
              Flexible(
                child: FilledButton(
                  onPressed: onOpenSettings,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.gold,
                    foregroundColor: AppColors.ink,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(
                    item.kind == NoticedKind.discoverable
                        ? 'Let people find me'
                        : 'Say what I sound like',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
