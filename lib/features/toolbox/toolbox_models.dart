import 'package:flutter/material.dart';

class ToolboxCategory {
  const ToolboxCategory({
    required this.id,
    required this.name,
    required this.icon,
    required this.tagline,
    this.sheets = const <CheatSheet>[],
  });

  final String id;
  final String name;
  final IconData icon;
  final String tagline;
  final List<CheatSheet> sheets;

  bool get hasContent => sheets.isNotEmpty;
}

enum CheatSheetKind { chordDiagrams, text }

class CheatSheet {
  const CheatSheet({
    required this.id,
    required this.title,
    required this.icon,
    required this.kind,
    this.chords = const <ChordDiagramData>[],
    this.sections = const <CheatSheetSection>[],
  });

  final String id;
  final String title;
  final IconData icon;
  final CheatSheetKind kind;

  /// Populated when [kind] is [CheatSheetKind.chordDiagrams].
  final List<ChordDiagramData> chords;

  /// Populated when [kind] is [CheatSheetKind.text].
  final List<CheatSheetSection> sections;
}

class CheatSheetSection {
  const CheatSheetSection({required this.heading, required this.rows});

  final String heading;
  final List<CheatSheetRow> rows;
}

class CheatSheetRow {
  const CheatSheetRow(this.label, this.value);

  final String label;
  final String value;
}

/// A six-string fretted-instrument chord shape, low string to high string
/// (standard guitar tuning order: E A D G B E).
class ChordDiagramData {
  const ChordDiagramData({
    required this.name,
    required this.frets,
    this.baseFret = 1,
  });

  final String name;

  /// One entry per string, low to high. -1 = muted (X), 0 = open (O),
  /// N = fret N relative to [baseFret].
  final List<int> frets;

  /// The fret the diagram starts on, for shapes played higher up the neck.
  final int baseFret;
}
