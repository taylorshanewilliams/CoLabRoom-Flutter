import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import 'toolbox_models.dart';

/// Draws a standard six-string chord diagram: strings run vertically,
/// frets horizontally, with X/O markers above muted/open strings and
/// filled dots on fretted positions.
class GuitarChordDiagram extends StatelessWidget {
  const GuitarChordDiagram({required this.chord, this.size = 120, super.key});

  final ChordDiagramData chord;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size * 1.15,
      child: CustomPaint(painter: _ChordPainter(chord)),
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
