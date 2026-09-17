import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../services/invite_link.dart';

/// A lesson link on paper, for the wall of a studio or a music shop.
///
/// Taylor's first sentence about lessons was a teacher who can "email out or
/// share a qr code or whatever". The screen does the first two; this is the
/// whatever that hangs by the door. One page: what the lessons are, who
/// teaches them, the code big enough to scan from across a room, and the
/// typed code under it for a phone whose camera will not cooperate.
///
/// Printed through the system dialog, which also saves a PDF -- for a
/// newsletter, a website, or a print shop.
abstract final class LessonPoster {
  static Future<void> print({
    required String title,
    required String code,
    String? teacher,
  }) {
    return Printing.layoutPdf(
      name: '${_fileName(title)}-lesson-poster.pdf',
      onLayout: (format) => document(title: title, code: code, teacher: teacher, format: format).save(),
    );
  }

  static pw.Document document({
    required String title,
    required String code,
    String? teacher,
    PdfPageFormat format = PdfPageFormat.a4,
  }) {
    final who = printable(teacher ?? '').trim();
    final document = pw.Document(title: _heading(title), author: who.isEmpty ? 'CoLabRoom' : who);

    document.addPage(
      pw.Page(
        pageFormat: format,
        margin: margin,
        build: (context) => sheet(title: title, code: code, teacher: teacher),
      ),
    );
    return document;
  }

  /// The white space round the page.
  static const margin = pw.EdgeInsets.fromLTRB(48, 44, 48, 40);

  /// Everything printed on the page, inside [margin].
  ///
  /// Centred: a page lays its child out loosely, and a column on its own
  /// shrinks to its widest line and sits against the left margin.
  static pw.Widget sheet({
    required String title,
    required String code,
    String? teacher,
  }) {
    final heading = _heading(title);
    final who = printable(teacher ?? '').trim();
    return pw.Center(
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: <pw.Widget>[
          pw.Text(
            'CoLabRoom',
            style: const pw.TextStyle(fontSize: 12, color: PdfColors.grey700, letterSpacing: 2),
          ),
          pw.SizedBox(height: 26),
          pw.Text(
            heading,
            textAlign: pw.TextAlign.center,
            maxLines: 2,
            style: pw.TextStyle(fontSize: _headingSize(heading), fontWeight: pw.FontWeight.bold),
          ),
          if (who.isNotEmpty) ...<pw.Widget>[
            pw.SizedBox(height: 6),
            pw.Text(
              'with $who',
              textAlign: pw.TextAlign.center,
              maxLines: 2,
              style: pw.TextStyle(fontSize: _nameSize(who), color: PdfColors.grey800),
            ),
          ],
          pw.SizedBox(height: 30),
          pw.BarcodeWidget(
            barcode: pw.Barcode.qrCode(errorCorrectLevel: pw.BarcodeQRCorrectionLevel.medium),
            data: lessonLink(code),
            // As big as a US Letter page allows under everything else:
            // scanned from across a room, not from arm's length.
            width: 320,
            height: 320,
            drawText: false,
          ),
          pw.SizedBox(height: 18),
          pw.Text(
            'Scan with your phone camera',
            style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 8),
          // Said on the wall, not only in the app: whoever reads this is the
          // person deciding whether to scan it (Every Musician, Same Song,
          // 17 September 2026 -- adult students first, until there is a
          // guardian step).
          pw.Text(
            'For students 18 and over',
            style: const pw.TextStyle(fontSize: 14, color: PdfColors.grey800),
          ),
          pw.SizedBox(height: 10),
          pw.Container(
            width: 380,
            child: pw.Text(
              'Everybody who scans gets their own room with me: just the two of us, '
              'the song sheet, and what we worked on last time.',
              textAlign: pw.TextAlign.center,
              style: const pw.TextStyle(fontSize: 13, color: PdfColors.grey800, lineSpacing: 3),
            ),
          ),
          pw.Spacer(),
          pw.Text(
            'Or open CoLabRoom, choose Join with a code, and type',
            style: const pw.TextStyle(fontSize: 12, color: PdfColors.grey700),
          ),
          pw.SizedBox(height: 6),
          pw.Text(
            lessonCodeSaid(code),
            style: pw.TextStyle(fontSize: 28, fontWeight: pw.FontWeight.bold, letterSpacing: 3),
          ),
          pw.SizedBox(height: 14),
          pw.Text(
            'app.colabroom.com',
            style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey600),
          ),
        ],
      ),
    );
  }

  static String _heading(String title) {
    final printed = printable(title).trim();
    return printed.isEmpty ? 'Lessons' : printed;
  }

  /// How big the title is drawn.
  ///
  /// A teacher can type 60 characters (0129), and at 40 pt that wraps to
  /// three lines on the shorter US page. A column that runs out of room
  /// stops laying children out rather than complaining, so the typed code
  /// and the address simply were not on the printed page -- found by
  /// measuring, not on paper. A long title is drawn smaller, and never on
  /// more than two lines, so the bottom of the poster is always there.
  static double _headingSize(String heading) => switch (heading.length) {
        <= 24 => 40,
        <= 40 => 30,
        _ => 24,
      };

  /// The same rule for the teacher's own name, which nothing caps: a name is
  /// drawn whole, smaller if it is long, rather than cut short or printed off
  /// the page.
  static double _nameSize(String who) => who.length <= 30 ? 22 : 16;

  /// What the page's built-in font can draw. Names and titles are typed by
  /// people and can carry an emoji or a script the standard PDF fonts do not
  /// have; a poster missing one character is fine, a poster that will not
  /// print at all is not.
  static String printable(String text) =>
      String.fromCharCodes(text.runes.where((rune) => rune >= 0x20 && rune <= 0xFF));

  static String _fileName(String title) {
    final cleaned = title.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '').trim();
    return cleaned.isEmpty ? 'lessons' : cleaned.replaceAll(' ', '-');
  }
}
