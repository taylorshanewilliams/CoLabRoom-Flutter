import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';

/// A six-string fretted-instrument chord shape, low string to high string
/// (standard guitar tuning order: E A D G B E).
///
/// Lived in the Toolbox until the Toolbox was removed. It moved here rather
/// than being deleted with it because the chord chart draws these — which was
/// always the better place for them: a shape you open by tapping the chord
/// you are looking at, already in your key.
class ChordDiagramData {
  const ChordDiagramData({
    required this.name,
    required this.frets,
    this.baseFret = 1,
    this.spokenName,
  });

  final String name;

  /// One entry per string, low to high. -1 = muted (X), 0 = open (O),
  /// N = fret N relative to [baseFret].
  final List<int> frets;

  /// The fret the diagram starts on, for shapes played higher up the neck.
  final int baseFret;

  /// What to call this chord out loud, where the written name is not what
  /// anybody says: "G major" for `G`, "G minor 7th" for `Gm7`. Falls back to
  /// [name], which a screen reader will spell rather than pronounce.
  final String? spokenName;
}

/// The six strings, low to high, named the way a player says them.
const List<String> _stringNames = <String>[
  'Low E',
  'A',
  'D',
  'G',
  'B',
  'High E',
];

/// What a screen reader says instead of the picture.
///
/// Every Musician, Same Song, 17 September 2026: schools and universities
/// have to meet WCAG 2.1 AA, and SC 1.1.1 asks every non-text thing that
/// carries meaning for a text alternative. A `CustomPaint` carries no
/// semantics whatsoever — this diagram was, to VoiceOver and TalkBack, an
/// empty rectangle — so the shape is said string by string, in the order a
/// teacher says it:
///
///     G major. Low E, 3rd fret. A, 2nd fret. D, open. G, open. B, open.
///     High E, 3rd fret.
///
/// Frets are absolute, not the diagram's own window, because "1st fret" on a
/// shape drawn from the 5th is a lie a sighted reader is protected from by
/// the `5fr` printed beside the grid.
String chordDiagramReading(ChordDiagramData chord) {
  final said = <String>[];
  final name = (chord.spokenName ?? chord.name).trim();
  if (name.isNotEmpty) said.add(name);

  // Before the strings, because it is the thing the hand does first and the
  // one thing the dots cannot show.
  final barre = _barre(chord);
  if (barre != null) {
    said.add('Barre at the ${_ordinal(barre.fret)} fret, '
        '${_stringNames[barre.from]} to ${_stringNames[barre.to]}');
  }

  final strings = math.min(_stringNames.length, chord.frets.length);
  for (var s = 0; s < strings; s += 1) {
    final fret = chord.frets[s];
    if (fret < 0) {
      said.add('${_stringNames[s]}, muted');
    } else if (fret == 0) {
      said.add('${_stringNames[s]}, open');
    } else {
      said.add('${_stringNames[s]}, ${_ordinal(chord.baseFret + fret - 1)} fret');
    }
  }
  return said.isEmpty ? '' : '${said.join('. ')}.';
}

/// The barre in a shape, read out of the shape itself.
///
/// There is no barre field to read: the shapes come from `music_reference`,
/// which stores a movable shape as frets relative to its own barre and says
/// "Barre at fret 5" in a hint meant for sighted eyes. Rather than thread a
/// new field through, the finger is inferred, which also covers any shape
/// somebody types in later.
///
/// A barre is the lowest fretted fret held on **both** of the outermost
/// strings that sound, spanning at least three strings, with nothing open in
/// between — one finger cannot lie across an open string. That is exactly the
/// E family (`[1,3,3,2,1,1]`, low E to high E) and the A family
/// (`[-1,1,3,3,3,1]`, A to high E), and none of the twenty-nine open shapes
/// in the library: A major holds three strings at the 2nd fret but its
/// outermost sounding strings are both open, and D major holds its 2nd fret
/// on two strings with an open D between them.
///
/// Two strings is enough — the A shape only sounds the barre at its two ends
/// — which is why the span is what rules a pair of ordinary fingers out.
({int fret, int from, int to})? _barre(ChordDiagramData chord) {
  final strings = math.min(_stringNames.length, chord.frets.length);
  final sounding = <int>[];
  final fretted = <int>[];
  for (var s = 0; s < strings; s += 1) {
    if (chord.frets[s] >= 0) sounding.add(s);
    if (chord.frets[s] > 0) fretted.add(s);
  }
  if (fretted.isEmpty) return null;

  var lowest = chord.frets[fretted.first];
  for (final s in fretted) {
    lowest = math.min(lowest, chord.frets[s]);
  }
  final held = fretted.where((s) => chord.frets[s] == lowest).toList();
  if (held.length < 2) return null;
  if (held.first != sounding.first || held.last != sounding.last) return null;
  if (held.last - held.first < 2) return null;
  for (var s = held.first + 1; s < held.last; s += 1) {
    if (chord.frets[s] == 0) return null;
  }
  return (fret: chord.baseFret + lowest - 1, from: held.first, to: held.last);
}

/// "1st", "2nd", "3rd" — said rather than shown, so a fret number reads as a
/// place on the neck and not as a count.
String _ordinal(int n) {
  if (n % 100 >= 11 && n % 100 <= 13) return '${n}th';
  return switch (n % 10) {
    1 => '${n}st',
    2 => '${n}nd',
    3 => '${n}rd',
    _ => '${n}th',
  };
}

/// Draws a standard six-string chord diagram: strings run vertically,
/// frets horizontally, with X/O markers above muted/open strings and
/// filled dots on fretted positions.
class GuitarChordDiagram extends StatelessWidget {
  const GuitarChordDiagram({required this.chord, this.size = 120, super.key});

  final ChordDiagramData chord;
  final double size;

  @override
  Widget build(BuildContext context) {
    // The drawing and the words are the same fact. See [chordDiagramReading].
    return Semantics(
      label: chordDiagramReading(chord),
      image: true,
      child: SizedBox(
        width: size,
        height: size * 1.15,
        child: CustomPaint(painter: _ChordPainter(chord)),
      ),
    );
  }
}

class _ChordPainter extends CustomPainter {
  _ChordPainter(this.chord);

  final ChordDiagramData chord;
  static const _strings = 6;
  static const _frets = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final markerRowHeight = size.height * 0.14;
    final baseFretRowHeight = chord.baseFret > 1 ? size.height * 0.12 : 0.0;
    final gridTop = markerRowHeight + baseFretRowHeight;
    final gridHeight = size.height - gridTop - size.height * 0.04;
    final gridWidth = size.width * 0.86;
    final gridLeft = (size.width - gridWidth) / 2;

    final stringGap = gridWidth / (_strings - 1);
    final fretGap = gridHeight / _frets;

    final linePaint = Paint()
      ..color = AppColors.muted
      ..strokeWidth = 1.4;
    final nutPaint = Paint()
      ..color = AppColors.text
      ..strokeWidth = chord.baseFret == 1 ? 4 : 1.4;

    for (var s = 0; s < _strings; s++) {
      final x = gridLeft + stringGap * s;
      canvas.drawLine(Offset(x, gridTop), Offset(x, gridTop + gridHeight), linePaint);
    }
    for (var f = 0; f <= _frets; f++) {
      final y = gridTop + fretGap * f;
      canvas.drawLine(
        Offset(gridLeft, y),
        Offset(gridLeft + gridWidth, y),
        f == 0 ? nutPaint : linePaint,
      );
    }

    if (chord.baseFret > 1) {
      final textPainter = TextPainter(
        text: TextSpan(
          text: '${chord.baseFret}fr',
          style: const TextStyle(color: AppColors.cyan, fontSize: 11, fontWeight: FontWeight.w700),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(canvas, Offset(gridLeft + gridWidth + 4, gridTop + 2));
    }

    final dotRadius = stringGap * 0.32;
    for (var s = 0; s < _strings && s < chord.frets.length; s++) {
      final fret = chord.frets[s];
      final x = gridLeft + stringGap * s;
      if (fret < 0) {
        _drawMark(canvas, Offset(x, markerRowHeight / 2), 'X', const Color(0xFFFF9AA9));
      } else if (fret == 0) {
        _drawMark(canvas, Offset(x, markerRowHeight / 2), 'O', AppColors.cyan);
      } else {
        final y = gridTop + fretGap * (fret - 0.5);
        canvas.drawCircle(Offset(x, y), dotRadius, Paint()..color = AppColors.cyan);
      }
    }
  }

  void _drawMark(Canvas canvas, Offset center, String symbol, Color color) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: symbol,
        style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w800),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(canvas, center - Offset(textPainter.width / 2, textPainter.height / 2));
  }

  @override
  bool shouldRepaint(covariant _ChordPainter oldDelegate) => oldDelegate.chord != chord;
}
