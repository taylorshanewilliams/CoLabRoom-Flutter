import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../domain/song_analysis_models.dart';
import 'sung_vs_written.dart';
import '../../widgets/note_that_fits.dart';

/// Where one line is taken across: the sung words become the written line.
typedef UseSungLine = Future<void> Function(Contribution line, String words);

/// What was sung, beside what was written.
///
/// A sheet over the song sheet, one row per written line: the line as it is
/// on the page and, under it, what the recording says at that line. The words
/// on both sides are muted and the words on one side only are in the full
/// text colour, so the eye lands where the singer and the page part and
/// nothing says which of them is right. No count of differences, no
/// percentage, nothing red (Every Musician, Same Song, 17 September 2026,
/// slice 37).
///
/// Each row that differs offers to take the sung words into the written
/// line, one line at a time. The whole page at once is the existing "Fill in
/// my lyrics from the Song Sheet", which asks first; this never does more
/// than the one line that was tapped, and the row shows what it did.
Future<void> showSungAndWritten(
  BuildContext context, {
  required SongProject project,
  required SongAnalysisBundle bundle,
  UseSungLine? onUseSung,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: AppColors.deepNavy,
    builder: (_) => SungAndWrittenSheet(
      project: project,
      bundle: bundle,
      onUseSung: onUseSung,
    ),
  );
}

class SungAndWrittenSheet extends StatefulWidget {
  const SungAndWrittenSheet({
    required this.project,
    required this.bundle,
    this.onUseSung,
    super.key,
  });

  final SongProject project;
  final SongAnalysisBundle bundle;

  /// Null for somebody the room only lets look, which leaves the comparison
  /// something to read.
  final UseSungLine? onUseSung;

  @override
  State<SungAndWrittenSheet> createState() => _SungAndWrittenSheetState();
}

class _SungAndWrittenSheetState extends State<SungAndWrittenSheet> {
  /// The song as this sheet knows it. A line taken across changes the copy
  /// here the moment the write lands, so the row reads as sung as written
  /// whether or not the screen underneath has refreshed yet.
  late SongProject _project = widget.project;
  late List<SungWrittenLine> _rows =
      pairSungWithWritten(_project, widget.bundle);

  /// The line being written, while it is.
  String? _busyLineId;

  Future<void> _useSung(SungWrittenLine row) async {
    final write = widget.onUseSung;
    final line = row.line;
    if (write == null || line == null || _busyLineId != null) return;
    final words = row.sung;
    setState(() => _busyLineId = line.id);
    try {
      await write(line, words);
      if (!mounted) return;
      setState(() {
        _project = _project.copyWith(
          contributions: <Contribution>[
            for (final each in _project.contributions)
              each.id == line.id ? each.copyWith(body: words) : each,
          ],
        );
        _rows = pairSungWithWritten(_project, widget.bundle);
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showNote('Could not change that line: $error');
    } finally {
      if (mounted) setState(() => _busyLineId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        key: const Key('sung_and_written_sheet'),
        padding: const EdgeInsets.fromLTRB(20, 2, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'Sung and written',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 3),
            Text(
              _project.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.muted, fontSize: 13),
            ),
            const SizedBox(height: 6),
            const Text(
              'What the recording says at each line, beside what is on the page.',
              style: TextStyle(color: AppColors.muted, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 14),
            Flexible(
              child: _rows.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'Nothing to put side by side yet.',
                        style: TextStyle(color: AppColors.muted, fontSize: 13.5, height: 1.4),
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: _rows.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 14),
                      itemBuilder: (context, index) => _Row(
                        row: _rows[index],
                        index: index,
                        busy: _busyLineId != null,
                        onUseSung: widget.onUseSung == null ? null : _useSung,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.row,
    required this.index,
    required this.busy,
    required this.onUseSung,
  });

  final SungWrittenLine row;
  final int index;
  final bool busy;
  final void Function(SungWrittenLine row)? onUseSung;

  @override
  Widget build(BuildContext context) {
    final line = row.line;
    final key = line == null
        ? Key('sung_only_$index')
        : Key('sung_written_${line.id}');
    if (row.differs) {
      return Column(
        key: key,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const _Label('Written'),
          _Words(row.writtenWords, comparing: true),
          const SizedBox(height: 8),
          const _Label('Sung'),
          _Words(row.sungWords, comparing: true),
          if (onUseSung != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                key: Key('use_sung_${line!.id}'),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.gold,
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: busy ? null : () => onUseSung!(row),
                // Size and weight on the label, where they merge into the
                // theme's style, never on the button (see
                // button_labels_keep_their_font).
                child: const Text(
                  'Use what was sung',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                ),
              ),
            ),
        ],
      );
    }
    if (row.readsTheSame) {
      return Column(
        key: key,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _Words(row.writtenWords, comparing: false),
          const SizedBox(height: 3),
          const _Note('Sung as written'),
        ],
      );
    }
    if (row.onThePage) {
      return Column(
        key: key,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _Words(row.writtenWords, comparing: false),
          const SizedBox(height: 3),
          const _Note('Not sung in this recording'),
        ],
      );
    }
    // Sung on no line of its own: either words the page does not have, or a
    // line the page has once and the recording more than once.
    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const _Label('Sung'),
        _Words(row.sungWords, comparing: false),
        const SizedBox(height: 3),
        _Note(row.sungAgain ? 'Also sung here' : 'Not on the page'),
      ],
    );
  }
}

/// A line of words. While [comparing], the words on both sides fall back
/// and the words on one side only stay in the text colour — the same colour
/// every other word on this sheet is in, because a difference is a fact and
/// not a fault.
class _Words extends StatelessWidget {
  const _Words(this.words, {required this.comparing});

  final List<ComparedWord> words;
  final bool comparing;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: <InlineSpan>[
          for (var i = 0; i < words.length; i += 1) ...<InlineSpan>[
            if (i > 0) const TextSpan(text: ' '),
            TextSpan(
              text: words[i].text,
              style: TextStyle(
                color: comparing && words[i].shared
                    ? AppColors.muted
                    : AppColors.text,
              ),
            ),
          ],
        ],
      ),
      style: const TextStyle(color: AppColors.text, fontSize: 15, height: 1.45),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(
        text,
        style: const TextStyle(
          color: AppColors.muted,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(color: AppColors.muted, fontSize: 11, height: 1.3),
    );
  }
}
