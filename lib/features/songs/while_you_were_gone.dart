import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../domain/activity.dart';
import '../../widgets/app_surface.dart';
import '../../widgets/player_face.dart';
import '../workspace/song_workspace_screen.dart';

/// What happened while you were not looking.
///
/// This was the one thing on the old Home screen that existed nowhere else.
/// Home's other five sections — start a song, recent songs, an Open Mic
/// preview, your catalogs — were each a summary of somewhere else in the app,
/// which is what made it a dashboard rather than a place. Nobody thinks "I
/// will go to the summary".
///
/// So the summary went, and the news came here: to the top of the songs you
/// were going to open anyway. It draws nothing at all on a quiet week, which
/// is the point — a band that has not played must not be shown a panel
/// announcing that.
class WhileYouWereGone extends StatelessWidget {
  const WhileYouWereGone({required this.activity, super.key});

  final List<ActivityItem> activity;

  @override
  Widget build(BuildContext context) {
    if (activity.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 4, 0, 10),
          child: Text('While you were gone',
              style: Theme.of(context).textTheme.titleLarge),
        ),
        for (var i = 0; i < activity.length; i += 1) ...<Widget>[
          if (i > 0) const SizedBox(height: 8),
          Dismissible(
            // Keyed on the event rather than the index, or dismissing one row
            // animates a different one away.
            key: ValueKey<String>('activity-${activity[i].id}'),
            direction: DismissDirection.endToStart,
            background: const _DismissBackground(),
            onDismissed: (_) => _dismissActivity(context, activity[i]),
            child: _ActivityRow(
              item: activity[i],
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      SongWorkspaceScreen(projectId: activity[i].projectId),
                ),
              ),
              // A swipe is not discoverable on its own, and nothing else in
              // the app is swipeable to teach it.
              onDismiss: () => _dismissActivity(context, activity[i]),
            ),
          ),
        ],
        const SizedBox(height: 18),
      ],
    );
  }
}

class _DismissBackground extends StatelessWidget {
  const _DismissBackground();

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 18),
      decoration: BoxDecoration(
        color: AppColors.raised,
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Icon(Icons.check_rounded, size: 19, color: AppColors.green),
    );
  }
}

/// Puts one item away, and offers it straight back.
///
/// The undo is not decoration. Somebody clearing a feed quickly will bin the
/// one thing they meant to read, and a dismissal that cannot be taken back
/// makes the whole gesture something to be careful with — which is the
/// opposite of what it is for.
void _dismissActivity(BuildContext context, ActivityItem item) {
  final controller = BetaScope.of(context, listen: false);
  final messenger = ScaffoldMessenger.of(context);
  unawaited(controller.dismissActivity(item.id));
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text('Cleared ${item.projectTitle}'),
      duration: const Duration(seconds: 4),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => unawaited(controller.restoreActivity(item)),
      ),
    ),
  );
}

/// One thing somebody did, as a sentence with a face on it.
class _ActivityRow extends StatelessWidget {
  const _ActivityRow({
    required this.item,
    required this.onTap,
    required this.onDismiss,
  });

  final ActivityItem item;
  final VoidCallback onTap;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: AppSurface(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // The activity view has carried actor_avatar_path since 0044 and
            // nothing ever drew it.
            PlayerFace(
              name: item.actorName,
              photo: BetaScope.of(context).avatarBytesFor(item.actorAvatarPath),
              size: 30,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    item.sentence,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13.5, height: 1.35),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    // The song is the part somebody scans for, so it is not
                    // buried inside the sentence.
                    item.projectTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.cyan,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text(
                  shortAgo(item.at),
                  style: const TextStyle(color: AppColors.muted, fontSize: 11),
                ),
                const SizedBox(height: 4),
                InkResponse(
                  onTap: onDismiss,
                  radius: 18,
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(Icons.close_rounded,
                        size: 15, color: AppColors.muted),
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
