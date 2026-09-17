import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:colabroom/services/project_export_service.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

/// Getting the chords off the phone.
///
/// Every Musician, Same Song, 17 September 2026: the app already draws the
/// one page a musician wants — the chords over the words — and then had no
/// way to hand it to anybody. Print was the lyrics on their own, which is
/// the half of the page a player does not need. A fill-in guitarist wants a
/// chart on a stand; a worship team runs Planning Center or OnSong and reads
/// ChordPro; a teacher wants the same page for six students.
///
/// Both exports are the song as the person is reading it right now — their
/// own transpose, their own key (see [chordAsPlayed] and [keyAsPlayed]).
/// A chart handed out in a key nobody in the room is playing is a chart
/// nobody can use. Nothing here is written back to the room: how you read a
/// song stays yours.
///
/// There is no ChordPro *import* yet, and that is a limit of where chords
/// live rather than a choice. A chord is a [ChordCue] with a start and an end
/// in milliseconds against an analyzed recording; a ChordPro file has no
/// timing in it at all, so importing one would mean inventing the timings
/// that everything else on the sheet is positioned by. That wants a home for
/// typed chords on a song with no recording, which does not exist yet.
abstract final class ChordSheetExport {
  /// One printed line of a chart: the row of chords, and the row of words it
  /// sits over.
  ///
  /// Two plain strings on one monospaced column grid, rather than a laid-out
  /// widget. A chart is the one page in this app where the horizontal
  /// position of a character carries meaning — a chord has to sit over the
  /// syllable it changes on, or it is worse than no chord at all — and
  /// columns are the only way to say that exactly, on paper and in a test
  /// alike.
  ///
  /// Folded to what a built-in PDF font can draw here rather than at the
  /// moment it is drawn (see [ProjectExportService.printable]): an ellipsis
  /// becoming three dots changes the width of the word under a chord, and a
  /// chord that moved after the columns were counted is over the wrong word.
  static ChartTextLine textLine(
    MusicianSheetLine line, {
    required int transpose,
    String? musicalKey,
    bool wordsTravel = true,
  }) {
    if (line.section) {
      return ChartTextLine(
        chords: '',
        words: ProjectExportService.printable(line.body.trim()),
        section: true,
      );
    }
    final words = ProjectExportService.printable(line.body)
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
    String named(ChordCue cue) => ProjectExportService.printable(
          plainChordName(
            chordAsPlayed(cue.chord, transpose: transpose, key: musicalKey),
          ),
        );

    if (!wordsTravel) {
      // Somebody else's song: the chords go, the words stay. Written as a
      // plain run rather than spaced over the words they belong to, because
      // spacing shaped by the words is still a trace of the words.
      final only = <String>[
        for (var index = 0; index < words.length; index += 1)
          if (placements[index] != null) named(placements[index]!),
      ].where((name) => name.isNotEmpty);
      return ChartTextLine(chords: only.join('  '), words: '');
    }

    final chordRow = StringBuffer();
    final wordRow = StringBuffer();
    for (var index = 0; index < words.length; index += 1) {
      if (index > 0) wordRow.write(' ');
      final cue = placements[index];
      final name = cue == null ? '' : named(cue);
      if (name.isNotEmpty) {
        // The chord starts over its word — unless the chord before it would
        // run into it, and then the word moves right instead. Two chords
        // touching read as a third chord that is neither of them.
        var at = wordRow.length;
        final earliest = chordRow.isEmpty ? 0 : chordRow.length + 1;
        if (earliest > at) {
          wordRow.write(' ' * (earliest - at));
          at = earliest;
        }
        chordRow.write(' ' * (at - chordRow.length));
        chordRow.write(name);
      }
      wordRow.write(words[index]);
    }
    return ChartTextLine(
      chords: chordRow.toString().trimRight(),
      words: wordRow.toString().trimRight(),
    );
  }

  /// The sheet's lines with the recording's section names folded in.
  ///
  /// The Song Sheet builds its lines from what was sung, which has no idea
  /// where a chorus begins; the analysis does, in `structureSections`. A
  /// chart without them is a wall of lines, and the shape of the song is
  /// most of what a chart is read for.
  ///
  /// Left alone when the lines already carry section rows of their own — a
  /// song whose words were typed into the room has them — so no heading ever
  /// lands twice. Only the last section due before a line is written, so
  /// every heading has something underneath it: "Intro" and "Verse" printed
  /// back to back name a part the page does not show.
  static List<MusicianSheetLine> withSectionNames(
    List<MusicianSheetLine> lines,
    List<StructureSection> sections,
  ) {
    if (lines.isEmpty || sections.isEmpty) return lines;
    if (lines.any((line) => line.section)) return lines;
    final ordered = List<StructureSection>.of(sections)
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
    final out = <MusicianSheetLine>[];
    var next = 0;
    for (final line in lines) {
      StructureSection? due;
      while (next < ordered.length &&
          ordered[next].startMs <= line.startMs + _sectionPickupMs) {
        due = ordered[next];
        next += 1;
      }
      if (due != null) {
        out.add(
          MusicianSheetLine(
            contributionId: null,
            body: due.displayLabel,
            section: true,
            startMs: due.startMs,
            endMs: due.endMs,
            chords: const <ChordCue>[],
            approximateTiming: false,
          ),
        );
      }
      out.add(line);
    }
    return List<MusicianSheetLine>.unmodifiable(out);
  }

  /// How far ahead of a section a singer may come in and still be part of it.
  ///
  /// A chorus starts on a downbeat and the vocal that opens it usually starts
  /// a beat or two before, on a pickup. Without this the heading lands one
  /// line late — printed underneath the first words of its own chorus.
  static const int _sectionPickupMs = 900;

  /// The song as ChordPro: `{title}`, `{key}`, `{tempo}`, section directives,
  /// and `[C]`inline chords in the words.
  ///
  /// The format worship teams already run on. Planning Center and OnSong both
  /// read it, which makes this the cheapest way for a band that does not use
  /// this app to still play what a band that does has worked out.
  static String chordPro({
    required SongProject project,
    required List<MusicianSheetLine> lines,
    required int transpose,
    String? musicalKey,
    double? bpm,
  }) {
    final wordsTravel = ProjectExportService.wordsTravel(project);
    final out = StringBuffer('{title: ${_directiveSafe(project.title)}}\n');
    if (musicalKey != null && musicalKey.trim().isNotEmpty) {
      out.writeln(
        '{key: ${_directiveSafe(keyAsPlayed(musicalKey.trim(), transpose))}}',
      );
    }
    if (bpm != null && bpm > 0) out.writeln('{tempo: ${bpm.round()}}');
    if (!wordsTravel) {
      out.writeln('{comment: ${_directiveSafe(ProjectExportService.wordsStayHome)}}');
    }

    var inChorus = false;
    var blankDue = true;
    for (final line in lines) {
      if (line.section) {
        if (inChorus) {
          out.writeln('{end_of_chorus}');
          inChorus = false;
        }
        final label = _directiveSafe(line.body.trim());
        if (label.isEmpty) continue;
        out.writeln();
        // A chorus is the one part of a song ChordPro has a shape for, and
        // the one a reader most wants set apart on the page. Everything else
        // is a comment, which every reader of the format prints as a heading.
        if (label.toLowerCase().contains('chorus')) {
          out.writeln('{start_of_chorus}');
          inChorus = true;
        } else {
          out.writeln('{comment: $label}');
        }
        blankDue = false;
        continue;
      }
      if (blankDue) {
        out.writeln();
        blankDue = false;
      }
      final written = _chordProLine(
        line,
        transpose: transpose,
        musicalKey: musicalKey,
        wordsTravel: wordsTravel,
      );
      if (written.isNotEmpty) out.writeln(written);
    }
    if (inChorus) out.writeln('{end_of_chorus}');
    return out.toString();
  }

  static String _chordProLine(
    MusicianSheetLine line, {
    required int transpose,
    String? musicalKey,
    required bool wordsTravel,
  }) {
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
    String named(ChordCue cue) => plainChordName(
          chordAsPlayed(cue.chord, transpose: transpose, key: musicalKey),
        );

    final out = StringBuffer();
    for (var index = 0; index < words.length; index += 1) {
      final cue = placements[index];
      final name = cue == null ? '' : named(cue);
      if (!wordsTravel) {
        if (name.isEmpty) continue;
        if (out.isNotEmpty) out.write(' ');
        out.write('[$name]');
        continue;
      }
      if (index > 0) out.write(' ');
      if (name.isNotEmpty) out.write('[$name]');
      out.write(words[index]);
    }
    return out.toString().trimRight();
  }

  /// The chart as a PDF: chords over the words, with the title, the key, the
  /// tempo and the section names at the top of it.
  ///
  /// Courier, deliberately. It is one of the fonts every PDF reader already
  /// has, so this needs no font asset — and it is the only way a chord lands
  /// over the right syllable, because in a monospaced face a column is a
  /// column.
  static pw.Document chartDocument({
    required SongProject project,
    required List<MusicianSheetLine> lines,
    required int transpose,
    String? musicalKey,
    double? bpm,
  }) {
    final wordsTravel = ProjectExportService.wordsTravel(project);
    final chart = <ChartTextLine>[
      for (final line in lines)
        ...wrap(
          textLine(
            line,
            transpose: transpose,
            musicalKey: musicalKey,
            wordsTravel: wordsTravel,
          ),
        ),
    ].where((line) => !line.isEmpty).toList(growable: false);

    final facts = <String>[
      if (musicalKey != null && musicalKey.trim().isNotEmpty)
        'Key of ${keyAsPlayed(musicalKey.trim(), transpose)}',
      if (bpm != null && bpm > 0) '${bpm.round()} bpm',
    ];

    final mono = pw.Font.courier();
    final monoBold = pw.Font.courierBold();
    final document = pw.Document();
    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.all(_margin),
        build: (_) => <pw.Widget>[
          pw.Text(
            ProjectExportService.printable(project.title),
            style: pw.TextStyle(fontSize: 25, fontWeight: pw.FontWeight.bold),
          ),
          if (facts.isNotEmpty) ...<pw.Widget>[
            pw.SizedBox(height: 6),
            pw.Text(ProjectExportService.printable(facts.join('   ·   ')),
                style: const pw.TextStyle(fontSize: 11)),
          ],
          if (!wordsTravel) ...<pw.Widget>[
            pw.SizedBox(height: 6),
            pw.Text(
                ProjectExportService.printable(
                    ProjectExportService.wordsStayHome),
                style: const pw.TextStyle(fontSize: 10)),
          ],
          pw.SizedBox(height: 20),
          ...chart.map(
            (line) => line.section
                ? pw.Padding(
                    padding: const pw.EdgeInsets.only(top: 14, bottom: 4),
                    child: pw.Text(
                      line.words.toUpperCase(),
                      style: pw.TextStyle(
                        fontSize: 11,
                        fontWeight: pw.FontWeight.bold,
                        letterSpacing: 1.1,
                      ),
                    ),
                  )
                : pw.Padding(
                    padding: const pw.EdgeInsets.only(bottom: 7),
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: <pw.Widget>[
                        if (line.chords.isNotEmpty)
                          pw.Text(
                            line.chords,
                            softWrap: false,
                            maxLines: 1,
                            style: pw.TextStyle(
                              font: monoBold,
                              fontSize: _chartFontSize,
                            ),
                          ),
                        if (line.words.isNotEmpty)
                          pw.Text(
                            line.words,
                            softWrap: false,
                            maxLines: 1,
                            style: pw.TextStyle(
                              font: mono,
                              fontSize: _chartFontSize,
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
    return document;
  }

  static Future<void> printChart({
    required SongProject project,
    required List<MusicianSheetLine> lines,
    required int transpose,
    String? musicalKey,
    double? bpm,
  }) async {
    final document = chartDocument(
      project: project,
      lines: lines,
      transpose: transpose,
      musicalKey: musicalKey,
      bpm: bpm,
    );
    await Printing.layoutPdf(
      name: '${ProjectExportService.fileName(project.title)}-chart.pdf',
      onLayout: (_) => document.save(),
    );
  }

  /// Hands the ChordPro out as a `.cho` file through the share sheet the
  /// rest of the app uses.
  ///
  /// Shared as bytes rather than written to disk first, so this is the same
  /// one path on a phone and in a browser — the takes export learned that
  /// the hard way, by throwing `MissingPluginException` out of path_provider
  /// on the web and reporting it as a fault.
  static Future<void> shareChordPro({
    required SongProject project,
    required List<MusicianSheetLine> lines,
    required int transpose,
    String? musicalKey,
    double? bpm,
  }) async {
    final text = chordPro(
      project: project,
      lines: lines,
      transpose: transpose,
      musicalKey: musicalKey,
      bpm: bpm,
    );
    final name = '${ProjectExportService.fileName(project.title)}.cho';
    await SharePlus.instance.share(
      ShareParams(
        subject: project.title,
        files: <XFile>[
          XFile.fromData(
            Uint8List.fromList(utf8.encode(text)),
            mimeType: 'text/plain',
            name: name,
          ),
        ],
        // XFile.fromData has no file on disk to take a name from, so without
        // this the receiving app is handed something called "null".
        fileNameOverrides: <String>[name],
      ),
    );
  }

  /// A chord name a text file and a printer can both carry.
  ///
  /// [chordDisplay] writes a diminished chord with ° and a half-diminished
  /// with ♭ — right on screen, and neither one is in the encoding the
  /// built-in PDF fonts use or in anything OnSong and Planning Center parse.
  /// Only the copy leaving the app changes; what is stored and what is drawn
  /// stay exactly as they are. The square bracket goes because a `]` inside
  /// `[...]` would end the chord early and spill the rest of it into the
  /// words.
  static String plainChordName(String chord) => chord
      .replaceAll('♯', '#')
      .replaceAll('♭', 'b')
      .replaceAll('°', 'dim')
      .replaceAll('[', '')
      .replaceAll(']', '')
      .trim();

  /// Breaks a chart line that is wider than the page, keeping both rows on
  /// the same column grid so the chords stay over their own words.
  ///
  /// The break is looked for backwards from the last column that fits, and
  /// only where neither row is in the middle of something — a chord cut in
  /// half is a different chord, and a word cut in half is worse. When there
  /// is no such column the line is cut where the page ends, which is what a
  /// single unbroken 90-character word deserves.
  static List<ChartTextLine> wrap(ChartTextLine line, {int? columns}) {
    if (line.section) return <ChartTextLine>[line];
    final safeColumns = math.max(8, columns ?? chartColumns);
    var chords = line.chords;
    var words = line.words;
    final pieces = <ChartTextLine>[];
    while (true) {
      if (math.max(chords.length, words.length) <= safeColumns) {
        pieces.add(
          ChartTextLine(chords: chords.trimRight(), words: words.trimRight()),
        );
        return List<ChartTextLine>.unmodifiable(pieces);
      }
      var cut = 0;
      for (var at = safeColumns; at > 0; at -= 1) {
        if (_breakable(chords, at) && _breakable(words, at)) {
          cut = at;
          break;
        }
      }
      if (cut <= 0) cut = safeColumns;
      pieces.add(
        ChartTextLine(
          chords: _upTo(chords, cut).trimRight(),
          words: _upTo(words, cut).trimRight(),
        ),
      );
      chords = _from(chords, cut);
      words = _from(words, cut);
      final lead = _commonLead(chords, words);
      chords = _from(chords, lead);
      words = _from(words, lead);
      if (chords.isEmpty && words.isEmpty) {
        return List<ChartTextLine>.unmodifiable(pieces);
      }
    }
  }

  /// Whether a line can be cut just before column [at]: either the row has
  /// ended by then, or the character landing on that column is a space.
  static bool _breakable(String row, int at) =>
      at >= row.length || row[at] == ' ';

  static String _upTo(String row, int at) =>
      at >= row.length ? row : row.substring(0, at);

  static String _from(String row, int at) =>
      at >= row.length ? '' : row.substring(at);

  /// The leading spaces both rows share, which are dropped so a continuation
  /// starts at the left margin rather than where it happened to break.
  static int _commonLead(String chords, String words) {
    final chordLead = chords.length - chords.trimLeft().length;
    final wordLead = words.length - words.trimLeft().length;
    if (chords.trim().isEmpty) return wordLead;
    if (words.trim().isEmpty) return chordLead;
    return math.min(chordLead, wordLead);
  }

  /// A brace directive holds one value and ends at the first `}`, so neither
  /// brace can appear inside one.
  static String _directiveSafe(String value) =>
      value.replaceAll('{', '(').replaceAll('}', ')').trim();

  static const double _margin = 46;
  static const double _chartFontSize = 10;

  /// How many characters of Courier fit between the margins of a letter page.
  ///
  /// Courier advances 0.6 of its point size per character, always — that is
  /// what makes it usable here — so this is arithmetic rather than a guess.
  static final int chartColumns =
      ((PdfPageFormat.letter.width - _margin * 2) / (_chartFontSize * 0.6))
          .floor();
}

/// One printed line of a chart. See [ChordSheetExport.textLine].
class ChartTextLine {
  const ChartTextLine({
    required this.chords,
    required this.words,
    this.section = false,
  });

  /// The chord row, padded with spaces so each chord starts over its word.
  final String chords;

  /// The word row — or the section's name when [section] is true, and empty
  /// on a song the room did not write.
  final String words;

  final bool section;

  bool get isEmpty => chords.isEmpty && words.isEmpty;

  @override
  String toString() => section ? '[$words]' : '$chords\n$words';
}
