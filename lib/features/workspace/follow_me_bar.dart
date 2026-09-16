import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../services/follow_me.dart';

/// Somebody is leading this song: one line on the song itself, and Follow.
///
/// On the song rather than in a notification, because the only people it
/// is for are the ones already looking at the song -- in the same room, or
/// on a call, having just been told "open Mountains". Nothing moves until
/// they press it.
class FollowBanner extends StatelessWidget {
  const FollowBanner({required this.leaderName, required this.onFollow, super.key});

  final String leaderName;
  final VoidCallback onFollow;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const Key('follow_banner'),
      color: AppColors.gold.withValues(alpha: 0.1),
      child: InkWell(
        onTap: onFollow,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
          child: Row(
            children: <Widget>[
              const Icon(Icons.play_circle_outline_rounded, size: 18, color: AppColors.gold),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '$leaderName is leading this song',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.text, fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ),
              TextButton(
                key: const Key('follow_banner_follow'),
                onPressed: onFollow,
                child: const Text(
                  'Follow',
                  style: TextStyle(color: AppColors.gold, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The line at the top of Perform's controls when the song is open on
/// more than one phone.
///
/// Absent when you are alone with the song, which is most of the time; it
/// appears the moment somebody else opens it, already saying what you can
/// do about that. One sentence and one verb, in four states: somebody is
/// here (Lead), somebody leads (Follow), you follow (Stop), you lead (Stop).
class TogetherRow extends StatelessWidget {
  const TogetherRow({required this.session, required this.me, super.key});

  final FollowSession session;
  final String me;

  @override
  Widget build(BuildContext context) {
    final leader = session.leader;
    final (String words, String verb, Key key, VoidCallback onTap, Color accent) =
        switch (session) {
      FollowSession(leading: true) => (
          session.followers == 0
              ? 'Leading · nobody following yet'
              : 'Leading · ${session.followers} following',
          'Stop',
          const Key('together_stop_leading'),
          session.stopLeading,
          AppColors.gold,
        ),
      FollowSession(following: true) => (
          'Following ${leader?.name ?? 'along'}',
          'Stop',
          const Key('together_unfollow'),
          session.unfollow,
          AppColors.green,
        ),
      _ when leader != null => (
          '${leader.name} is leading',
          'Follow',
          const Key('together_follow'),
          session.follow,
          AppColors.gold,
        ),
      _ => (
          whoIsHere(session.others, me),
          'Lead',
          const Key('together_lead'),
          session.lead,
          AppColors.green,
        ),
    };
    return SizedBox(
      key: const Key('together_row'),
      height: 32,
      child: Row(
        children: <Widget>[
          const SizedBox(width: 6),
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              words,
              key: const Key('together_words'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.text, fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
          TextButton(
            key: key,
            onPressed: onTap,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: Text(
              verb,
              style: TextStyle(color: accent, fontSize: 12.5, fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
  }

  /// Whether the row has anything to say.
  static bool shows(FollowSession session) =>
      session.leading || session.following || session.leader != null || session.others.isNotEmpty;
}
