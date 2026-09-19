import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../services/music_reference.dart';
import 'guitar_chord_diagram.dart' show ordinalFret;

/// The two chord pictures that are not a fretted neck.
///
/// Every Musician, Same Song, 17 September 2026: the diagrams were a
/// right-handed six-string guitar, and a bass player and a pianist read the
/// same chord and need a different picture of it. Both of these describe the
/// chord and neither composes anything — there is no order to the notes here,
/// no rhythm and no line. What to play of them, and when, is the player's.

/// The four strings of a bass, lowest first, named the way a player says them.
/// One E, so it needs no "low".
const List<String> bassStrings = <String>['E', 'A', 'D', 'G'];

/// What a screen reader says instead of the bass neck.
///
///     C major. Root, A string, 3rd fret. 5th, D string, 5th fret.
///
/// The degree first and the place second, because the question a bass player
/// brings to a chord is "where is the root", not "what is at the 3rd fret".
String bassNeckReading(String spokenName, List<BassPosition> positions) {
  final said = <String>[];
  final name = spokenName.trim();
  if (name.isNotEmpty) said.add(name);
  for (final position in positions) {
    final string = position.string >= 0 && position.string < bassStrings.length
        ? bassStrings[position.string]
        : null;
    if (string == null) continue;
    // Each position starts a sentence, so the degree starts with a capital.
    // It is written lower case where it belongs — "C, the root" on the keys,
    // "root" under a note chip on the sheet.
    final degree = position.degree.isEmpty
        ? position.degree
        : position.degree[0].toUpperCase() + position.degree.substring(1);
    said.add(position.fret == 0
        ? '$degree, $string string, open'
        : '$degree, $string string, ${ordinalFret(position.fret)} fret');
  }
  return said.isEmpty ? '' : '${said.join('. ')}.';
}

/// The root and the fifth of a chord on a four-string bass, drawn the same way
/// round as the guitar diagram beside it: strings down, frets across.
///
/// The root is the heavy mark and the fifth the light one, and a slash bass —
/// the one note of a slash chord that really is the bass player's — is marked
/// as itself. Nothing joins them up, because a line between two notes is a
/// line somebody has been told to play.
class BassNeckDiagram extends StatelessWidget {
  const BassNeckDiagram({
    required this.positions,
    required this.spokenName,
    this.leftHanded = false,
    this.size = 120,
    super.key,
  });

  final List<BassPosition> positions;

  /// What the chord is called out loud — "C major over G", never `C/G`, which
  /// a screen reader reads as a date.
  final String spokenName;

  /// Whether the neck is drawn the way a left-handed player sees it: the
  /// strings the other way round, at the same frets. The words underneath do
  /// not change, because they name each string by its letter and are ordered
  /// by what the note is to the chord rather than by where it sits.
  final bool leftHanded;

  final double size;

  @override
  Widget build(BuildContext context) {
    // The drawing and the words are the same fact. See [bassNeckReading].
    return Semantics(
      label: bassNeckReading(spokenName, positions),
      image: true,
      child: SizedBox(
        width: size,
        height: size * 1.15,
        child: CustomPaint(painter: _BassPainter(positions, leftHanded)),
      ),
    );
  }
}

class _BassPainter extends CustomPainter {
  _BassPainter(this.positions, this.leftHanded);

  final List<BassPosition> positions;
  final bool leftHanded;
  static const _strings = 4;

  /// The lowest fret anything is stopped at, which is where the window starts.
  ///
  /// An open string puts it at the nut whatever else is in the chord: an O
  /// above a diagram that starts at the 2nd fret would be an open string
  /// drawn where there is no nut for it to be open against.
  int get _base {
    var lowest = 0;
    for (final position in positions) {
      if (position.fret == 0) return 1;
      if (lowest == 0 || position.fret < lowest) lowest = position.fret;
    }
    return lowest == 0 ? 1 : lowest;
  }

  /// Four frets like the guitar's, and wider when a chord's notes are further
  /// apart than that — better a crowded window than a note drawn off the end.
  int get _rows {
    var highest = _base;
    for (final position in positions) {
      highest = math.max(highest, position.fret);
    }
    return math.max(4, highest - _base + 1);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final base = _base;
    final rows = _rows;
    final markerRowHeight = size.height * 0.14;
    final baseFretRowHeight = base > 1 ? size.height * 0.12 : 0.0;
    final gridTop = markerRowHeight + baseFretRowHeight;
    final gridHeight = size.height - gridTop - size.height * 0.04;
    final gridWidth = size.width * 0.86 * 0.7;
    final gridLeft = (size.width - gridWidth) / 2;

    final stringGap = gridWidth / (_strings - 1);
    final fretGap = gridHeight / rows;

    final linePaint = Paint()
      ..color = AppColors.muted
      ..strokeWidth = 1.4;
    final nutPaint = Paint()
      ..color = AppColors.text
      ..strokeWidth = base == 1 ? 4 : 1.4;

    for (var s = 0; s < _strings; s++) {
      final x = gridLeft + stringGap * s;
      canvas.drawLine(
          Offset(x, gridTop), Offset(x, gridTop + gridHeight), linePaint);
    }
    for (var f = 0; f <= rows; f++) {
      final y = gridTop + fretGap * f;
      canvas.drawLine(
        Offset(gridLeft, y),
        Offset(gridLeft + gridWidth, y),
        f == 0 ? nutPaint : linePaint,
      );
    }

    if (base > 1) {
      final textPainter = TextPainter(
        text: TextSpan(
          text: '${base}fr',
          style: const TextStyle(
              color: AppColors.cyan, fontSize: 11, fontWeight: FontWeight.w700),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(canvas, Offset(gridLeft + gridWidth + 4, gridTop + 2));
    }

    final dotRadius = stringGap * 0.3;
    for (final position in positions) {
      if (position.string < 0 || position.string >= _strings) continue;
      // The E string is on the left for a right-handed player and on the
      // right for a left-handed one. Only the column moves: the fret a note
      // is at is the same fret either way.
      final column =
          leftHanded ? _strings - 1 - position.string : position.string;
      final x = gridLeft + stringGap * column;
      final root = position.degree == 'root';
      final color = root ? AppColors.gold : AppColors.cyan;
      if (position.fret == 0) {
        _drawMark(canvas, Offset(x, markerRowHeight / 2), 'O', color);
        continue;
      }
      final y = gridTop + fretGap * (position.fret - base + 0.5);
      final paint = Paint()..color = color;
      if (position.degree == 'bass note') {
        // A ring rather than a dot: it is the chord's foot rather than one of
        // its own notes, and it is said in words underneath either way.
        canvas.drawCircle(
          Offset(x, y),
          dotRadius,
          paint
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      } else {
        canvas.drawCircle(Offset(x, y), root ? dotRadius : dotRadius * 0.78,
            paint);
      }
    }
  }

  void _drawMark(Canvas canvas, Offset center, String symbol, Color color) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: symbol,
        style:
            TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w800),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(
        canvas, center - Offset(textPainter.width / 2, textPainter.height / 2));
  }

  @override
  bool shouldRepaint(covariant _BassPainter oldDelegate) =>
      oldDelegate.positions != positions ||
      oldDelegate.leftHanded != leftHanded;
}

/// What a screen reader says instead of the keyboard.
///
///     C major over G. C, the root. E, the 3rd. G, the 5th, and the bass.
String pianoKeysReading(String spokenName, List<PianoKey> keys) {
  final said = <String>[];
  final name = spokenName.trim();
  if (name.isNotEmpty) said.add(name);
  for (final key in keys) {
    if (key.degree == 'bass note') {
      said.add('${key.note}, in the bass');
    } else if (key.bass) {
      said.add('${key.note}, the ${key.degree}, and the bass');
    } else {
      said.add('${key.note}, the ${key.degree}');
    }
  }
  return said.isEmpty ? '' : '${said.join('. ')}.';
}

/// One octave of a keyboard with the chord's notes marked on it, the root
/// heaviest.
///
/// One octave and not two, because a chord is a set of notes and which octave
/// a pair of hands puts them in is the player's business — an inversion drawn
/// here would be a voicing somebody had been told to play.
class PianoKeysDiagram extends StatelessWidget {
  const PianoKeysDiagram({
    required this.keys,
    required this.spokenName,
    this.width = 180,
    super.key,
  });

  final List<PianoKey> keys;

  /// What the chord is called out loud — "C major over G".
  final String spokenName;

  final double width;

  @override
  Widget build(BuildContext context) {
    // The drawing and the words are the same fact. See [pianoKeysReading].
    return Semantics(
      label: pianoKeysReading(spokenName, keys),
      image: true,
      child: SizedBox(
        width: width,
        height: width * 0.6,
        child: CustomPaint(painter: _PianoPainter(keys)),
      ),
    );
  }
}

class _PianoPainter extends CustomPainter {
  _PianoPainter(this.keys);

  final List<PianoKey> keys;

  /// The pitch class of each white key of an octave, C to B.
  static const List<int> _white = <int>[0, 2, 4, 5, 7, 9, 11];

  /// The black keys, as (pitch class, which white key they sit after).
  static const List<(int, int)> _black = <(int, int)>[
    (1, 0),
    (3, 1),
    (6, 3),
    (8, 4),
    (10, 5),
  ];

  PianoKey? _marked(int pitch) {
    for (final key in keys) {
      if (key.pitch % 12 == pitch) return key;
    }
    return null;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final whiteWidth = size.width / _white.length;
    final blackWidth = whiteWidth * 0.6;
    final blackHeight = size.height * 0.62;

    final whitePaint = Paint()..color = const Color(0xFFF2F6FF);
    final blackPaint = Paint()..color = const Color(0xFF0A1424);
    final edge = Paint()
      ..color = AppColors.line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    for (var i = 0; i < _white.length; i += 1) {
      final rect = Rect.fromLTWH(whiteWidth * i, 0, whiteWidth, size.height);
      canvas.drawRect(rect, whitePaint);
      canvas.drawRect(rect, edge);
    }
    // The keys first and every mark afterwards, so a black key drawn over its
    // neighbour cannot land on top of a mark.
    for (final black in _black) {
      canvas.drawRect(
        Rect.fromLTWH(
          whiteWidth * (black.$2 + 1) - blackWidth / 2,
          0,
          blackWidth,
          blackHeight,
        ),
        blackPaint,
      );
    }

    for (var i = 0; i < _white.length; i += 1) {
      final key = _marked(_white[i]);
      if (key == null) continue;
      _mark(
        canvas,
        Offset(whiteWidth * (i + 0.5), size.height * 0.82),
        whiteWidth * 0.3,
        key,
        onBlack: false,
      );
    }
    for (final (pitch, after) in _black) {
      final key = _marked(pitch);
      if (key == null) continue;
      _mark(
        canvas,
        Offset(whiteWidth * (after + 1), blackHeight * 0.74),
        blackWidth * 0.34,
        key,
        onBlack: true,
      );
    }
  }

  void _mark(
    Canvas canvas,
    Offset center,
    double radius,
    PianoKey key, {
    required bool onBlack,
  }) {
    final root = key.degree == 'root';
    // The root heaviest, which is the one thing a chord picture has to say
    // first. Gold on the ink the rest of the app uses for what matters.
    final color = root
        ? AppColors.gold
        : onBlack
            ? AppColors.cyan
            : AppColors.blue;
    canvas.drawCircle(
      center,
      root ? radius : radius * 0.78,
      Paint()..color = color,
    );
    if (key.bass) {
      canvas.drawCircle(
        center,
        radius * 1.45,
        Paint()
          ..color = AppColors.gold
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PianoPainter oldDelegate) =>
      oldDelegate.keys != keys;
}
