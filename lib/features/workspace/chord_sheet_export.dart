import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:colabroom/domain/music_models.dart';
import 'package:colabroom/domain/song_analysis_models.dart';
import 'package:colabroom/features/workspace/musician_sheet_logic.dart';
import 'package:colabroom/services/project_export_service.dart';
import 'package:colabroom/services/rehearsal_letters.dart';
import 'package:colabroom/services/song_language.dart';
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
        letter: line.letter,
      );
    }
    // Split the way the sheet splits it — by word, or by character in a
    // script that does not space them (0163) — because chord placement is by
    // index into this list, and a chart that counted the pieces differently
    // would put the same chord over a different syllable from the one on
    // screen. Split first and folded to printable characters after, one piece
    // at a time: printable() replaces every character the built-in PDF fonts
    // cannot draw with '?', and splitting that would be counting question
    // marks rather than the song's own pieces (review, 18 September 2026).
    // Each piece still occupies the width it prints in, which is what decides
    // where the chord above it starts.
    final units = lyricUnits(line.body, language: line.language);
    final words = <String>[
      for (final unit in units) ProjectExportService.printable(unit),
    ];
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
    // Nothing between two characters of a script that is written without
    // spaces: a space after every character would be a line no reader of it
    // has ever seen, and it would double the width of every line on the page.
    // A space does stay where only one side is such a character, so an
    // English word in a Chinese line is still a word.
    for (var index = 0; index < words.length; index += 1) {
      if (index > 0) {
        // Measured on the song's own characters, not on the '?' they print
        // as: whether two pieces need a space between them is a fact about
        // the language and not about the font.
        wordRow.write(
          unitGapBetween(units[index - 1], units[index], line.language),
        );
      }
      // A placeholder is not a word. An instrumental line carries one marker
      // per chord so the chords have something to sit over on screen (see
      // [instrumentalMark]); printed as written it is a page of dots handed
      // to somebody as if they were lyrics.
      final word = words[index] == instrumentalMark ? '' : words[index];
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
      wordRow.write(word);
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
  ///
  /// Each heading carries its rehearsal letter with it, so the page can mark
  /// the part the way a band names it out loud — see rehearsal_letters.dart.
  static List<MusicianSheetLine> withSectionNames(
    List<MusicianSheetLine> lines,
    List<StructureSection> sections,
  ) {
    if (lines.isEmpty || sections.isEmpty) return lines;
    if (lines.any((line) => line.section)) return lines;
    final ordered = rehearsalLetters(sections);
    final out = <MusicianSheetLine>[];
    var next = 0;
    for (final line in lines) {
      RehearsalLetter? due;
      while (next < ordered.length &&
          ordered[next].startMs <= line.startMs + _sectionPickupMs) {
        due = ordered[next];
        next += 1;
      }
      if (due != null) {
        out.add(
          MusicianSheetLine(
            contributionId: null,
            body: due.label,
            section: true,
            startMs: due.startMs,
            endMs: due.endMs,
            chords: const <ChordCue>[],
            approximateTiming: false,
            letter: due.letter,
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
  ///
  /// [notes] are extra lines for the top of the file, written as comments
  /// under the header the way the cover's own sentence is. A whole song needs
  /// none; a cut of one needs to say which bars it is and, for a song the
  /// room did not write, that the recording stayed behind as well as the
  /// words (see passage_export.dart).
  static String chordPro({
    required SongProject project,
    required List<MusicianSheetLine> lines,
    required int transpose,
    String? musicalKey,
    double? bpm,
    List<String> notes = const <String>[],
  }) {
    final wordsTravel = ProjectExportService.wordsTravel(project);
    final out = StringBuffer('{title: ${_directiveSafe(project.title)}}\n');
    if (musicalKey != null && musicalKey.trim().isNotEmpty) {
      out.writeln(
        '{key: ${_directiveSafe(chordProKey(keyAsPlayed(musicalKey.trim(), transpose)))}}',
      );
    }
    if (bpm != null && bpm > 0) out.writeln('{tempo: ${bpm.round()}}');
    if (!wordsTravel) {
      out.writeln('{comment: ${_directiveSafe(ProjectExportService.wordsStayHome)}}');
    }
    for (final note in notes) {
      final line = _directiveSafe(note);
      if (line.isNotEmpty) out.writeln('{comment: $line}');
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
        // The name goes into the directive either way: the block is what a
        // chorus looks like, the label is which chorus it is, and a file that
        // opens three unnamed blocks in a row has thrown away the second
        // half of what a chart is read for.
        if (_namesAChorus(label)) {
          out.writeln('{start_of_chorus: $label}');
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

  /// Whether a part's name is the chorus itself, rather than a part that
  /// merely has the word in its name.
  ///
  /// This used to be `contains('chorus')`, which made a pre-chorus and a
  /// post-chorus into the chorus — a formatted block around the wrong bars,
  /// and in a reader that indents a chorus, a page that lies about the shape
  /// of the song. Matched from the front instead, so "Chorus", "Chorus 2"
  /// and "Chorus (last time)" open the block and "Pre-Chorus" falls through
  /// to a comment like every other part.
  ///
  /// A label is whatever the band called the part (see
  /// [StructureSection.displayLabel]), so this has to be a judgement about
  /// text rather than a lookup.
  static bool _namesAChorus(String label) =>
      _chorusLabel.hasMatch(label.trim());

  static final RegExp _chorusLabel = RegExp(r'^chorus\b', caseSensitive: false);

  /// A key written the way ChordPro's `{key}` directive means it: a chord,
  /// not a sentence.
  ///
  /// The key on the page is English — the separation worker returns "A minor"
  /// — and printed as "Key of A minor" that is exactly right. In the file it
  /// is not: OnSong and Planning Center transpose the whole song by this
  /// value and both want a chord shape, so "A minor" arriving verbatim is a
  /// key neither of them can use and a transpose control with nothing to work
  /// from. Only the directive is folded; the printed sentence stays a
  /// sentence.
  ///
  /// The test for a minor key is the one `keyUsesFlats` already uses, so a
  /// mode named two ways cannot be read two ways. Anything else — a dorian,
  /// a mixolydian, a word nothing recognises — comes out as its tonic alone,
  /// which is a key a reader can at least transpose by.
  static String chordProKey(String key) {
    final match = RegExp(r'^([A-G][#b]?)\s*(.*)$').firstMatch(key.trim());
    if (match == null) return key.trim();
    final rest = match.group(2)!.toLowerCase();
    final minor =
        rest.startsWith('min') || rest == 'm' || rest.startsWith('aeolian');
    return minor ? '${match.group(1)!}m' : match.group(1)!;
  }

  static String _chordProLine(
    MusicianSheetLine line, {
    required int transpose,
    String? musicalKey,
    required bool wordsTravel,
  }) {
    // The sheet's own pieces again (0163), for the same reason the printed
    // chart uses them: a chord in a ChordPro file names the syllable it is
    // written in front of, and that has to be the syllable it is over here.
    final words = line.units;
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
      if (index > 0) {
        out.write(unitGapBetween(words[index - 1], words[index], line.language));
      }
      if (name.isNotEmpty) out.write('[$name]');
      // The same rule as the printed chart: a marker is where a word would
      // be, not a word. `[G]· [C]·` for a whole song is a lyric sheet of
      // middle dots in OnSong.
      if (words[index] != instrumentalMark) out.write(words[index]);
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
    String arrangement = '',
  }) {
    return pw.Document()
      ..addPage(
        chartPage(
          project: project,
          lines: lines,
          transpose: transpose,
          musicalKey: musicalKey,
          bpm: bpm,
          arrangement: arrangement,
        ),
      );
  }

  /// The line under a chart's title: the key and the tempo, whichever are
  /// known.
  ///
  /// The key is [musicalKey] moved by [transpose], unless [keyLabel] names
  /// it outright. The stand-in's pack hands it the set's key as the band
  /// wrote it, so a chart cannot disagree with the running order above it
  /// about what key the song is done in: a song heard in A minor and done in
  /// C major moves no chord, and the moved song key would still have read
  /// "A minor" (review, 18 September 2026).
  static List<String> chartFacts({
    required int transpose,
    String? musicalKey,
    String? keyLabel,
    double? bpm,
  }) {
    final named = keyLabel?.trim();
    return <String>[
      if (named != null && named.isNotEmpty)
        'Key of $named'
      else if (musicalKey != null && musicalKey.trim().isNotEmpty)
        'Key of ${keyAsPlayed(musicalKey.trim(), transpose)}',
      if (bpm != null && bpm > 0) '${bpm.round()} bpm',
    ];
  }

  /// The chart as pages that can go into a document of somebody else's.
  ///
  /// Split from [chartDocument] for the stand-in's pack (Every Musician, Same
  /// Song, 17 September 2026): a set prints as its running order followed by
  /// one of these per song, in one file, and the pdf package has no way to
  /// glue two documents together after the fact. The page is exactly what
  /// the song's own print produces, so a chart in a pack cannot differ from
  /// the same chart printed from the song.
  ///
  /// [arrangement] is the song's whole form on one line — "I A A B A C B B O"
  /// — printed under the facts. Empty for a song whose sections are not
  /// known, and then the line is not printed at all.
  static pw.MultiPage chartPage({
    required SongProject project,
    required List<MusicianSheetLine> lines,
    required int transpose,
    String? musicalKey,
    String? keyLabel,
    double? bpm,
    String arrangement = '',
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

    final facts = chartFacts(
      transpose: transpose,
      musicalKey: musicalKey,
      keyLabel: keyLabel,
      bpm: bpm,
    );

    final mono = pw.Font.courier();
    final monoBold = pw.Font.courierBold();
    return pw.MultiPage(
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
        // The shape of the song, under its title, where a chart writes it.
        // In Courier with the rest of the page so the letters keep the
        // spacing they were written with.
        if (arrangement.isNotEmpty) ...<pw.Widget>[
          pw.SizedBox(height: 6),
          pw.Text(
            ProjectExportService.printable(arrangement),
            style: pw.TextStyle(
              font: monoBold,
              fontSize: 11,
              letterSpacing: 1.1,
            ),
          ),
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
                    // The letter beside the name, the way a chart marks a
                    // part somebody will call for out loud.
                    line.heading,
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
    );
  }

  static Future<void> printChart({
    required SongProject project,
    required List<MusicianSheetLine> lines,
    required int transpose,
    String? musicalKey,
    double? bpm,
    String arrangement = '',
  }) async {
    final document = chartDocument(
      project: project,
      lines: lines,
      transpose: transpose,
      musicalKey: musicalKey,
      bpm: bpm,
      arrangement: arrangement,
    );
    await Printing.layoutPdf(
      name: '${ProjectExportService.fileName(project.title)}-chart.pdf',
      onLayout: (_) => document.save(),
    );
  }

  /// Hands the ChordPro out as a `.cho` file through the share sheet the
  /// rest of the app uses.
  ///
  /// Shared as bytes rather than written to disk first, which keeps
  /// path_provider out of it — the takes export learned that the hard way,
  /// by throwing `MissingPluginException` out of path_provider on the web
  /// and reporting it as a fault.
  ///
  /// That is only half of it, though, and the half that is left is why the
  /// button is not offered in a browser. share_plus on the web hands a file
  /// to `navigator.share`, which desktop Firefox and Safari do not have, so
  /// this would throw there for a reason that is a limit of the browser
  /// rather than anything broken. A limit reported as a fault is the exact
  /// shape the takes screen already removed. The caller gates on `kIsWeb`
  /// and says so in a sentence instead.
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
    this.letter,
  });

  /// The chord row, padded with spaces so each chord starts over its word.
  final String chords;

  /// The word row — or the section's name when [section] is true, and empty
  /// on a song the room did not write.
  final String words;

  final bool section;

  /// The part's rehearsal letter, on a [section] line that has one.
  final String? letter;

  /// The heading as it is printed: "B  CHORUS", or the name alone for a part
  /// with no letter to give — and the letter alone where the name would only
  /// repeat it (see rehearsal_letters.dart).
  String get heading => letteredHeading(letter, words);

  bool get isEmpty => chords.isEmpty && words.isEmpty;

  @override
  String toString() => section ? '[$words]' : '$chords\n$words';
}
