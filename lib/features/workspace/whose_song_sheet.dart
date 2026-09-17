import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';

/// Whose song is this?
///
/// Asked once, in one sheet, the first time a song's audience moves beyond
/// "Only you" — and never again unless somebody opens it from the song's
/// menu to change the answer. Every Musician, Same Song, 17 September 2026
/// calls this one of the two gates: it is the difference between a song this
/// app can carry anywhere and one it has to keep in the room.
///
/// **Asked at the moment it matters, not at the start.** A question at song
/// creation would be a form standing between somebody and a first line, for
/// a song that will probably never leave their own phone. Asked when the
/// song is about to be heard by somebody else, it is obviously about the
/// thing they just pressed.
///
/// **Three plain answers and no legal words.** Nobody is agreeing to
/// anything, declaring anything, or being told about licensing. They are
/// saying where the song came from, in the words a musician would use.
Future<SongOrigin?> showWhoseSongSheet(
  BuildContext context, {
  required String songTitle,
  SongOrigin? answered,
}) {
  return showModalBottomSheet<SongOrigin>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: AppColors.deepNavy,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 2, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'Who wrote this song?',
              style: Theme.of(sheetContext).textTheme.headlineSmall,
            ),
            const SizedBox(height: 3),
            Text(
              songTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.muted, fontSize: 13),
            ),
            const SizedBox(height: 18),
            _Answer(
              answer: SongOrigin.ours,
              here: answered == SongOrigin.ours,
              label: 'We did',
              icon: Icons.group_outlined,
            ),
            _Answer(
              answer: SongOrigin.publicDomain,
              here: answered == SongOrigin.publicDomain,
              label: "It's old enough to be anyone's",
              icon: Icons.history_edu_outlined,
            ),
            _Answer(
              answer: SongOrigin.cover,
              here: answered == SongOrigin.cover,
              label: 'Somebody else',
              icon: Icons.person_outline_rounded,
            ),
            const SizedBox(height: 12),
            const Text(
              'You can change this later from the song menu.',
              style: TextStyle(
                  color: AppColors.muted, fontSize: 11.5, height: 1.4),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Answer extends StatelessWidget {
  const _Answer({
    required this.answer,
    required this.here,
    required this.label,
    required this.icon,
  });

  final SongOrigin answer;
  final bool here;
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: here
            ? AppColors.cyan.withValues(alpha: 0.10)
            : Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(11),
          side: BorderSide(
            color: here ? AppColors.cyan.withValues(alpha: 0.5) : AppColors.line,
          ),
        ),
        child: InkWell(
          key: Key('whose_song_${answer.name}'),
          onTap: () => Navigator.pop(context, answer),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
            child: Row(
              children: <Widget>[
                Icon(icon,
                    size: 18, color: here ? AppColors.cyan : AppColors.muted),
                const SizedBox(width: 11),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: AppColors.text,
                      fontSize: 14,
                      fontWeight: here ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
