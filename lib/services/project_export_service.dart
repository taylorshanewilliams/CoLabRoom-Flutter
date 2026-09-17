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
  static bool _wordsTravel(SongProject project) =>
      project.songOrigin != SongOrigin.cover;

  /// The lines an export carries: everything on a song of the room's own,
  /// and everything but the words on somebody else's.
  static Iterable<Contribution> _linesFor(SongProject project) =>
      _wordsTravel(project)
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
    if (!_wordsTravel(project)) {
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

  static String setlistText(Setlist setlist, Iterable<SongProject> projects) {
    final songs = projects.toList(growable: false);
    final buffer = StringBuffer(setlist.name);
    for (var index = 0; index < songs.length; index += 1) {
      buffer
        ..writeln()
        ..write('${index + 1}. ${songs[index].title}');
    }
    return buffer.toString();
  }

  static Future<void> shareSong(SongProject project) {
    return _share(project.title, songText(project));
  }

  static Future<void> shareSetlist(Setlist setlist, Iterable<SongProject> projects) {
    return _share(setlist.name, setlistText(setlist, projects));
  }

  static Future<void> _share(String subject, String text) async {
    await SharePlus.instance.share(ShareParams(subject: subject, text: text));
  }

  static Future<void> printSong(SongProject project) {
    return _print(project.title, _songDocument(project));
  }

  static Future<void> printSetlist(Setlist setlist, Iterable<SongProject> projects) {
    final songs = projects.toList(growable: false);
    final document = pw.Document();
    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.all(46),
        build: (_) => <pw.Widget>[
          pw.Text(setlist.name, style: pw.TextStyle(fontSize: 25, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 20),
          ...songs.indexed.map(
            (entry) => pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 7),
              child: pw.Text('${entry.$1 + 1}.  ${entry.$2.title}',
                  style: const pw.TextStyle(fontSize: 15)),
            ),
          ),
        ],
      ),
    );
    return _print(setlist.name, document);
  }

  static pw.Document _songDocument(SongProject project) {
    final document = pw.Document();
    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.all(46),
        build: (_) => <pw.Widget>[
          pw.Text(project.title, style: pw.TextStyle(fontSize: 25, fontWeight: pw.FontWeight.bold)),
          if (project.description.trim().isNotEmpty) ...<pw.Widget>[
            pw.SizedBox(height: 7),
            pw.Text(project.description.trim(), style: const pw.TextStyle(fontSize: 10)),
          ],
          if (!_wordsTravel(project)) ...<pw.Widget>[
            pw.SizedBox(height: 7),
            pw.Text(wordsStayHome, style: const pw.TextStyle(fontSize: 10)),
          ],
          pw.SizedBox(height: 22),
          ..._linesFor(project).map((line) {
            final section = line.kind == ContributionKind.section;
            return pw.Padding(
              padding: pw.EdgeInsets.only(top: section ? 14 : 3, bottom: 3),
              child: pw.Text(
                section ? line.body.toUpperCase() : line.body,
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
      name: '${_fileName(title)}.pdf',
      onLayout: (_) => document.save(),
    );
  }

  static String _fileName(String title) {
    final cleaned = title.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '').trim();
    return cleaned.isEmpty ? 'CoLabRoom' : cleaned.replaceAll(' ', '-');
  }
}
