import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/colabroom_theme.dart';

class BrandMark extends StatelessWidget {
  const BrandMark({this.compact = false, super.key});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: compact ? 36 : 46,
          height: compact ? 36 : 46,
          decoration: BoxDecoration(
            color: AppColors.deepNavy,
            borderRadius: BorderRadius.circular(compact ? 12 : 15),
            border: Border.all(color: AppColors.line),
            boxShadow: const <BoxShadow>[
              BoxShadow(color: Color(0x243AD3FF), blurRadius: 24),
            ],
          ),
          child: const CustomPaint(painter: _CoLabRoomMarkPainter()),
        ),
        const SizedBox(width: 12),
        // Flexible, and it has to be here rather than only at the call site.
        //
        // The mark is a fixed square but the wordmark beside it is text at 26
        // points, so it grows with the reader's font setting — and a Row with
        // mainAxisSize.min hands its children their natural width and lets
        // them run off the end. Wrapping the whole BrandMark in a Flexible
        // outside does not help: that constrains the Row, and the Row then
        // overflows internally instead, which is exactly what happened.
        //
        // Softwrap off with an ellipsis, because a brand that breaks onto two
        // lines in a header looks like a bug, and one that is quietly clipped
        // mid-letter looks like a worse one.
        Flexible(
          child: Text.rich(
            const TextSpan(
              children: <InlineSpan>[
                TextSpan(text: 'CoLab', style: TextStyle(color: AppColors.text)),
                TextSpan(text: 'Room', style: TextStyle(color: AppColors.cyan)),
              ],
            ),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: compact ? 20 : 26,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }
}

class _CoLabRoomMarkPainter extends CustomPainter {
  const _CoLabRoomMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    final gradient = const LinearGradient(
      colors: <Color>[Color(0xFF159DFF), Color(0xFF35D8F7)],
    ).createShader(bounds);
    final ring = Paint()
      ..shader = gradient
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.shortestSide * 0.14
      ..strokeCap = StrokeCap.square;
    canvas.drawArc(
      Rect.fromCircle(
        center: bounds.center,
        radius: size.shortestSide * 0.33,
      ),
      math.pi * 0.25,
      math.pi * 1.5,
      false,
      ring,
    );

    final play = Path()
      ..moveTo(size.width * 0.41, size.height * 0.33)
      ..lineTo(size.width * 0.72, size.height * 0.5)
      ..lineTo(size.width * 0.41, size.height * 0.67)
      ..close();
    canvas.drawPath(play, Paint()..shader = gradient);
  }

  @override
  bool shouldRepaint(covariant _CoLabRoomMarkPainter oldDelegate) => false;
}
