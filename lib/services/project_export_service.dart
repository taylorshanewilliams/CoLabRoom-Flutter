import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../domain/music_models.dart';

class ProjectExportService {
  const ProjectExportService._();

  static String songText(SongProject project) {
    final buffer = StringBuffer(project.title);
    if (project.description.trim().isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(project.description.trim());
    }
    for (final line in project.contributions) {
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
          pw.SizedBox(height: 22),
          ...project.contributions.map((line) {
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
