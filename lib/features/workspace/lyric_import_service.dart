import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:csv/csv.dart';
import 'package:pdf_document/pdf_document.dart';
import 'package:pdf_graphics/pdf_graphics.dart';
import 'package:xml/xml.dart';

import '../../domain/music_models.dart';

class LyricImportDraft {
  const LyricImportDraft({required this.sourceName, required this.lines});

  final String sourceName;
  final List<ContributionDraft> lines;

  String get editableText => lines.map((line) => line.body).join('\n');
}

class LyricImportException implements Exception {
  const LyricImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract final class LyricImportService {
  static const maxFileBytes = 12 * 1024 * 1024;
  static const maxLines = 500;
  // Guards against a single pathologically long cell/paragraph (e.g. a
  // misread spreadsheet row with no column boundaries) blowing up the
  // review screen's text field with one enormous unbroken line.
  static const maxLineLength = 400;

  static LyricImportDraft fromFile({
    required String name,
    required Uint8List bytes,
  }) {
    if (bytes.isEmpty) throw const LyricImportException('That file is empty.');
    if (bytes.length > maxFileBytes) {
      throw const LyricImportException('Choose a lyric file smaller than 12 MB.');
    }
    final extension = name.split('.').last.toLowerCase();
    final rawLines = switch (extension) {
      'pdf' => _pdfLines(bytes),
      'xlsx' => _spreadsheetLines(bytes),
      'csv' => _csvLines(utf8.decode(bytes, allowMalformed: true)),
      'txt' || 'md' => utf8.decode(bytes, allowMalformed: true).split(RegExp(r'\r?\n')),
      _ => throw const LyricImportException('Use a PDF, XLSX, CSV, TXT, or Markdown file.'),
    };
    return LyricImportDraft(sourceName: name, lines: cleanLines(rawLines));
  }

  static LyricImportDraft fromText({required String sourceName, required String text}) {
    return LyricImportDraft(
      sourceName: sourceName,
      lines: cleanLines(text.split(RegExp(r'\r?\n'))),
    );
  }

  static LyricImportDraft fromCsv({required String sourceName, required String csvText}) {
    return LyricImportDraft(sourceName: sourceName, lines: cleanLines(_csvLines(csvText)));
  }

  static List<ContributionDraft> cleanLines(Iterable<String> rawLines) {
    final result = <ContributionDraft>[];
    for (final raw in rawLines) {
      var line = raw
          .replaceAll('\ufeff', '')
          .replaceAll(RegExp(r'[\u200B-\u200D\u2060]'), '')
          .trim();
      line = line.replaceFirst(RegExp(r'^(?:[•●▪◦‣⁃*\-]+|\d+[.)])\s+'), '');
      line = line.replaceAll(RegExp(r'[\t ]+'), ' ').trim();
      if (line.length > maxLineLength) line = '${line.substring(0, maxLineLength)}…';
      // Catches stray separator rows (a lone "-", "—", "x", "N/A") that
      // survive as a non-empty cell in an otherwise-unused row — these
      // aren't digits, so the check above lets them through, but they're
      // not lyrics either.
      if (line.isEmpty ||
          RegExp(r'^\d+$').hasMatch(line) ||
          !RegExp(r'\p{L}', unicode: true).hasMatch(line)) {
        continue;
      }
      final lowered = line.toLowerCase();
      if (<String>{
        'lyric',
        'lyrics',
        'line',
        'lines',
        'text',
        'song lyrics',
        'section',
        'sections',
      }.contains(lowered)) {
        continue;
      }
      final section = _sectionLabel(line);
      result.add(
        ContributionDraft(
          body: section ?? line,
          kind: section == null ? ContributionKind.lyric : ContributionKind.section,
        ),
      );
      if (result.length == maxLines) break;
    }
    if (result.isEmpty) {
      throw const LyricImportException(
        'No readable lyric lines were found. Scanned PDFs may need OCR before importing.',
      );
    }
    return result;
  }

  static List<String> _pdfLines(Uint8List bytes) {
    try {
      final document = PdfDocument.open(bytes);
      final lines = <String>[];
      for (var page = 0; page < document.pageCount; page++) {
        lines.addAll(PdfTextExtractor.extract(document, page).text.split(RegExp(r'\r?\n')));
      }
      return lines;
    } catch (error) {
      throw LyricImportException('Could not read that PDF: $error');
    }
  }

  static List<String> _spreadsheetLines(Uint8List bytes) {
    try {
      final workbook = ZipDecoder().decodeBytes(bytes);
      ArchiveFile? sharedStringsFile;
      for (final file in workbook) {
        if (file.name == 'xl/sharedStrings.xml') {
          sharedStringsFile = file;
          break;
        }
      }
      final sharedStrings = sharedStringsFile == null
          ? const <String>[]
          : XmlDocument.parse(
              utf8.decode(sharedStringsFile.content, allowMalformed: true),
            )
              .findAllElements('si')
              .map((item) => item.findAllElements('t').map((text) => text.innerText).join())
              .toList(growable: false);
      final sheets = workbook
          .where(
            (file) => RegExp(r'^xl/worksheets/[^/]+\.xml$').hasMatch(file.name),
          )
          .toList(growable: false)
        ..sort((left, right) => left.name.compareTo(right.name));
      final lines = <String>[];
      for (final sheet in sheets) {
        final document = XmlDocument.parse(
          utf8.decode(sheet.content, allowMalformed: true),
        );
        for (final row in document.findAllElements('row')) {
          for (final cell in row.findElements('c')) {
            final type = cell.getAttribute('t');
            final valueElements = cell.findElements('v');
            final rawValue = valueElements.isEmpty ? '' : valueElements.first.innerText;
            String value;
            if (type == 's') {
              final index = int.tryParse(rawValue);
              value = index != null && index >= 0 && index < sharedStrings.length
                  ? sharedStrings[index]
                  : '';
            } else if (type == 'inlineStr') {
              value = cell.findAllElements('t').map((text) => text.innerText).join();
            } else {
              value = rawValue;
            }
            if (value.trim().isNotEmpty) lines.add(value);
          }
        }
      }
      return lines;
    } catch (error) {
      throw LyricImportException('Could not read that spreadsheet: $error');
    }
  }

  static List<String> _csvLines(String source) {
    try {
      final normalized = source.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
      final rows = const CsvToListConverter(
        shouldParseNumbers: false,
        eol: '\n',
      ).convert(normalized);
      // One spreadsheet row becomes one line — using that row's single
      // longest cell, not every non-empty cell joined together. A sheet
      // built for songwriting usually has more than a lyrics column (chord,
      // section, timing, notes); those are reliably shorter than the actual
      // lyric text in the same row, so picking the longest cell isolates
      // the lyrics column without needing the user to say which one it is.
      return rows
          .map((row) {
            var longest = '';
            for (final cell in row) {
              final value = cell?.toString().trim() ?? '';
              if (value.length > longest.length) longest = value;
            }
            return longest;
          })
          .where((line) => line.isNotEmpty)
          .toList(growable: false);
    } catch (error) {
      throw LyricImportException('Could not read that CSV: $error');
    }
  }

  static String? _sectionLabel(String source) {
    final match = RegExp(
      r'^\[?\s*(intro|verse|pre[ -]?chorus|chorus|refrain|bridge|hook|breakdown|interlude|outro)(?:\s+(\d+))?\s*[:\]]?$',
      caseSensitive: false,
    ).firstMatch(source);
    if (match == null) return null;
    final words = match.group(1)!
        .replaceAll('-', ' ')
        .split(' ')
        .map((word) => '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}')
        .join(' ');
    final number = match.group(2);
    return '[${number == null ? words : '$words $number'}]';
  }
}
