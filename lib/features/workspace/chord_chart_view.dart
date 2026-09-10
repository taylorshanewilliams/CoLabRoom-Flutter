import 'package:flutter/material.dart';

import '../../services/set_aside.dart';

import '../../app/colabroom_theme.dart';
import '../../services/chord_chart.dart';
import '../../services/chord_names.dart';
import 'music_reference_sheets.dart';
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
/// What the sheet needs to know about the song a chord came from.
typedef _SongContext = ({String? musicalKey, List<String> used, Set<String> roles});

/// The one line that says the chords are worth tapping.
///
/// Taylor: "lets make it easily accessible and known that this help is
/// available, without being overbearing or intrusive. seemless and intuitive,
/// thats the name of the game for this app."
///
/// So: said once, in the smallest type on the screen, under the chart rather
/// than over it — and never again after somebody has tapped a chord, because
/// at that point they know. A hint that keeps explaining a thing you have
/// already done is the same nag as the card that would not close.
///
/// It also only appears when there is something worth tapping *for*: with no
/// key detected the sheet can still show shapes, but "what works here" is
/// most of the reason to look, and promising it when the song cannot answer
/// is worse than staying quiet.
const String _chordHintId = 'tap_a_chord';

class ChordChartView extends StatelessWidget {
  const ChordChartView({
    required this.rows,
    required this.transpose,
    required this.fontScale,
    this.musicalKey,
    this.roles = const <String>{},
    super.key,
  });

  final List<ChartRow> rows;
  final int transpose;
  final double fontScale;

  /// The song's key, so a tapped chord can say where it sits rather than only
  /// what it is. Null when detection did not find one, which is a real
  /// outcome on plenty of recordings and simply means fewer answers.
  final String? musicalKey;

  /// What the person plays. Order only -- see `whatWorksHere`.
  final Set<String> roles;

  /// The song, gathered once and handed down to the chords.
  ///
  /// Passed rather than looked up from an InheritedWidget: three widgets deep
  /// is not far enough to justify one, and a chart that could be built with
  /// or without its song attached is a chart that will one day be built
  /// without it by accident.
  _SongContext get _song => (
        musicalKey: musicalKey,
        used: _used,
        roles: roles,
      );

  /// Every chord on this chart, so the sheet can say which of the key's
  /// chords the song has not reached for yet. That question is the whole
  /// difference between a reference and an answer.
  List<String> get _used => <String>[
        for (final row in rows)
          for (final bar in row.bars)
            for (final chord in bar.chords)
              if (chord.chord.trim().isNotEmpty) chord.chord,
      ];

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

    // Every row is built at once — this sits inside the sheet's own scroll
    // view, so it cannot be lazy. That is fine for a song: four minutes in
    // four at 120bpm is about thirty rows. It is not fine for a beat grid
    // that came back wrong, where thousands of "bars" would be laid out in
    // the frame that switches to the chart and the app would appear to hang.
    // Past a plainly impossible length, draw what fits and say so.
    const maxRows = 200;
    final drawn = rows.length > maxRows ? rows.sublist(0, maxRows) : rows;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (drawn.length != rows.length)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              'This recording came back with ${rows.length * 4} bars, which is '
              'more than a song has — the beat grid is probably wrong. Showing '
              'the first ${maxRows * 4}.',
              style: const TextStyle(
                color: AppColors.muted,
                fontSize: 11.5,
                height: 1.4,
              ),
            ),
          ),
        // Under the chart, not over it. Somebody who already knows does not
        // read it, and somebody who does not is looking at the chords when
        // they run out of ideas -- which is exactly where this sits.
        if (musicalKey != null && !SetAside.has(SetAside.hint, _chordHintId))
          Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 2),
            child: Row(
              children: <Widget>[
                Icon(Icons.touch_app_outlined,
                    size: 13, color: AppColors.muted.withValues(alpha: 0.8)),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    'Tap any chord for what works over it',
                    style: TextStyle(
                      color: AppColors.muted.withValues(alpha: 0.8),
                      fontSize: 11.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        for (final row in drawn) ...<Widget>[
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
          _ChartRowView(
              row: row,
              transpose: transpose,
              fontScale: fontScale,
              song: _song),
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
    required this.song,
  });

  final ChartRow row;
  final int transpose;
  final double fontScale;
  final _SongContext song;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      // Deliberately not CrossAxisAlignment.stretch. Stretch copies the
      // incoming maxHeight down as a *tight* constraint, and the chart is laid
      // out inside the song sheet's scroll view, where that height is
      // Infinity. Every row of every chart threw "BoxConstraints forces an
      // infinite height" on the bar number and the closing line — the two
      // children with no height of their own — and the Chart tab failed to lay
      // out at all.
      //
      // The fix is not to keep stretch and pin a height here: the row's real
      // height is whatever the chord text comes to, which moves with fontScale
      // and with the reader's OS text size. Instead nothing in this row asks
      // to be stretched. The bar cells size to their own content, they are all
      // built the same way so they agree on a height, and the lines are drawn
      // as their borders rather than as separate widgets that would need a
      // height handed to them.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
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
          for (var i = 0; i < row.bars.length; i += 1)
            Expanded(
              child: _BarCell(
                song: song,
                bar: row.bars[i],
                transpose: transpose,
                fontScale: fontScale,
                // Every bar draws its own opening line, so the last one has to
                // close the row or it hangs open.
                closing: i == row.bars.length - 1,
              ),
            ),
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
    required this.closing,
    required this.song,
  });

  final ChartBar bar;
  final _SongContext song;
  final int transpose;
  final double fontScale;

  /// Whether this is the last bar of its row, and so draws the line that
  /// closes it.
  final bool closing;

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
      decoration: BoxDecoration(
        border: Border(
          left: const BorderSide(color: AppColors.line, width: 1.5),
          right: closing
              ? const BorderSide(color: AppColors.line, width: 1.5)
              : BorderSide.none,
        ),
      ),
      padding: EdgeInsets.symmetric(vertical: 9 * fontScale, horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          for (var beat = 1; beat <= bar.beatsInBar; beat += 1)
            Expanded(
              child: _BeatSlot(
                  chord: byBeat[beat] ?? '',
                  fontScale: fontScale,
                  song: song),
            ),
        ],
      ),
    );
  }
}

/// One beat of a bar — a chord name, or the space that means "keep playing
/// the last one".
///
/// The chord is a tap target because a chart is read by people who can't yet
/// play every chord on it. The Toolbox used to answer that question in a
/// different tab, in a different key.
class _BeatSlot extends StatelessWidget {
  const _BeatSlot({
    required this.chord,
    required this.fontScale,
    required this.song,
  });

  final String chord;
  final double fontScale;
  final _SongContext song;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      chord,
      maxLines: 1,
      overflow: TextOverflow.visible,
      softWrap: false,
      style: TextStyle(
        color: AppColors.text,
        fontSize: 14.5 * fontScale,
        fontWeight: FontWeight.w800,
        height: 1.1,
        // The same dotted underline the sheet uses, for the same reason:
        // without it a chord on a chart is ink, and nobody taps ink.
        decoration: chord.isEmpty ? null : TextDecoration.underline,
        decorationStyle: TextDecorationStyle.dotted,
        decorationColor: AppColors.cyan.withValues(alpha: 0.55),
      ),
    );
    if (chord.isEmpty) return text;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => showChordReference(
        context,
        chord,
        keyLabel: song.musicalKey,
        used: song.used,
        roles: song.roles,
      ),
      child: text,
    );
  }
}
