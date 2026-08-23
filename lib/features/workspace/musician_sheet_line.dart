import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:flutter/material.dart';

typedef MusicianChordTap = void Function(
  MusicianSheetLine line,
  ChordCue chord,
  int wordIndex,
);
typedef MusicianWordTap = void Function(
  MusicianSheetLine line,
  int wordIndex,
);

class MusicianSectionLine extends StatelessWidget {
  const MusicianSectionLine({
    required this.line,
    required this.fontScale,
    this.liveMode = false,
    super.key,
  });

  final MusicianSheetLine line;
  final double fontScale;
  final bool liveMode;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        top: liveMode ? 22 : 18,
        bottom: liveMode ? 8 : 7,
      ),
      child: Text(
        line.body.toUpperCase(),
        style: TextStyle(
          color: liveMode
              ? AppColors.gold
              : const Color(0xFF7A6C5A),
          fontSize: (liveMode ? 10.5 : 9.5) * fontScale,
          fontWeight: FontWeight.w900,
          letterSpacing: liveMode ? 1.55 : 1.3,
        ),
      ),
    );
  }
}

class MusicianChordLyricLine extends StatelessWidget {
  const MusicianChordLyricLine({
    required this.line,
    required this.transpose,
    required this.fontScale,
    required this.showChords,
    this.editable = false,
    this.liveMode = false,
    this.active = false,
    this.onEditChord,
    this.onAddChord,
    super.key,
  });

  final MusicianSheetLine line;
  final int transpose;
  final double fontScale;
  final bool showChords;
  final bool editable;
  final bool liveMode;
  final bool active;
  final MusicianChordTap? onEditChord;
  final MusicianWordTap? onAddChord;

  @override
  Widget build(BuildContext context) {
    final words = line.body
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList(growable: false);
    final placements = chordPlacementsForLine(
      wordCount: words.length,
      lineStartMs: line.startMs,
      lineEndMs: line.endMs,
      chords: line.chords,
      wordStartsMs: line.wordStartsMs,
    );
    return Padding(
      padding: EdgeInsets.symmetric(vertical: liveMode ? 3 : 4),
      child: Wrap(
        spacing: liveMode ? 7 : 5,
        runSpacing: liveMode ? 9 : 7,
        crossAxisAlignment: WrapCrossAlignment.end,
        children: <Widget>[
          // The bar this line starts on, in the gutter where it sits on
          // paper. Only ever present when the recording gave a real beat
          // grid and the line's timing is measured — see MusicianSheetLine.bar.
          if (line.bar != null && showChords)
            _BarMarker(
              number: line.bar!,
              fontScale: fontScale,
              liveMode: liveMode,
            ),
          for (var index = 0; index < words.length; index += 1)
            _ChordWord(
              key: ValueKey<String>(
                '${line.contributionId ?? line.body}-$index',
              ),
              word: words[index],
              line: line,
              chord: placements[index],
              wordIndex: index,
              transpose: transpose,
              fontScale: fontScale,
              showChords: showChords,
              editable: editable,
              liveMode: liveMode,
              active: active,
              onEditChord: onEditChord,
              onAddChord: onAddChord,
            ),
        ],
      ),
    );
  }
}

/// The bar number, set quietly beside the line rather than in it — a
/// reference point you look for when you need it, not something competing
/// with the words for attention while you're singing.
class _BarMarker extends StatelessWidget {
  const _BarMarker({
    required this.number,
    required this.fontScale,
    required this.liveMode,
  });

  final int number;
  final double fontScale;
  final bool liveMode;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Sits on the chord row, not the lyric row: it's information about the
      // music, and it lines up with the chords above the words.
      padding: EdgeInsets.only(bottom: liveMode ? 2 : 1, right: 2),
      child: Text(
        '$number',
        style: TextStyle(
          color: const Color(0xFF7A6C5A),
          fontSize: (liveMode ? 10 : 9) * fontScale,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _ChordWord extends StatelessWidget {
  const _ChordWord({
    required this.word,
    required this.line,
    required this.chord,
    required this.wordIndex,
    required this.transpose,
    required this.fontScale,
    required this.showChords,
    required this.editable,
    required this.liveMode,
    required this.active,
    required this.onEditChord,
    required this.onAddChord,
    super.key,
  });

  final String word;
  final MusicianSheetLine line;
  final ChordCue? chord;
  final int wordIndex;
  final int transpose;
  final double fontScale;
  final bool showChords;
  final bool editable;
  final bool liveMode;
  final bool active;
  final MusicianChordTap? onEditChord;
  final MusicianWordTap? onAddChord;

  void _activate() {
    final existing = chord;
    if (existing != null) {
      onEditChord?.call(line, existing, wordIndex);
    } else {
      onAddChord?.call(line, wordIndex);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chordText =
        chord == null ? '' : transposeChord(chord!.chord, transpose);
    final chordWidget = chord == null
        ? const SizedBox.shrink()
        : InkWell(
            key: chord!.id == null ? null : Key('edit_chord_${chord!.id}'),
            onTap: editable ? _activate : null,
            borderRadius: BorderRadius.circular(5),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 1),
              child: Text(
                chordText,
                style: TextStyle(
                  color: liveMode
                      ? AppColors.gold
                      : chord!.isManual
                          ? const Color(0xFF0D655F)
                          : const Color(0xFF197A74),
                  fontFamily: 'monospace',
                  fontSize: (liveMode ? 10.8 : 11.2) * fontScale,
                  height: 1,
                  fontWeight: FontWeight.w900,
                  decoration: editable ? TextDecoration.underline : null,
                  decorationStyle: TextDecorationStyle.dotted,
                ),
              ),
            ),
          );

    // widthFactor is intentional. Without it, Align consumes the complete
    // Wrap width and turns every lyric word into its own visual row.
    final chordLabel = SizedBox(
      height: showChords ? (liveMode ? 16.5 : 16) * fontScale : 0,
      child: showChords
          ? Align(
              alignment: Alignment.bottomLeft,
              widthFactor: 1,
              child: chordWidget,
            )
          : null,
    );
    final lyric = AnimatedDefaultTextStyle(
      duration: const Duration(milliseconds: 220),
      style: TextStyle(
        color: liveMode
            ? active
                ? Colors.white
                : const Color(0xFFF3F7FC)
            : const Color(0xFF2A231B),
        fontFamily: 'monospace',
        fontSize: (liveMode ? 13.0 : 13.2) * fontScale,
        height: liveMode ? 1.16 : 1.12,
        fontWeight: active ? FontWeight.w700 : FontWeight.w500,
        decoration: editable ? TextDecoration.underline : null,
        decorationStyle: TextDecorationStyle.dotted,
        decorationColor:
            liveMode ? AppColors.gold.withValues(alpha: 0.4) : const Color(0x557A6C5A),
      ),
      child: Text(word),
    );

    return IntrinsicWidth(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          chordLabel,
          if (editable)
            InkWell(
              key: Key(
                'place_chord_${line.contributionId ?? 'transcript'}_$wordIndex',
              ),
              onTap: _activate,
              borderRadius: BorderRadius.circular(5),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 1, vertical: 1),
                child: lyric,
              ),
            )
          else
            lyric,
        ],
      ),
    );
  }
}
