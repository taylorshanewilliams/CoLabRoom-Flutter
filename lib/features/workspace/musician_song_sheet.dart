import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/music_reference_sheets.dart';
import 'package:colabroom/features/workspace/musician_sheet_line.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:colabroom/features/workspace/song_language_sheet.dart';
import 'package:colabroom/services/horn_reading.dart';
import 'package:colabroom/services/song_language.dart';
import 'package:colabroom/services/melody_reading.dart';
import 'package:colabroom/services/number_reading.dart';
import 'package:flutter/material.dart';

/// A "physical paper" chord+lyric sheet — chords sit directly above the word
/// they land on. Deliberately takes already-built [lines] rather than a
/// SongProject/SongAnalysisBundle: the per-project Song Sheet and The
/// Studio's pre-project drafts both need this exact rendering, but only one
/// of them has a project to wrap the data in (see transcriptSheetLines in
/// musician_sheet_logic.dart, which both callers build [lines] from).
class MusicianSongSheet extends StatelessWidget {
  const MusicianSongSheet({
    required this.title,
    required this.lines,
    required this.musicalKey,
    required this.transpose,
    required this.fontScale,
    required this.showChords,
    this.reading = HornReading.concert,
    this.onReading,
    this.numbers = NumberReading.letters,
    this.onNumbers,
    this.capo = 0,
    this.onCapo,
    this.melody,
    this.melodyReading = MelodyReading.letters,
    this.onMelodyReading,
    this.sa,
    this.onSa,
    this.spelling,
    this.onKey,
    this.language,
    this.onLanguage,
    this.languagesYouSingIn = const <String>[],
    this.keyOverridden = false,
    this.editableChords = false,
    this.selectedChordStartMs,
    this.onEditChord,
    this.onAddChord,
    this.onLoopChange,
    this.chords = const <String>[],
    super.key,
  });

  final String title;
  final List<MusicianSheetLine> lines;

  /// Every chord the song reaches for, as the song stores them, so the capo
  /// rows on the key sheet can be about this song and not only about its
  /// key. Empty on a sheet whose caller has none — a draft in the Studio —
  /// which leaves those rows the chart they always were.
  final List<String> chords;
  final String? musicalKey;
  final int transpose;

  /// The instrument this person reads the song for, stacked on top of
  /// [transpose]: a B♭ player in a band that took the song down two still
  /// needs it down two. Personal, and never shared with the room.
  final HornReading reading;

  /// Where a new choice goes. Null on a sheet that has nowhere to keep one,
  /// which leaves the key badge the chart it always was.
  final ValueChanged<HornReading>? onReading;

  /// Whether this person reads the chords as letters, numbers or numerals.
  /// Personal, like the rest of them, and the only one that does not move
  /// when [transpose] does.
  final NumberReading numbers;
  final ValueChanged<NumberReading>? onNumbers;

  /// Which fret the capo is on, which moves the chords under the hand and
  /// nothing the band hears. Personal, and only ever in play in concert
  /// pitch — see the capo rows in the key sheet.
  final int capo;
  final ValueChanged<int>? onCapo;

  /// The tune the recording sang, and how this person reads it.
  ///
  /// [spelling] is the prepared answer — the language, the 1 and the middle
  /// octave, worked out once by the caller — and it is also the switch: null
  /// means the notes stay off the page, which is what the sheet has always
  /// done. [melody] is the tune itself, and the rest is for the picker on the
  /// key badge (Every Musician, Same Song, 17 September 2026).
  final Melody? melody;
  final MelodyReading melodyReading;
  final ValueChanged<MelodyReading>? onMelodyReading;
  final int? sa;
  final ValueChanged<int?>? onSa;
  final MelodySpelling? spelling;

  /// Whether there is a tune to offer a language for: one worth reading, and
  /// at least one line whose words are timed. The row is laid out word by
  /// word, so on a song whose transcription came back as text with no timings
  /// the chips would name a row that is drawn nowhere (review, 18 September
  /// 2026).
  bool get _hasReadableTune =>
      (melody?.worthReading ?? false) &&
      lines.any((line) => line.wordStartsMs != null);

  /// Where the 1 is, which is the one thing on this badge that belongs to the
  /// room rather than to this device. Null on a sheet whose caller cannot
  /// write it, which leaves the key sheet a reference.
  final SayTheKey? onKey;

  /// What the room said this song is sung in (0163), as a BCP-47 tag, or
  /// null because nobody has said.
  ///
  /// The lines carry it themselves and lay themselves out by it; this is
  /// only for the line under the title that says what it is and opens the
  /// question.
  final String? language;

  /// Where a new answer goes. Null for somebody the room only lets look,
  /// and for a sheet with no song behind it — the Studio's drafts — which
  /// leaves the line a statement or leaves it off the page entirely.
  final SayTheLanguage? onLanguage;

  /// What the person reading has said they sing in (0156), offered first in
  /// the language list. Never applied on its own: a profile does not know
  /// what any one song is.
  final List<String> languagesYouSingIn;

  /// Whether [musicalKey] is the band's answer rather than the analysis's, so
  /// the sheet can offer to hand it back.
  final bool keyOverridden;
  final double fontScale;
  final bool showChords;
  final bool editableChords;

  /// Where the held cue starts, passed straight through to the line that
  /// owns it. Null on a device with no keyboard, which is most of them.
  final int? selectedChordStartMs;
  final MusicianChordTap? onEditChord;
  final MusicianWordTap? onAddChord;

  /// A chord held down, for the one change somebody is stuck on. Null on a
  /// sheet with nowhere to play the song from.
  final MusicianChordHold? onLoopChange;

  @override
  Widget build(BuildContext context) {
    final key = musicalKey;
    // What the voice on this sheet reads: the person's own key, then their
    // instrument's transposition on top of it. A capo is deliberately not in
    // here — it moves the hand, not the singer — so it is handed to the lines
    // separately and only the chords come down by it.
    final sung = transpose + reading.semitones;
    final capoHere = reading == HornReading.concert ? capo : 0;
    // What the chords and the key badge are written in.
    final written = sung - capoHere;
    final approximate = lines.any((line) => line.approximateTiming);
    return Container(
      key: const Key('musician_song_sheet'),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFAEC),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: editableChords
              ? const Color(0x66197A74)
              : const Color(0x1A2A231B),
          width: editableChords ? 1.4 : 1,
        ),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 28,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 15),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          title,
                          style: TextStyle(
                            color: const Color(0xFF241E18),
                            fontSize: 23 * fontScale,
                            height: 1.08,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.55,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Row(
                          children: <Widget>[
                            Text(
                              'COLABROOM SONG SHEET',
                              style: TextStyle(
                                color: const Color(0xFF7A6C5A),
                                fontSize: 8.5 * fontScale,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.4,
                              ),
                            ),
                            if (editableChords) ...<Widget>[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0x16197A74),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Text(
                                  'EDITING CHORDS',
                                  style: TextStyle(
                                    color: Color(0xFF197A74),
                                    fontSize: 7.5,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0.8,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        _SungInLine(
                          language: language,
                          onLanguage: onLanguage,
                          youSingIn: languagesYouSingIn,
                          fontScale: fontScale,
                        ),
                      ],
                    ),
                  ),
                  if (key != null && key.trim().isNotEmpty)
                    // The badge is a tap target, not decoration: the key is
                    // the one fact on the sheet that answers a question the
                    // reader actually has — which notes, which chords, and
                    // where to put the capo.
                    GestureDetector(
                      key: const Key('song_sheet_key_badge'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => showKeyReference(
                        context,
                        keyAsPlayed(key, transpose),
                        reading: reading,
                        onReading: onReading,
                        numbers: numbers,
                        onNumbers: onNumbers,
                        capo: capo,
                        onCapo: onCapo,
                        melody: melodyReading,
                        onMelody: onMelodyReading,
                        sa: sa,
                        onSa: onSa,
                        hasTune: _hasReadableTune,
                        // The song's own chords, moved the way the key on
                        // this badge has been, so the capo the sheet offers
                        // is worked out in the key it is showing.
                        chords: <String>[
                          for (final chord in chords)
                            chordAsPlayed(chord,
                                transpose: transpose, key: key),
                        ],
                        songKey: key,
                        overridden: keyOverridden,
                        onKey: onKey,
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8F0E8),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          children: <Widget>[
                            Text(
                              reading == HornReading.concert
                                  ? 'KEY'
                                  : 'KEY FOR ${reading.label}',
                              style: const TextStyle(
                                color: Color(0xFF667263),
                                fontSize: 7.5,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1,
                              ),
                            ),
                            // Underlined like the chords, and for the same
                            // reason: a badge reads as a label, and nobody
                            // taps a label.
                            Text(
                              keyAsPlayed(key, written),
                              style: TextStyle(
                                color: const Color(0xFF244A37),
                                fontSize: 15,
                                fontWeight: FontWeight.w900,
                                decoration: TextDecoration.underline,
                                decorationStyle: TextDecorationStyle.dotted,
                                decorationColor: const Color(0xFF244A37)
                                    .withValues(alpha: 0.55),
                              ),
                            ),
                            // The band's key, never dropped: the written key
                            // is what this player reads, and the concert key
                            // is what they have to say out loud when they
                            // call the tune. A capo is the same story with a
                            // different cause — the shapes changed and the
                            // song did not.
                            if (reading != HornReading.concert)
                              Text(
                                'concert ${keyAsPlayed(key, transpose)}',
                                style: const TextStyle(
                                  color: Color(0xFF667263),
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              )
                            else if (capoHere > 0)
                              Text(
                                'capo $capoHere · sounds in '
                                '${keyAsPlayed(key, transpose)}',
                                style: const TextStyle(
                                  color: Color(0xFF667263),
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0x142A231B)),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
              child: lines.isEmpty
                  ? Text(
                      'Nothing to show yet — analyze a recording with either singing or a clear instrument track.',
                      style: TextStyle(
                        color: const Color(0xFF6D6254),
                        fontSize: 13 * fontScale,
                        height: 1.45,
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        for (final line in lines)
                          if (line.section)
                            MusicianSectionLine(
                              line: line,
                              fontScale: fontScale,
                            )
                          else
                            MusicianChordLyricLine(
                              line: line,
                              transpose: sung,
                              capo: capoHere,
                              numbers: numbers,
                              musicalKey: key,
                              fontScale: fontScale,
                              showChords: showChords,
                              editable: editableChords,
                              melody: melody,
                              spelling: spelling,
                              selectedChordStartMs: selectedChordStartMs,
                              onEditChord: onEditChord,
                              onAddChord: onAddChord,
                              onLoopChange: onLoopChange,
                            ),
                        if (approximate) ...<Widget>[
                          const SizedBox(height: 16),
                          const Divider(
                            height: 1,
                            color: Color(0x142A231B),
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            'Some chord positions use guided timing because the sung-word match was incomplete. You can still correct every chord and move it to the right word.',
                            style: TextStyle(
                              color: Color(0xFF8A7A66),
                              fontSize: 9.5,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the song is sung in, under its title (0163).
///
/// On the sheet rather than in a menu because this is where it shows: the
/// lines below it run the way it says, and somebody who can see that the
/// page is laid out wrong is looking straight at the control that fixes it.
///
/// Three states and no banner. Nobody who can answer has: one quiet line
/// asking. Answered: the answer, still tappable, because the first answer
/// is often the wrong one. Somebody who can only look: the answer if there
/// is one, and otherwise nothing at all — a question nobody can answer is
/// not worth the line it is written on.
class _SungInLine extends StatelessWidget {
  const _SungInLine({
    required this.language,
    required this.onLanguage,
    required this.youSingIn,
    required this.fontScale,
  });

  final String? language;
  final SayTheLanguage? onLanguage;
  final List<String> youSingIn;
  final double fontScale;

  @override
  Widget build(BuildContext context) {
    final said = language;
    final write = onLanguage;
    if (said == null && write == null) return const SizedBox.shrink();
    final label = said == null
        ? 'Say what it is sung in'
        : 'Sung in ${languageNamed(said)}';
    final text = Text(
      label,
      style: TextStyle(
        color: const Color(0xFF7A6C5A),
        fontSize: 8.5 * fontScale,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.6,
        // Underlined like the key badge and the chords, and for the same
        // reason: nobody taps a label.
        decoration: write == null ? null : TextDecoration.underline,
        decorationStyle: TextDecorationStyle.dotted,
        decorationColor: const Color(0xFF7A6C5A).withValues(alpha: 0.6),
      ),
    );
    if (write == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: text,
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: InkWell(
          key: const Key('song_sheet_sung_in'),
          borderRadius: BorderRadius.circular(6),
          onTap: () => showSongLanguageSheet(
            context,
            language: said,
            onLanguage: write,
            suggested: youSingIn,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 1),
            child: text,
          ),
        ),
      ),
    );
  }
}
