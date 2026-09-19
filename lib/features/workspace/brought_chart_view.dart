import 'package:flutter/material.dart';

import '../../domain/song_analysis_models.dart' show ChordCue;
import '../../services/brought_chart.dart';
import '../../services/horn_reading.dart';
import '../../services/music_reference.dart' show keyRootPitch;
import '../../services/number_reading.dart';
import 'music_reference_sheets.dart';
import 'musician_sheet_line.dart';
import 'musician_sheet_logic.dart';

/// A chart somebody brought, on the page.
///
/// The same page the song sheet is drawn on and the same line widget, which
/// is the whole point: a chord here is a chord name, so transposing it, capoing
/// it, reading it as a number, reading it for a horn and tapping it for its
/// shape all work already (Every Musician, Same Song, 17 September 2026).
/// Nothing about a brought chart needed any of that written twice.
///
/// What it does that the song sheet does not, and the reason it is a widget
/// of its own: a row of chords with no words under it — an intro, a
/// turnaround — a block of tablature kept character for character in a
/// monospace block rather than taken apart, a line the reader did not
/// understand kept exactly as it arrived, and a line with more chords than it
/// has words to put them over (see [_wordsLine]).
class BroughtChartView extends StatelessWidget {
  const BroughtChartView({
    required this.chart,
    required this.title,
    required this.transpose,
    required this.fontScale,
    this.capo = 0,
    this.reading = HornReading.concert,
    this.numbers = NumberReading.letters,
    this.musicalKey,
    this.language,
    super.key,
  });

  final BroughtChart chart;

  /// The song's name. The chart's own `{title}` is shown under it when the
  /// two differ, because a chart that came from somewhere else usually
  /// spells the song a little differently and that is worth seeing.
  final String title;

  /// The reader's own zoom on the page, on top of their phone's text size.
  final double fontScale;

  /// How far this person has moved the song, their instrument's part
  /// included. The same arithmetic the song sheet does.
  final int transpose;

  /// Which fret their capo is on, which moves the shapes and not the singing.
  final int capo;
  final HornReading reading;
  final NumberReading numbers;

  /// The key the chords are counted from when somebody reads them as numbers
  /// — what the chart says it is in, or nothing.
  final String? musicalKey;

  /// What the room said the song is sung in (0163), so a chart in Arabic or
  /// Chinese is laid out the way the sheet lays those songs out.
  final String? language;

  @override
  Widget build(BuildContext context) {
    final sung = transpose + reading.semitones;
    final capoHere = reading == HornReading.concert ? capo : 0;
    final written = sung - capoHere;
    return Container(
      key: const Key('brought_chart'),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFAEC),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0x1A2A231B)),
        boxShadow: const <BoxShadow>[
          BoxShadow(color: Color(0x22000000), blurRadius: 28, offset: Offset(0, 12)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 14),
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
                  // What the chart says about itself, in the chart's own
                  // words. A Wrap, so the line goes onto a second one rather
                  // than off the page at a large text size.
                  if (_facts.isNotEmpty)
                    Wrap(
                      spacing: 10,
                      runSpacing: 3,
                      children: <Widget>[
                        for (final fact in _facts)
                          Text(
                            fact,
                            style: TextStyle(
                              color: const Color(0xFF7A6C5A),
                              fontSize: 10.5 * fontScale,
                              fontWeight: FontWeight.w700,
                              height: 1.35,
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0x142A231B)),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final line in chart.lines)
                    switch (line.kind) {
                      ChartLineKind.heading => MusicianSectionLine(
                          line: MusicianSheetLine(
                            contributionId: null,
                            body: line.text,
                            section: true,
                            startMs: 0,
                            endMs: 0,
                            chords: const <ChordCue>[],
                            approximateTiming: false,
                            language: language,
                          ),
                          fontScale: fontScale,
                        ),
                      ChartLineKind.words => _wordsLine(line, sung, capoHere),
                      ChartLineKind.chords => _ChordRow(
                          chords: line.chords,
                          transpose: written,
                          numbers: numbers,
                          musicalKey: musicalKey,
                          fontScale: fontScale,
                        ),
                      ChartLineKind.tab =>
                        _KeptVerbatim(text: line.text, fontScale: fontScale),
                      ChartLineKind.text =>
                        _KeptVerbatim(text: line.text, fontScale: fontScale),
                      ChartLineKind.blank => SizedBox(height: 10 * fontScale),
                    },
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Words with the chords over them — or, when they will not all fit, the
  /// chords on a row of their own above the words.
  ///
  /// The sheet holds one chord over each piece of a line, which is what every
  /// chord sheet in this app does and is right for almost every line ever
  /// written. It is wrong for the short ones: "C  G" over "Oh" is two chords
  /// and one word, and the sheet would draw the second and quietly lose the
  /// first. Losing a chord is the one thing a chart must never do — the
  /// chords are the whole reason somebody brought it — so a crowded line is
  /// written the way a chart writes one, with the changes on their own row
  /// above the words. The line as stored keeps every chord where it was
  /// written either way.
  Widget _wordsLine(BroughtChartLine line, int sung, int capoHere) {
    final sheetLine = broughtLineAsSheetLine(line, language: language);
    final placed = chordPlacementsForLine(
      wordCount: sheetLine.units.length,
      lineStartMs: sheetLine.startMs,
      lineEndMs: sheetLine.endMs,
      chords: sheetLine.chords,
      wordStartsMs: sheetLine.wordStartsMs,
    );
    if (placed.length >= _chordsWanted(sheetLine.chords)) {
      return MusicianChordLyricLine(
        line: sheetLine,
        transpose: sung,
        capo: capoHere,
        numbers: numbers,
        musicalKey: musicalKey,
        fontScale: fontScale,
        showChords: true,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _ChordRow(
          chords: line.chords,
          transpose: sung - capoHere,
          numbers: numbers,
          musicalKey: musicalKey,
          fontScale: fontScale,
        ),
        MusicianChordLyricLine(
          line: MusicianSheetLine(
            contributionId: null,
            body: line.text,
            section: false,
            startMs: sheetLine.startMs,
            endMs: sheetLine.endMs,
            chords: const <ChordCue>[],
            approximateTiming: false,
            language: language,
          ),
          transpose: sung,
          capo: capoHere,
          numbers: numbers,
          musicalKey: musicalKey,
          fontScale: fontScale,
          showChords: false,
        ),
      ],
    );
  }

  /// How many chords this line actually asks the sheet to draw.
  ///
  /// The same run-of-duplicates rule [chordPlacementsForLine] applies before
  /// it places anything: the same chord written twice over one piece of a
  /// line is one chord, not two, and counting it as two would send a line
  /// that fits perfectly well down the crowded path.
  static int _chordsWanted(List<ChordCue> chords) {
    var count = 0;
    ChordCue? last;
    for (final chord in chords) {
      if (last == null ||
          last.chord != chord.chord ||
          last.startMs != chord.startMs) {
        count += 1;
        last = chord;
      }
    }
    return count;
  }

  /// The line under the title: what the chart called the song, who it says
  /// wrote it, and the key, capo and tuning it states. Only what it actually
  /// said — nothing here is worked out.
  List<String> get _facts => <String>[
        if (chart.title != null && chart.title!.trim() != title.trim())
          chart.title!,
        if (chart.artist != null) chart.artist!,
        if (chart.key != null) 'Key of ${chart.key}',
        if (chart.capo != null) 'Capo ${chart.capo}',
        if (chart.tuning != null) 'Tuning ${chart.tuning}',
      ];
}

/// A row of chords with no words under it.
///
/// An intro, a turnaround, a solo. Drawn in the same ink as the chords over
/// the words and tappable for the same reason: this is the one place on the
/// page where the chord *is* the line.
class _ChordRow extends StatelessWidget {
  const _ChordRow({
    required this.chords,
    required this.transpose,
    required this.numbers,
    required this.musicalKey,
    required this.fontScale,
  });

  final List<BroughtChord> chords;
  final int transpose;
  final NumberReading numbers;
  final String? musicalKey;
  final double fontScale;

  @override
  Widget build(BuildContext context) {
    final style = chordNameStyle(
      liveMode: false,
      fontScale: fontScale,
      editable: false,
      manual: true,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Wrap(
        spacing: 12,
        runSpacing: 7,
        children: <Widget>[
          for (final chord in chords)
            InkWell(
              onTap: () => showChordReference(
                context,
                chordAsPlayed(chord.chord,
                    transpose: transpose, key: musicalKey),
              ),
              borderRadius: BorderRadius.circular(5),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                decoration: BoxDecoration(
                  color: const Color(0xFF197A74).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  chordAsRead(
                    chord.chord,
                    transpose: transpose,
                    key: musicalKey,
                    numbers: numbers,
                  ),
                  // A chord name is Latin music notation and reads the one
                  // way it is ever written, whichever way the song runs.
                  textDirection: TextDirection.ltr,
                  style: style,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A line kept exactly as it arrived.
///
/// Tablature is six strings and a wall of dashes, and it only means anything
/// in a font where every character is the same width — so it is drawn in one,
/// and it scrolls sideways rather than wrapping, because a wrapped tab is a
/// different tab. A directive this app did not recognise is drawn here too:
/// it was kept rather than thrown away, and this is what kept looks like.
class _KeptVerbatim extends StatelessWidget {
  const _KeptVerbatim({required this.text, required this.fontScale});

  final String text;
  final double fontScale;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Text(
        text,
        softWrap: false,
        textDirection: TextDirection.ltr,
        style: TextStyle(
          color: const Color(0xFF6D6254),
          fontFamily: 'monospace',
          fontSize: 11 * fontScale,
          height: 1.35,
        ),
      ),
    );
  }
}

/// The key a brought chart is read in.
///
/// What the chart says, when it says anything. Numbers, the capo chart and
/// the scale are all counted from a key, and a chart that does not name one
/// simply has none — nothing here guesses it from the chords, because a
/// guessed key silently renumbers somebody's whole page (Every Musician,
/// Same Song, 17 September 2026: nothing is inferred).
String? chartKey(BroughtChart chart) {
  final said = chart.key?.trim();
  if (said == null || said.isEmpty) return null;
  // Read through the app's own key grammar, which takes "G", "Am" and
  // "A minor" alike. A chart that wrote a sentence there has no key as far as
  // this is concerned, which is better than counting numbers from a word.
  return keyRootPitch(said) == null ? null : said;
}
