import 'dart:math' as math;

import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/music_reference_sheets.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:colabroom/features/workspace/practice_rules.dart';
import 'package:colabroom/services/melody_reading.dart';
import 'package:colabroom/services/number_reading.dart';
import 'package:colabroom/services/rehearsal_letters.dart';
import 'package:colabroom/services/song_language.dart';
import 'package:colabroom/widgets/text_measures.dart';
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

/// A chord held down: the change it is, offered on repeat.
///
/// Where a chord ends up on repeat is not the line's business — the sheet
/// hands it to Perform and Perform already has a loop — so all that travels
/// up is which change was held (Every Musician, Same Song, 17 September
/// 2026).
typedef MusicianChordHold = void Function(ChordCue chord);

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
    return _ReadThisWay(
      language: line.language,
      child: Padding(
      padding: EdgeInsets.only(
        top: liveMode ? 22 : 18,
        bottom: liveMode ? 8 : 7,
      ),
      child: Text(
        // The rehearsal letter first, where the part has one: "B  CHORUS".
        // It is what gets said out loud — "from B" — and the name is what
        // it means (Every Musician, Same Song, 17 September 2026). A heading
        // somebody typed into the song carries no letter and is printed
        // exactly as it always was, and a part the analysis lettered itself
        // prints that letter once (see rehearsal_letters.dart).
        letteredHeading(line.letter, line.body),
        style: TextStyle(
          color: liveMode
              ? AppColors.gold
              : const Color(0xFF7A6C5A),
          fontSize: (liveMode ? 10.5 : 9.5) * fontScale,
          fontWeight: FontWeight.w900,
          letterSpacing: liveMode ? 1.55 : 1.3,
        ),
      ),
      ),
    );
  }
}

/// The page, turned the way this song is read (0163).
///
/// A song nobody has said anything about gets nothing: [child] is returned
/// as it is, so every sheet that existed before this is laid out by exactly
/// the widgets that laid it out before. A song somebody said is in Arabic,
/// Hebrew, Persian or Urdu is wrapped in a right-to-left Directionality,
/// and that one wrapper is what turns the whole line round — the Wrap lays
/// its words from the right, each word's column aligns its chord over the
/// right-hand end of the word it belongs to, and the words themselves are
/// laid out by Flutter's own bidi algorithm with the correct base direction,
/// which is what puts a line's trailing punctuation on the correct side.
class _ReadThisWay extends StatelessWidget {
  const _ReadThisWay({required this.language, required this.child});

  final String? language;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!readsRightToLeft(language)) return child;
    return Directionality(textDirection: TextDirection.rtl, child: child);
  }
}

class MusicianChordLyricLine extends StatelessWidget {
  const MusicianChordLyricLine({
    required this.line,
    required this.transpose,
    this.capo = 0,
    this.numbers = NumberReading.letters,
    this.musicalKey,
    required this.fontScale,
    required this.showChords,
    this.editable = false,
    this.liveMode = false,
    this.active = false,
    this.elapsedMs,
    this.melody,
    this.spelling,
    this.selectedChordStartMs,
    this.onEditChord,
    this.onAddChord,
    this.onLoopChange,
    super.key,
  });

  final MusicianSheetLine line;

  /// How far this person has moved the song, instrument's part included.
  /// What the *voice* reads: the note names under the words are this, and
  /// the chords are this less [capo].
  final int transpose;

  /// Which fret the capo is on, which moves the chords under the hand and
  /// leaves the singing where it was. A guitarist who capos up four does not
  /// sing four semitones lower, so the notes under the words must not move
  /// with the shapes (Every Musician, Same Song, 17 September 2026).
  final int capo;

  /// Whether the chords are drawn as letters, Nashville numbers or Roman
  /// numerals. Numbers are counted from [musicalKey] and do not move with
  /// [transpose] at all -- see [chordAsRead].
  final NumberReading numbers;

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
  /// above, and in the same key as them: the names move with [transpose].
  /// Only ever set on the active line in Perform: a page of notes under
  /// every word is a score, and this is a sheet.
  final Melody? melody;

  /// The language this person reads the sung notes in, when it is not
  /// letters — do-re-mi, fixed do, sargam or jianpu (see MelodySpelling).
  ///
  /// It is also what turns the row on away from Perform. A page of notes
  /// under every word is a score and the sheet deliberately is not one, but
  /// somebody who has chosen sargam has asked for exactly that page: it is
  /// off until they do, and it is theirs alone (Every Musician, Same Song,
  /// 17 September 2026).
  final MelodySpelling? spelling;

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

  /// A chord held down, for the one change a beginner is stuck on. Null
  /// where there is nowhere for the song to be played from, which leaves the
  /// long press doing nothing rather than offering a loop nothing can run.
  final MusicianChordHold? onLoopChange;

  @override
  Widget build(BuildContext context) {
    // The pieces a chord can sit over: words, or characters in a script that
    // does not put spaces between them (0163). One call, so the sheet, the
    // printed chart and the ChordPro file cannot disagree about which piece
    // a chord belongs to.
    final words = line.units;
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
    // In Perform, the line being sung and no other. On the sheet, only once
    // somebody has asked for the notes by choosing a language to read them
    // in -- see [spelling].
    final notes = (liveMode && active) || (!liveMode && spelling != null)
        ? notesForWords(
            melody,
            line.wordStartsMs,
            line.endMs,
            words.length,
            transpose: transpose,
            key: musicalKey,
            spelling: spelling,
          )
        : const <String?>[];
    return _ReadThisWay(
      language: line.language,
      child: Padding(
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
              transpose: transpose - capo,
              numbers: numbers,
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
              onLoopChange: onLoopChange,
            ),
        ],
      ),
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
      // music, and it lines up with the chords above the words. `end` rather
      // than `right`, so on a song read from the right the gap is on the
      // side the first word is actually on.
      padding: EdgeInsetsDirectional.only(bottom: liveMode ? 2 : 1, end: 2),
      child: Text(
        '$number',
        // A bar number is counted the one way everywhere, like the chord
        // names it sits beside.
        textDirection: TextDirection.ltr,
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
    this.numbers = NumberReading.letters,
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
    this.onLoopChange,
    this.note,
    this.showNotes = false,
    super.key,
  });

  final String word;
  final MusicianSheetLine line;
  final ChordCue? chord;
  final int wordIndex;

  /// What the chords are written in: the person's key, their instrument's
  /// part and their capo, already added up by the line.
  final int transpose;
  final NumberReading numbers;
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

  /// See MusicianChordLyricLine.onLoopChange.
  final MusicianChordHold? onLoopChange;

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
    // this the sheet reads "C:maj"), in the key being played -- or as the
    // number it is of the song's key, for somebody reading it that way.
    final chordText = chord == null
        ? ''
        : chordAsRead(
            chord!.chord,
            transpose: transpose,
            key: musicalKey,
            numbers: numbers,
          );
    // The same chord in letters, for the reference sheet a tap opens. A
    // number has no shape and no notes in it, so asking "what is a 4" would
    // open an empty sheet -- the question is always about the chord the
    // number stands for.
    final chordInLetters = chord == null
        ? ''
        : chordAsPlayed(chord!.chord, transpose: transpose, key: musicalKey);
    // Held down, a chord offers the change it is, on repeat and slowed. It is
    // deliberately the one thing a chord does in live mode: a tap there would
    // be a modal over the words while somebody is playing, and this is a
    // gesture nobody makes by accident and nobody makes while their hands are
    // busy (Every Musician, Same Song, 17 September 2026).
    final held = chord == null || editable || onLoopChange == null
        ? null
        : () => onLoopChange!(chord!);
    // A chord that answers when tapped is worth nothing if nobody taps it. On
    // paper a chord is just ink, so it needs to look like it holds something:
    // a pale tint behind it and a dotted underline — the oldest "there is
    // more here" mark there is — which together cost almost no ink but change
    // what the eye reads it as. Not in live mode, where a tap does nothing
    // and a tint that says "tap me" would be a lie; the long press is
    // deliberately unmarked there, the way the chart's own long press is (see
    // chord_chart_view.dart).
    final chordStyle = TextStyle(
      color: liveMode
          ? AppColors.gold
          : chord != null && chord!.isManual
              ? const Color(0xFF0D655F)
              : const Color(0xFF197A74),
      fontFamily: 'monospace',
      fontSize: (liveMode ? 10.8 : 11.2) * fontScale,
      height: 1,
      fontWeight: FontWeight.w900,
      decoration: liveMode ? null : TextDecoration.underline,
      decorationStyle: TextDecorationStyle.dotted,
      decorationColor:
          const Color(0xFF197A74).withValues(alpha: editable ? 0.9 : 0.55),
    );
    final chordBody = chord == null
        ? const SizedBox.shrink()
        : Container(
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
              // A chord name is Latin music notation and not lyric text. On a
              // song read from the right it would otherwise be handed to the
              // bidi algorithm with a right-to-left base, which moves a
              // trailing or leading symbol to the other end: A♯ drew as ♯A,
              // B♭ as ♭B, F# as #F, and the number reading ♭7 as 7♭. The
              // position of the name is still directional — it sits over the
              // start of its word, whichever side that is — but the name
              // itself reads the one way it is ever written (review, 18
              // September 2026).
              textDirection: TextDirection.ltr,
              style: chordStyle,
            ),
          );
    final chordKey = chord?.id == null ? null : Key('edit_chord_${chord!.id}');
    final chordWidget = chord == null
        ? const SizedBox.shrink()
        : liveMode
            // Nothing but the hold in live mode, and a bare gesture for it.
            // An InkWell counts itself enabled the moment it is given a long
            // press, so it takes the tap as well and wins it from the screen
            // underneath — which is the screen's own "bring the controls
            // back" tap, and chords sit over most of the words. So the hold
            // goes on a recognizer that only listens for a hold, and taps
            // carry on through to Perform. Translucent, because what is
            // being held is the ink, not the row.
            ? GestureDetector(
                key: chordKey,
                behavior: HitTestBehavior.translucent,
                onLongPress: held,
                child: chordBody,
              )
            // A chord on the sheet answers a question before it asks one:
            // most of the time somebody tapping A♯ wants to know how to play
            // A♯, not to correct it. Correcting is the deliberate mode with
            // its own banner, and it keeps the tap while it is on.
            : InkWell(
                key: chordKey,
                onTap: editable
                    ? _activate
                    : () => showChordReference(context, chordInLetters),
                onLongPress: held,
                borderRadius: BorderRadius.circular(5),
                child: chordBody,
              );

    // The row over the words is as tall as the chord names actually are.
    //
    // Every Musician, Same Song, 17 September 2026: the phone's own text size
    // is honoured, never clamped. 16.5 and 16 are the height of a chord name
    // at the author's own text size and at this person's own sheet zoom —
    // but the reader's phone scales the name on top of both, and this box did
    // not follow. At twice normal the chord was drawn down over the word it
    // belongs to instead of above it, and a chord sheet whose chords sit on
    // the wrong syllable is worse than one with no chords at all.
    //
    // Measured with the style it is drawn in rather than multiplied by a
    // guess: the line height belongs to the font, so a multiplier would be
    // wrong the day the theme changes family and wrong silently. The two old
    // numbers stay as a floor, so nothing moves for anybody who has not
    // turned their text up. `+ 2` is the chip's own vertical padding.
    //
    // widthFactor is intentional. Without it, Align consumes the complete
    // Wrap width and turns every lyric word into its own visual row.
    //
    // AlignmentDirectional, not Alignment: a chord goes over the start of
    // the word it changes on, and on a song read from the right the start of
    // the word is its right-hand end. In every left-to-right song this
    // resolves to bottomLeft, which is what it always was.
    final chordLabel = SizedBox(
      height: showChords
          ? math.max(
              (liveMode ? 16.5 : 16) * fontScale,
              linesOfTextHigh(context, chordStyle) + 2,
            )
          : 0,
      child: showChords
          ? Align(
              alignment: AlignmentDirectional.bottomStart,
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
          if (showNotes) _notes(context),
        ],
      ),
    );
  }

  /// The note this word is sung on, in a row as tall as the names are.
  ///
  /// Every Musician, Same Song, 17 September 2026: the phone's own text size
  /// is honoured, never clamped. 12 was the height of one of these names at
  /// the author's text size, so at twice normal the row of sung notes ran
  /// down into whatever came after it. The old number stays as a floor, and
  /// the height is measured with the style the names are drawn in — a word
  /// the tracker heard nothing in still gets a blank of the same height, not
  /// a dash, so the words along a line stay level.
  Widget _notes(BuildContext context) {
    final style = TextStyle(
      // On paper the row is ink, not a dimmed white: the sheet is a cream
      // page, and the live row's white at 42 % was invisible on it.
      color: moment == WordMoment.now
          ? AppColors.gold
          : liveMode
              ? Colors.white.withValues(alpha: 0.42)
              : const Color(0xFF7A6C5A),
      fontFamily: 'monospace',
      fontSize: 9.4 * fontScale,
      height: 1,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.3,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: SizedBox(
        height: math.max(12 * fontScale, linesOfTextHigh(context, style)),
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 90),
          style: style,
          // A note name is notation too, for the same reason the chord above
          // it is: B♭4 must not draw as ♭B4, and ♭7 in jianpu must not draw
          // as 7♭.
          child: Text(note ?? '', textDirection: TextDirection.ltr),
        ),
      ),
    );
  }
}
