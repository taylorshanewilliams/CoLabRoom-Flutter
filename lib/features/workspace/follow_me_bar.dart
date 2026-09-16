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
  const TogetherRow({required this.session, required this.me, this.onStopLeading, super.key});

  final FollowSession session;
  final String me;

  /// What Stop does while leading. Perform asks for a note first when
  /// somebody is following; without this it simply stops.
  final VoidCallback? onStopLeading;

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
          onStopLeading ?? () => session.stopLeading(),
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

/// Asks a leader who is stopping whether to leave the people following
/// something to practise from. Returns the note ('' for none), or null when
/// they changed their mind and are still leading.
///
/// Asked only when somebody is following: a teacher at the end of a lesson
/// has the one sentence the student most needs, and this is the moment it
/// is on the tip of their tongue. It goes to the student's Home with the
/// part and the speed they worked on, and nowhere else.
Future<String?> showLeaveANote(BuildContext context, {required int followers}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.deepNavy,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(sheetContext).bottom),
      child: LeaveANoteSheet(followers: followers),
    ),
  );
}

class LeaveANoteSheet extends StatefulWidget {
  const LeaveANoteSheet({required this.followers, super.key});

  final int followers;

  @override
  State<LeaveANoteSheet> createState() => _LeaveANoteSheetState();
}

class _LeaveANoteSheetState extends State<LeaveANoteSheet> {
  final TextEditingController _note = TextEditingController();

  @override
  void initState() {
    super.initState();
    _note.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final written = _note.text.trim().isNotEmpty;
    final who = widget.followers == 1 ? 'the person following' : 'the ${widget.followers} people following';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              'Leave them something to practise from?',
              style: TextStyle(color: AppColors.text, fontSize: 17, fontWeight: FontWeight.w800, height: 1.3),
            ),
            const SizedBox(height: 6),
            Text(
              'What you worked on is already kept for $who. A line from you goes with it.',
              style: const TextStyle(color: AppColors.muted, fontSize: 12.5, height: 1.4),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const Key('leave_a_note_text'),
              controller: _note,
              maxLength: leaderNoteMax,
              minLines: 1,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(color: AppColors.text, fontSize: 14.5),
              decoration: const InputDecoration(
                hintText: 'Keep it slow until the change is clean',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton(
              key: const Key('leave_a_note_stop'),
              onPressed: () => Navigator.pop(context, _note.text.trim()),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
                backgroundColor: AppColors.gold,
                foregroundColor: AppColors.ink,
              ),
              child: Text(written ? 'Stop and leave the note' : 'Stop without a note'),
            ),
            const SizedBox(height: 4),
            TextButton(
              key: const Key('leave_a_note_keep_leading'),
              onPressed: () => Navigator.pop(context),
              style: TextButton.styleFrom(
                minimumSize: const Size.fromHeight(40),
                foregroundColor: AppColors.muted,
              ),
              child: const Text('Keep leading'),
            ),
          ],
        ),
      ),
    );
  }
}
