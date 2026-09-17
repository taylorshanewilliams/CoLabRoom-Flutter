import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/music_reference_sheets.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:colabroom/features/workspace/practice_rules.dart';
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
    this.musicalKey,
    required this.fontScale,
    required this.showChords,
    this.editable = false,
    this.liveMode = false,
    this.active = false,
    this.elapsedMs,
    this.melody,
    this.selectedChordStartMs,
    this.onEditChord,
    this.onAddChord,
    super.key,
  });

  final MusicianSheetLine line;
  final int transpose;

  /// The song's key before transposing, so chords are spelled the way the
  /// key writes them (B♭, not A♯). Null when none was found.
  final String? musicalKey;
  final double fontScale;
  final bool showChords;
  final bool editable;
  final bool liveMode;
  final bool active;

  /// The tune the recording was sung to, for the line being sung.
  ///
  /// With it, and with word timing on the line, each word carries the note
  /// it is sung on underneath -- G4, A4, A4, B4 -- the way the chords sit
  /// above. Only ever set on the active line in Perform: a page of notes
  /// under every word is a score, and this is a sheet.
  final Melody? melody;

  /// Where the song is, for the line being sung.
  ///
  /// Set only on the active line in Perform. With it, and with real word
  /// timing on the line, each word is coloured by whether it has been sung,
  /// is being sung, or is still to come -- the words light up one by one.
  /// Without it the line is lit as a whole, which is what it always did.
  final int? elapsedMs;

  /// Where the cue the keyboard is holding starts.
  ///
  /// Keyed on startMs rather than id because a cue id is nullable and a
  /// start is not — and startMs is what saveManualChordCue already uses to
  /// find the row, so the selection and the save agree by construction.
  final int? selectedChordStartMs;
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
    final sung = liveMode && active
        ? wordAt(line.wordStartsMs, elapsedMs, words.length)
        : null;
    final notes = liveMode && active
        ? notesForWords(melody, line.wordStartsMs, line.endMs, words.length)
        : const <String?>[];
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
              musicalKey: musicalKey,
              fontScale: fontScale,
              showChords: showChords,
              editable: editable,
              liveMode: liveMode,
              active: active,
              moment: sung == null
                  ? WordMoment.whole
                  : index < sung
                      ? WordMoment.sung
                      : index == sung
                          ? WordMoment.now
                          : WordMoment.later,
              note: index < notes.length ? notes[index] : null,
              showNotes: notes.isNotEmpty,
              selected: selectedChordStartMs != null &&
                  placements[index]?.startMs == selectedChordStartMs,
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

/// Where one word stands in the singing of its line.
///
/// [whole] is a line without word timing, or one that is not being sung:
/// every word the same. The other three only ever appear together on the
/// active line, and they are what makes a line read as being sung rather
/// than merely current.
enum WordMoment { whole, sung, now, later }

class _ChordWord extends StatelessWidget {
  const _ChordWord({
    required this.word,
    required this.line,
    required this.chord,
    required this.wordIndex,
    required this.transpose,
    this.musicalKey,
    required this.fontScale,
    required this.showChords,
    required this.editable,
    required this.liveMode,
    required this.active,
    required this.moment,
    required this.selected,
    required this.onEditChord,
    required this.onAddChord,
    this.note,
    this.showNotes = false,
    super.key,
  });

  final String word;
  final MusicianSheetLine line;
  final ChordCue? chord;
  final int wordIndex;
  final int transpose;
  final String? musicalKey;
  final double fontScale;
  final bool showChords;
  final bool editable;
  final bool liveMode;
  final bool active;
  final WordMoment moment;

  /// The note this word is sung on, as a singer says it ("G4"), and
  /// whether the line is showing notes at all -- a word without one keeps
  /// the space, so the words along a line stay level.
  final String? note;
  final bool showNotes;

  /// Whether the keyboard is holding this chord.
  ///
  /// Visible from across a desk, because otherwise the arrow keys are moving
  /// something nobody can see, which is worse than not having them.
  final bool selected;
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
    // Written the way it goes on paper (ChordMini stores Harte, so without
    // this the sheet reads "C:maj"), in the key being played.
    final chordText = chord == null
        ? ''
        : chordAsPlayed(chord!.chord, transpose: transpose, key: musicalKey);
    final chordWidget = chord == null
        ? const SizedBox.shrink()
        : InkWell(
            key: chord!.id == null ? null : Key('edit_chord_${chord!.id}'),
            // A chord on the sheet answers a question before it asks one:
            // most of the time somebody tapping A♯ wants to know how to play
            // A♯, not to correct it. Correcting is the deliberate mode with
            // its own banner, and it keeps the tap while it is on.
            //
            // Not in live mode — a modal over the words while somebody is
            // playing along is the one place this would be an interruption
            // rather than an answer.
            onTap: editable
                ? _activate
                : liveMode
                    ? null
                    : () => showChordReference(context, chordText),
            borderRadius: BorderRadius.circular(5),
            // A chord that answers when tapped is worth nothing if nobody
            // taps it. On paper a chord is just ink, so it needs to look
            // like it holds something: a pale tint behind it and a dotted
            // underline — the oldest "there is more here" mark there is —
            // which together cost almost no ink but change what the eye
            // reads it as. Not in live mode, where nothing is tappable and
            // an affordance would be a lie.
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
              decoration: liveMode
                  ? null
                  : BoxDecoration(
                      color: selected
                          ? AppColors.cyan.withValues(alpha: 0.22)
                          : const Color(0xFF197A74)
                              .withValues(alpha: editable ? 0.16 : 0.08),
                      borderRadius: BorderRadius.circular(5),
                      border: selected
                          ? Border.all(color: AppColors.cyan, width: 1.2)
                          : null,
                    ),
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
                  decoration:
                      liveMode ? null : TextDecoration.underline,
                  decorationStyle: TextDecorationStyle.dotted,
                  decorationColor: const Color(0xFF197A74)
                      .withValues(alpha: editable ? 0.9 : 0.55),
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
    // The word being sung is gold; the ones already sung stay white; the
    // ones still to come wait in the wings. A word takes a few hundred
    // milliseconds, so the colour change is quick -- a slow fade would still
    // be arriving on a word as the next one started.
    final lyricColor = switch (moment) {
      WordMoment.now => AppColors.gold,
      WordMoment.later => Colors.white.withValues(alpha: 0.5),
      WordMoment.sung => Colors.white,
      WordMoment.whole => liveMode
          ? active
              ? Colors.white
              : const Color(0xFFF3F7FC)
          : const Color(0xFF2A231B),
    };
    final lyric = AnimatedDefaultTextStyle(
      duration: Duration(milliseconds: moment == WordMoment.whole ? 220 : 90),
      style: TextStyle(
        color: lyricColor,
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
          // The note under the word, where a singer's eye goes after the
          // word itself. Gold on the word being sung, quiet on the rest, and
          // never a guess: a word the tracker heard nothing in gets a blank
          // of the same height, not a dash.
          if (showNotes)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: SizedBox(
                height: 12 * fontScale,
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 90),
                  style: TextStyle(
                    color: moment == WordMoment.now
                        ? AppColors.gold
                        : Colors.white.withValues(alpha: 0.42),
                    fontFamily: 'monospace',
                    fontSize: 9.4 * fontScale,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                  child: Text(note ?? ''),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
