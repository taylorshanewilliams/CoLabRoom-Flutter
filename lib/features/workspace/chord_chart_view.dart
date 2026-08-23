import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../services/chord_chart.dart';
import '../../services/chord_names.dart';
import 'musician_sheet_logic.dart' show transposeChord;

/// The song as bars.
///
/// The lyric sheet puts chords above the words you sing. This puts them in
/// bars, which is what you want when you're comping, when the song has no
/// words yet, or when you're handing it to someone else to play.
///
/// Read it the way a chart is read: a chord is written where it *changes*, and
/// an empty bar means keep playing the last one. That falls out of the data
/// rather than being a rule imposed here — snapping already merged repeated
/// chords into one cue, so a chord held for four bars is one cue that starts
/// in the first of them.
class ChordChartView extends StatelessWidget {
  const ChordChartView({
    required this.rows,
    required this.transpose,
    required this.fontScale,
    super.key,
  });

  final List<ChartRow> rows;
  final int transpose;
  final double fontScale;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
        decoration: BoxDecoration(
          color: AppColors.raised,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.line),
        ),
        // Bars are the one thing here that can't be estimated. Saying so is
        // better than drawing a grid that looks right and isn't.
        child: const Text(
          'No bar grid for this recording yet — analyze it to lay the chords '
          'out in bars.',
          style: TextStyle(color: AppColors.muted, fontSize: 12, height: 1.4),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final row in rows) ...<Widget>[
          if (row.sectionLabel != null)
            Padding(
              padding: const EdgeInsets.only(top: 14, bottom: 5, left: 2),
              child: Text(
                row.sectionLabel!.toUpperCase(),
                style: TextStyle(
                  color: AppColors.gold,
                  fontSize: 10 * fontScale,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.4,
                ),
              ),
            ),
          _ChartRowView(row: row, transpose: transpose, fontScale: fontScale),
        ],
      ],
    );
  }
}

class _ChartRowView extends StatelessWidget {
  const _ChartRowView({
    required this.row,
    required this.transpose,
    required this.fontScale,
  });

  final ChartRow row;
  final int transpose;
  final double fontScale;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // The bar number in the margin, like a printed chart. Only on the
          // first bar of the line — numbering every bar turns the page into
          // arithmetic.
          SizedBox(
            width: 24 * fontScale,
            child: Padding(
              padding: const EdgeInsets.only(top: 12, right: 4),
              child: Text(
                '${row.firstBarNumber}',
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: AppColors.muted,
                  fontSize: 9.5 * fontScale,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          for (final bar in row.bars)
            Expanded(
              child: _BarCell(bar: bar, transpose: transpose, fontScale: fontScale),
            ),
          // The closing line. Every bar draws its own opening line, so
          // without this the last bar of a row is left hanging open.
          Container(width: 1.5, color: AppColors.line),
        ],
      ),
    );
  }
}

class _BarCell extends StatelessWidget {
  const _BarCell({
    required this.bar,
    required this.transpose,
    required this.fontScale,
  });

  final ChartBar bar;
  final int transpose;
  final double fontScale;

  @override
  Widget build(BuildContext context) {
    // One slot per beat, so a chord on beat 3 sits halfway across a 4/4 bar
    // without any arithmetic about pixel positions. It also stays right when
    // the bar isn't in four, which happens more than people expect.
    final byBeat = <int, String>{};
    for (final chord in bar.chords) {
      byBeat[chord.beat] = chordDisplay(transposeChord(chord.chord, transpose));
    }
    return Container(
      decoration: const BoxDecoration(
        border: Border(left: BorderSide(color: AppColors.line, width: 1.5)),
      ),
      padding: EdgeInsets.symmetric(vertical: 9 * fontScale, horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          for (var beat = 1; beat <= bar.beatsInBar; beat += 1)
            Expanded(
              child: Text(
                byBeat[beat] ?? '',
                maxLines: 1,
                overflow: TextOverflow.visible,
                softWrap: false,
                style: TextStyle(
                  color: AppColors.text,
                  fontSize: 14.5 * fontScale,
                  fontWeight: FontWeight.w800,
                  height: 1.1,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
