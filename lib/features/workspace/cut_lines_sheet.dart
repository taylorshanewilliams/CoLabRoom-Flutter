import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../app/music_beta_controller.dart';
import '../../domain/music_models.dart';
import 'continuous_song_editor.dart';

/// Your cut lines.
///
/// A line taken out of a song is not deleted any more: it is marked cut and
/// kept for whoever wrote it, whoever cut it (migration 0153, the second half
/// of "nobody's words disappear" in Every Musician, Same Song, 17 September
/// 2026). This is where the writer finds it again.
///
/// **On the song, not in the Ideas room.** The plan offered either. A copy
/// in the writer's own Ideas room would be a new line in a new song, made in
/// somebody else's catalogue by whoever cut it, without its voice note or its
/// place. The list keeps the line itself and costs nothing new.
///
/// **Yours and only yours.** The person who cut the line sees nothing of it
/// here unless they wrote it. The words are read when the sheet opens, not
/// carried on the song: a cut line is not part of the song, and nothing that
/// draws the song can see one.
///
/// No dates, no count. When a line came out is not something a writer needs
/// to be told, and the list is as long as it is.
Future<void> showCutLinesSheet(
  BuildContext context, {
  required SongProject project,
  required MusicBetaController controller,
}) {
  final lines = controller.linesYouCut(project);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: AppColors.deepNavy,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        key: const Key('cut_lines_sheet'),
        padding: const EdgeInsets.fromLTRB(20, 2, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'Your cut lines',
              style: Theme.of(sheetContext).textTheme.headlineSmall,
            ),
            const SizedBox(height: 3),
            Text(
              project.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.muted, fontSize: 13),
            ),
            const SizedBox(height: 14),
            Flexible(child: _CutLines(lines: lines)),
          ],
        ),
      ),
    ),
  );
}

class _CutLines extends StatelessWidget {
  const _CutLines({required this.lines});

  final Future<List<Contribution>> lines;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Contribution>>(
      future: lines,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Your cut lines could not be read just now.',
              style: TextStyle(color: AppColors.muted, fontSize: 13.5, height: 1.4),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        // A cut blank line is nothing to find again.
        final kept = snapshot.data!
            .where((line) => displayContributionBody(line.body).trim().isNotEmpty)
            .toList(growable: false);
        if (kept.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Nothing of yours has been cut from this song. '
              'When a line of yours comes out, it waits here.',
              style: TextStyle(color: AppColors.muted, fontSize: 13.5, height: 1.4),
            ),
          );
        }
        return ListView.separated(
          shrinkWrap: true,
          itemCount: kept.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (context, index) => _CutLine(line: kept[index]),
        );
      },
    );
  }
}

class _CutLine extends StatelessWidget {
  const _CutLine({required this.line});

  final Contribution line;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: Key('cut_line_${line.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // The writer's colour in this room, the same dot the rail shows
        // beside a line that is still in the song.
        Padding(
          padding: const EdgeInsets.only(top: 7, right: 11),
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: Color(line.colorValue),
              shape: BoxShape.circle,
            ),
          ),
        ),
        Expanded(
          // Selectable, so the words can be carried back into the song or
          // anywhere else by hand. Putting a line back in its place is not
          // this sheet's job.
          child: SelectableText(
            displayContributionBody(line.body),
            style: const TextStyle(color: AppColors.text, fontSize: 15, height: 1.45),
          ),
        ),
      ],
    );
  }
}
