import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';

/// The strip of times above the lanes.
///
/// Its job is not decoration: it is what tells somebody that the lanes below
/// share one clock, which is the whole claim the arrange view makes and the
/// reason dragging the playhead reads as scrubbing rather than as adjusting
/// a slider.
class TimelineRuler extends StatelessWidget {
  const TimelineRuler({required this.totalMs, this.leftInset = 0, super.key});

  final int totalMs;

  /// The width of the lane headers, so the marks line up with the audio
  /// rather than with the names beside it.
  final double leftInset;

  @override
  Widget build(BuildContext context) {
    final marks = _marks(totalMs);
    return SizedBox(
      height: 22,
      child: Row(
        children: <Widget>[
          SizedBox(width: leftInset),
          Expanded(
            child: Stack(
              children: <Widget>[
                for (final mark in marks)
                  Align(
                    alignment: Alignment(mark.at * 2 - 1, -1),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          mark.label,
                          style: const TextStyle(
                            color: Color(0xFF4E6183),
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.3,
                          ),
                        ),
                        Container(width: 1, height: 5, color: AppColors.line),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Round numbers a person reads, at a spacing that fits a phone.
  ///
  /// A fixed count would put marks at 0:37 and 1:14 on one song and 0:09 and
  /// 0:18 on another. Snapping to 15/30/60-second steps means the same song
  /// always carries the same marks, and every mark is a time somebody could
  /// say out loud.
  static List<_Mark> _marks(int totalMs) {
    if (totalMs <= 0) return const <_Mark>[];
    final seconds = totalMs / 1000;
    const steps = <int>[5, 10, 15, 30, 60, 120, 300];
    var step = steps.last;
    for (final candidate in steps) {
      if (seconds / candidate <= 6) {
        step = candidate;
        break;
      }
    }
    final out = <_Mark>[];
    for (var at = 0; at <= seconds; at += step) {
      out.add(_Mark(
        at: at / seconds,
        label: '${at ~/ 60}:${(at % 60).toString().padLeft(2, '0')}',
      ));
    }
    return out;
  }
}

class _Mark {
  const _Mark({required this.at, required this.label});
  final double at;
  final String label;
}

/// The line down the lanes, and the handle that drags it.
class Playhead extends StatelessWidget {
  const Playhead({required this.at, required this.leftInset, super.key});

  /// 0..1 through the song.
  final double at;
  final double leftInset;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      left: leftInset,
      child: IgnorePointer(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final x = constraints.maxWidth * at.clamp(0.0, 1.0);
            return Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                Positioned(
                  left: x - 1,
                  top: 0,
                  bottom: 0,
                  child: Container(width: 2, color: AppColors.cyan),
                ),
                Positioned(
                  left: x - 6,
                  top: -6,
                  child: CustomPaint(
                    size: const Size(12, 9),
                    painter: _KnobPainter(),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _KnobPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = AppColors.cyan);
  }

  @override
  bool shouldRepaint(_KnobPainter oldDelegate) => false;
}
