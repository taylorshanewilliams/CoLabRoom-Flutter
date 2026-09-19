import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../domain/music_models.dart';
import '../../domain/song_analysis_models.dart';
import '../../services/project_export_service.dart';
import '../../services/rehearsal_letters.dart';
import '../workspace/chord_sheet_export.dart';
import '../workspace/continuous_song_editor.dart' show displayContributionBody;
import '../workspace/count_in.dart';
import '../workspace/musician_sheet_logic.dart';

/// A setlist that knows each song, and the pack a stand-in reads on the
/// night.
///
/// Every Musician, Same Song, 17 September 2026: the live scene runs on a
/// paper list anyone can trust. A set stored titles and an order; a gigging
/// band needs what to do with each song — the key it is done in, the tempo,
/// who counts it, the shape, how it ends, and "straight into the next one".
/// Read from the analysis where it exists and overridable by the band, on
/// the set rather than on the song: doing a song down a tone on Saturday has
/// not changed what key the song is in.
///
/// Kept away from the screen so the answers can be tested without a phone,
/// and so the row on the screen, the text that is shared and the printed
/// page all read the same facts through the same call.

/// What the set says about one song, with the song's own answers filled in
/// wherever the band said nothing.
class SetSongFacts {
  const SetSongFacts({
    required this.key,
    required this.bpm,
    required this.countIn,
    required this.form,
    required this.ending,
    required this.note,
    required this.songKey,
    required this.transpose,
  });

  /// The key the set does the song in: the band's answer for this occasion,
  /// or the song's own key.
  final String? key;

  final double? bpm;
  final String? countIn;
  final String? form;
  final String? ending;
  final String? note;

  /// The song's own key — what its chords are counted from — which is the
  /// key a chart has to be handed to be moved into [key].
  final String? songKey;

  /// Semitones from the song's own key up to the set's: what the chart is
  /// transposed by. Zero when they agree, and zero when the song's key is
  /// not known, because chords in an unknown key cannot be moved anywhere
  /// honestly — the set still names its key on the list.
  final int transpose;

  /// The line under a title: "G major · 96 bpm · One bar of 4 · Ending: cold".
  ///
  /// The form and the note are left off it, because both run long and each
  /// is a line of its own on the page.
  String get line => <String>[
        if (key != null) key!,
        if (bpm != null && bpm! > 0) '${bpm!.round()} bpm',
        if (countIn != null) countIn!,
        if (ending != null) 'Ending: ${ending!}',
      ].join(' · ');
}

/// What the set says about [project], from what the band wrote on it and
/// what the song's own analysis found.
///
/// Every fallback lives here and nowhere else. The key falls back to the
/// song's own ([SongProject.songKey]: the band's key, else the detected
/// one). The tempo falls back to the analysis. The count-in falls back to
/// one bar of the song's own metre, worked out the way Perform counts a
/// band in ([countInForSong]), and to nothing when the recording has no beat
/// the app would trust. The form falls back to the song's sections: the
/// ones typed into it, else the ones the analysis heard.
SetSongFacts setSongFacts(
  SetlistSong? entry,
  SongProject project,
  SongAnalysisBundle? bundle,
) {
  final reference = bundle?.reference;
  final songKey = _spelled(project.songKey(reference?.musicalKey));
  final key = _spelled(entry?.key) ?? songKey;
  // From bar 1 onward, the way Perform does it. The metre is the median gap
  // between downbeats, and a count-in the beat tracker read as bars of its
  // own can outvote a short song and count the band in on two; the song
  // already says where its own bar 1 is, so the same guess is made from
  // there (0161).
  final counted = countInForSong(reference, barOne: project.barOne);
  return SetSongFacts(
    key: key,
    bpm: entry?.bpm ?? reference?.bpm,
    countIn: entry?.countIn ?? (counted == null ? null : 'One bar of ${counted.beats}'),
    form: entry?.form ?? songForm(project, reference),
    ending: entry?.ending,
    note: entry?.note,
    songKey: songKey,
    transpose: entry?.key == null ? 0 : semitonesBetweenKeys(songKey, key),
  );
}

/// A key written the way a chart writes it: "Bb major" for the "A# major"
/// the analyser names every flat key as (audit, 17 September 2026). The
/// list, the sheet's hint and the chart's header all read a key through
/// this, so one song cannot be "A# major" on the list and "Bb major" on the
/// chart under it.
String? _spelled(String? key) {
  final said = key?.trim();
  if (said == null || said.isEmpty) return null;
  return keyAsPlayed(said, 0);
}

/// The shape of a song as its sections say it: "Intro · Verse · Chorus".
///
/// The sections typed into the song first, because those are the band's own
/// words for its parts; the analysis's when nobody typed any. Null when
/// neither knows the shape, so a page does not print an empty label.
String? songForm(SongProject project, ReferenceTrack? reference) {
  final typed = <String>[
    for (final line in project.contributions)
      if (isSheetSection(line))
        cleanSheetSection(displayContributionBody(line.body)),
  ].where((label) => label.isNotEmpty).toList(growable: false);
  final labels = typed.isNotEmpty
      ? typed
      : (List<StructureSection>.of(reference?.structureSections ?? const <StructureSection>[])
            ..sort((a, b) => a.startMs.compareTo(b.startMs)))
          .map((section) => section.displayLabel)
          .where((label) => label.trim().isNotEmpty)
          .toList(growable: false);
  return labels.isEmpty ? null : labels.join(' · ');
}

/// One song of the pack: the song, what the set says about it, and the
/// chart's lines — empty when the song has nothing on its sheet.
class SetlistPackSong {
  const SetlistPackSong({
    required this.project,
    required this.facts,
    required this.lines,
    this.arrangement = '',
  });

  final SongProject project;
  final SetSongFacts facts;
  final List<MusicianSheetLine> lines;

  /// The song's whole form on one line — "I A A B A C B B O" — for the top
  /// of its chart page, exactly as the song's own print writes it. Empty
  /// when the recording has no sections.
  final String arrangement;

  bool get hasChart => lines.isNotEmpty;
}

/// The set as one file a stand-in can read: the running order with each
/// song's facts, then the chord chart for every song that has one, in the
/// key the set does it in.
abstract final class SetlistPack {
  /// The pack's songs in the set's order. [analyses] is what could be loaded
  /// for each song; a song with none, or with nothing on its sheet, is on
  /// the list and gets no chart.
  static List<SetlistPackSong> songs({
    required Setlist setlist,
    required List<SongProject> projects,
    required Map<String, SongAnalysisBundle?> analyses,
  }) {
    return <SetlistPackSong>[
      for (final project in projects)
        SetlistPackSong(
          project: project,
          facts: setSongFacts(setlist.songFor(project.id), project, analyses[project.id]),
          lines: chartLines(project, analyses[project.id]),
          arrangement: arrangementCode(rehearsalLetters(
            analyses[project.id]?.reference?.structureSections ??
                const <StructureSection>[],
          )),
        ),
    ];
  }

  /// The chart's lines for a song, exactly as the song's own chart export
  /// builds them: the sheet the recording produced, with the recording's
  /// section names folded in. Empty without an analysis.
  static List<MusicianSheetLine> chartLines(SongProject project, SongAnalysisBundle? bundle) {
    if (bundle == null) return const <MusicianSheetLine>[];
    return ChordSheetExport.withSectionNames(
      buildMusicianSheetLines(project, bundle, ignoreWorkspaceLyrics: true),
      bundle.reference?.structureSections ?? const <StructureSection>[],
    );
  }

  /// The set as text, for a message: the running order with each song's
  /// facts under its title.
  static String text(Setlist setlist, List<SetlistPackSong> songs) {
    final buffer = StringBuffer(setlist.name);
    for (var index = 0; index < songs.length; index += 1) {
      final song = songs[index];
      buffer
        ..writeln()
        ..write('${index + 1}. ${song.project.title}');
      final line = song.facts.line;
      if (line.isNotEmpty) buffer.write(' — $line');
      final form = song.facts.form;
      if (form != null) {
        buffer
          ..writeln()
          ..write('   Form: $form');
      }
      final note = song.facts.note;
      if (note != null) {
        buffer
          ..writeln()
          ..write('   $note');
      }
    }
    return buffer.toString();
  }

  /// The pack as a PDF: the running order first, then one chart per song.
  ///
  /// The chart page is the song's own ([ChordSheetExport.chartPage]), handed
  /// the song's key and the transpose the set asks for, so a chart in the
  /// pack is the same chart the song prints — moved into the set's key, and
  /// carrying the set's tempo at the top where the song's would be. The
  /// header names the set's key as the band wrote it, so it reads the same
  /// as the running order; a song whose own key is unknown gets no key on
  /// its chart, because its chords were not moved anywhere.
  static pw.Document document(Setlist setlist, List<SetlistPackSong> songs) {
    final document = pw.Document();
    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.all(46),
        build: (_) => <pw.Widget>[
          pw.Text(
            ProjectExportService.printable(setlist.name),
            style: pw.TextStyle(fontSize: 25, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 16),
          for (final (index, song) in songs.indexed)
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 7),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: <pw.Widget>[
                  pw.Text(
                    ProjectExportService.printable('${index + 1}.  ${song.project.title}'),
                    style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold),
                  ),
                  if (song.facts.line.isNotEmpty)
                    pw.Padding(
                      padding: const pw.EdgeInsets.only(left: 22, top: 2),
                      child: pw.Text(
                        ProjectExportService.printable(song.facts.line),
                        style: const pw.TextStyle(fontSize: 11),
                      ),
                    ),
                  if (song.facts.form != null)
                    pw.Padding(
                      padding: const pw.EdgeInsets.only(left: 22, top: 2),
                      child: pw.Text(
                        ProjectExportService.printable('Form: ${song.facts.form}'),
                        style: const pw.TextStyle(fontSize: 11),
                      ),
                    ),
                  if (song.facts.note != null)
                    pw.Padding(
                      padding: const pw.EdgeInsets.only(left: 22, top: 2),
                      child: pw.Text(
                        ProjectExportService.printable(song.facts.note!),
                        style: pw.TextStyle(fontSize: 11, fontStyle: pw.FontStyle.italic),
                      ),
                    ),
                  // Said on the list, so a dep in the van can tell a song
                  // that has no chart from a page that went missing
                  // (review, 18 September 2026).
                  if (!song.hasChart)
                    pw.Padding(
                      padding: const pw.EdgeInsets.only(left: 22, top: 2),
                      child: pw.Text(
                        'No chart',
                        style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey600),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
    for (final song in songs) {
      if (!song.hasChart) continue;
      document.addPage(
        ChordSheetExport.chartPage(
          project: song.project,
          lines: song.lines,
          transpose: song.facts.transpose,
          musicalKey: song.facts.songKey,
          keyLabel: song.facts.songKey == null ? null : song.facts.key,
          bpm: song.facts.bpm,
          arrangement: song.arrangement,
        ),
      );
    }
    return document;
  }

  static Future<void> print(Setlist setlist, List<SetlistPackSong> songs) async {
    final document = SetlistPack.document(setlist, songs);
    await Printing.layoutPdf(
      name: '${ProjectExportService.fileName(setlist.name)}.pdf',
      onLayout: (_) => document.save(),
    );
  }

  /// Hands the pack out as a file through the share sheet — the one thing a
  /// dep can open in the van. Through the printing package rather than
  /// share_plus, because it knows what to do with a PDF on the web as well
  /// (it downloads), where share_plus has no share sheet to hand a file to.
  static Future<void> share(Setlist setlist, List<SetlistPackSong> songs) async {
    final Uint8List bytes = await SetlistPack.document(setlist, songs).save();
    await Printing.sharePdf(
      bytes: bytes,
      filename: '${ProjectExportService.fileName(setlist.name)}.pdf',
      subject: setlist.name,
    );
  }

  /// [origin] is where on screen the share was asked for; an iPad hangs the
  /// share sheet off it. See services/share_origin.dart.
  static Future<void> shareText(
    Setlist setlist,
    List<SetlistPackSong> songs, {
    Rect? origin,
  }) async {
    await SharePlus.instance.share(
      ShareParams(
        subject: setlist.name,
        text: text(setlist, songs),
        sharePositionOrigin: origin,
      ),
    );
  }
}
