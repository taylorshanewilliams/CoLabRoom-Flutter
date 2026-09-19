import 'dart:ui' show Rect;

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../domain/music_models.dart';

class ProjectExportService {
  const ProjectExportService._();

  /// What a print or a share says instead of the words, on a song the room
  /// did not write.
  ///
  /// Said rather than left silent: an export that quietly dropped every line
  /// would read as the app having lost somebody's work.
  static const String wordsStayHome =
      'Words are not included — somebody else wrote this one.';

  /// Whether the words travel with the song.
  ///
  /// Every Musician, Same Song, 17 September 2026: a cover's text exports
  /// carry the structure and leave the words in the room. The structure is
  /// what a musician needs on a stand; the words are the part that is not
  /// the room's to hand out. Audio exports of the band's own takes are a
  /// different question and are left alone.
  ///
  /// Public because the chord chart and the ChordPro file are text exports
  /// too and have to obey the same rule (see ChordSheetExport). One answer,
  /// in one place, so a second export cannot quietly disagree with this one.
  static bool wordsTravel(SongProject project) =>
      project.songOrigin != SongOrigin.cover;

  /// The lines an export carries: everything on a song of the room's own,
  /// and everything but the words on somebody else's.
  static Iterable<Contribution> _linesFor(SongProject project) =>
      wordsTravel(project)
          ? project.contributions
          : project.contributions
              .where((line) => line.kind != ContributionKind.lyric);

  static String songText(SongProject project) {
    final buffer = StringBuffer(project.title);
    if (project.description.trim().isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(project.description.trim());
    }
    if (!wordsTravel(project)) {
      buffer
        ..writeln()
        ..writeln(wordsStayHome);
    }
    for (final line in _linesFor(project)) {
      buffer
        ..writeln()
        ..write(line.kind == ContributionKind.section ? line.body.toUpperCase() : line.body);
    }
    return buffer.toString();
  }

  // A set prints and shares through SetlistPack: the running order with each
  // song's key, tempo, count-in, form, ending and note, then a chart per
  // song. The title-only list this file used to write is what a stand-in
  // could not play from (Every Musician, Same Song, 17 September 2026).

  /// [origin] is where on screen the share was asked for, which an iPad hangs
  /// the share sheet off. It comes from the caller because this file has no
  /// context to measure and a global one would be a guess; see
  /// services/share_origin.dart.
  ///
  /// Required, and not nullable, so that a caller who has not thought about
  /// where the sheet points does not compile. `shareOrigin(context)` always
  /// answers something usable, so there is no caller that has nothing to
  /// pass -- and a share that quietly went back to the middle of the screen
  /// is exactly the failure nothing here can see.
  static Future<void> shareSong(SongProject project, {required Rect origin}) {
    return _share(project.title, songText(project), origin);
  }

  static Future<void> _share(String subject, String text, Rect origin) async {
    await SharePlus.instance.share(ShareParams(
      subject: subject,
      text: text,
      sharePositionOrigin: origin,
    ));
  }

  static Future<void> printSong(SongProject project) {
    return _print(project.title, _songDocument(project));
  }

  static pw.Document _songDocument(SongProject project) {
    final document = pw.Document();
    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.all(46),
        build: (_) => <pw.Widget>[
          pw.Text(printable(project.title), style: pw.TextStyle(fontSize: 25, fontWeight: pw.FontWeight.bold)),
          if (project.description.trim().isNotEmpty) ...<pw.Widget>[
            pw.SizedBox(height: 7),
            pw.Text(printable(project.description.trim()), style: const pw.TextStyle(fontSize: 10)),
          ],
          if (!wordsTravel(project)) ...<pw.Widget>[
            pw.SizedBox(height: 7),
            pw.Text(printable(wordsStayHome), style: const pw.TextStyle(fontSize: 10)),
          ],
          pw.SizedBox(height: 22),
          ..._linesFor(project).map((line) {
            final section = line.kind == ContributionKind.section;
            return pw.Padding(
              padding: pw.EdgeInsets.only(top: section ? 14 : 3, bottom: 3),
              child: pw.Text(
                printable(section ? line.body.toUpperCase() : line.body),
                style: pw.TextStyle(
                  fontSize: section ? 12 : 11,
                  fontWeight: section ? pw.FontWeight.bold : pw.FontWeight.normal,
                ),
              ),
            );
          }),
        ],
      ),
    );
    return document;
  }

  static Future<void> _print(String title, pw.Document document) async {
    await Printing.layoutPdf(
      name: '${fileName(title)}.pdf',
      onLayout: (_) => document.save(),
    );
  }

  /// Text a built-in PDF font can actually draw.
  ///
  /// The fonts every PDF reader already has are Latin-1 and nothing else, and
  /// the pdf package does not soften that: it calls `latin1.encode` on the
  /// string and **throws** on the first character outside the set. So a song
  /// with a curly apostrophe in it — which is every lyric pasted out of a
  /// document, and most of what a transcript writes — did not print badly, it
  /// did not print at all. Nor did a cover, because the sentence this file
  /// puts in place of the words has an em dash in it (found while building
  /// the chord chart, 17 September 2026).
  ///
  /// Typographic quotes, dashes and ellipses become their typewriter
  /// equivalents, which is what they were before somebody's word processor
  /// got hold of them. Anything else outside Latin-1 becomes a question
  /// mark: a printed page that says a character is missing, rather than an
  /// export that fails. Carrying those properly needs a Unicode font
  /// embedded in the app, which is a megabyte of asset for a case nobody has
  /// hit yet.
  ///
  /// The one answer. The lesson poster and the provenance record print
  /// through the same built-in fonts and call this rather than keeping a
  /// rule of their own, because a teacher called "José 王" getting "José " on
  /// one page and "José ?" on another, from the same app in the same
  /// session, is two answers to one question.
  static String printable(String value) {
    final folded = value
        .replaceAll('‘', "'")
        .replaceAll('’', "'")
        .replaceAll('‚', "'")
        .replaceAll('“', '"')
        .replaceAll('”', '"')
        .replaceAll('„', '"')
        .replaceAll('–', '-')
        .replaceAll('—', '-')
        .replaceAll('―', '-')
        .replaceAll('…', '...')
        .replaceAll('′', "'")
        .replaceAll('″', '"')
        .replaceAll('♯', '#')
        .replaceAll('♭', 'b')
        .replaceAll(' ', ' ');
    final out = StringBuffer();
    for (final rune in folded.runes) {
      out.writeCharCode(rune <= 0xFF ? rune : 0x3F);
    }
    return out.toString();
  }

  /// A title turned into something a file system will accept.
  ///
  /// Public alongside [wordsTravel]: the chart, the ChordPro file, the lesson
  /// poster and the provenance record are all named the same way, and each
  /// one holding its own copy of the same regular expression is how they
  /// stop being the same way. [fallback] is what a title made entirely of
  /// punctuation leaves behind, which is the only part that differs.
  static String fileName(String title, {String fallback = 'CoLabRoom'}) {
    final cleaned = title.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '').trim();
    return cleaned.isEmpty ? fallback : cleaned.replaceAll(RegExp(r'\s+'), '-');
  }
}
