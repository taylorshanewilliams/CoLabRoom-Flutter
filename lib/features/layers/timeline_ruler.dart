import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../widgets/text_measures.dart';
import 'take_lane.dart';

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
  ///
  /// The strip takes it that the lanes begin at its own left edge, which is
  /// how the arrange view stacks them, and works out the rest of the way in
  /// to the waveform from the lane itself.
  final double leftInset;

  /// The style a time is drawn in.
  ///
  /// Lifted out of the build so the strip is measured against the style it
  /// actually draws rather than a second copy of the numbers, which is the
  /// kind of pair that drifts apart the first time somebody changes one.
  static const labelStyle = TextStyle(
    color: Color(0xFF4E6183),
    fontSize: 9,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.3,
  );

  /// The mark under the time.
  static const double _tickHigh = 5;
  static const double _tickWide = 1;

  /// The least room one time gets before the next, as a share of its own
  /// width: a quarter over, which is about a digit of air at whatever size
  /// the reader has set their text. Marks that cannot have that much are
  /// thinned out rather than drawn over each other.
  static const double _leastAir = 1.25;

  @override
  Widget build(BuildContext context) {
    final high = linesOfTextHigh(context, labelStyle);
    return SizedBox(
      // 22 held a 9-point time over a 5-pixel tick at the text size of the
      // phone it was measured on, and only there. Every Musician, Same Song,
      // 17 September 2026: the phone's own text size is honoured, never
      // clamped, so the times grow — at twice the size the time alone is 25
      // and the strip overflowed by 8, once for every mark on it. Measured
      // now, with the old number as the floor so that nothing moves for a
      // reader who has not turned their text up.
      height: math.max(22, high + _tickHigh),
      child: Row(
        children: <Widget>[
          SizedBox(width: leftInset),
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                final wide =
                    textWidthOf(context, _widestTime(totalMs), labelStyle);
                // Where the audio itself begins and ends, counted from this
                // strip's own left edge: a lane holds its waveform inside its
                // padding and past its header column, so the sound starts a
                // few pixels right of where this strip starts and stops a few
                // short of its right edge. Marks spread across the whole
                // strip instead sit beside the moment they name rather than
                // on it.
                final from =
                    math.max(0.0, TakeLane.waveStartsInLane - leftInset);
                final span = math.max(
                  0.0,
                  box.maxWidth - from - TakeLane.waveEndsBeforeLaneEnd,
                );
                // The furthest left a time can start and still be whole.
                final furthest = math.max(0.0, box.maxWidth - wide);
                final marks = _marks(
                  totalMs,
                  span: span,
                  timeWide: wide,
                  edge: math.min(from, TakeLane.waveEndsBeforeLaneEnd),
                );
                return Stack(
                  children: <Widget>[
                    for (final mark in marks) ...<Widget>[
                      // The time, centred over its mark, and held inside the
                      // strip at the two ends rather than hanging off them:
                      // the first mark stands at the very start of the audio
                      // and the last at the very end, so half of a time large
                      // enough to read would be off the edge of the screen.
                      // Every Musician, Same Song, 17 September 2026 — the
                      // phone's own text size is honoured, and half a time is
                      // not honouring it.
                      Positioned(
                        left: (from + mark.at * span - wide / 2)
                            .clamp(0.0, furthest),
                        top: 0,
                        width: wide,
                        child: Text(
                          mark.label,
                          style: labelStyle,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          softWrap: false,
                        ),
                      ),
                      // The mark itself, placed by its own centre. Aligned by
                      // fraction, as it was, a mark is placed by the width of
                      // the time above it — so it walked rightwards as the
                      // reader's text grew, and at the largest sizes 0:00
                      // stood a good seventeen seconds into a three-minute
                      // song while 3:00 stood short of the end.
                      Positioned(
                        left: from + mark.at * span - _tickWide / 2,
                        top: high,
                        width: _tickWide,
                        height: _tickHigh,
                        child: const ColoredBox(color: AppColors.line),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// The longest time this strip could draw, for measuring against.
  ///
  /// No mark runs past the end of the song, so no time carries more digits
  /// than the song's last whole minute. Every time on one strip is given the
  /// room of the longest, which is what stops them shuffling sideways as the
  /// song grows a minute.
  static String _widestTime(int totalMs) =>
      '${math.max(0, totalMs) ~/ 60000}:00';

  /// Round numbers a person reads, at a spacing that fits a phone.
  ///
  /// A fixed count would put marks at 0:37 and 1:14 on one song and 0:09 and
  /// 0:18 on another. Snapping to 15/30/60-second steps means the same song
  /// always carries the same marks, and every mark is a time somebody could
  /// say out loud.
  ///
  /// [span] is how many pixels the marks are spread over, [timeWide] how wide
  /// one of them is drawn, and [edge] how little room there is beyond the
  /// first and last marks — so a step is only taken if the times it makes
  /// have room to be read. Six marks fit a phone at an ordinary text size and
  /// two or three at the largest, and at the largest the difference between
  /// six and three is the difference between a row of times and a smear. The
  /// same song still always carries the same marks on the same phone: it is
  /// the reader's own text size that decides how many of them, and that does
  /// not change while they are looking at it.
  static List<_Mark> _marks(
    int totalMs, {
    double span = 0,
    double timeWide = 0,
    double edge = 0,
  }) {
    if (totalMs <= 0) return const <_Mark>[];
    final seconds = totalMs / 1000;
    const steps = <int>[5, 10, 15, 30, 60, 120, 300];
    // A time at either end is held inside the strip, so it can stand as much
    // as half its own width nearer its neighbour than its mark is; what the
    // neighbour has to clear is where it lands, not where its mark stands.
    final pushed = math.max(0.0, timeWide / 2 - edge);
    var step = steps.last;
    for (final candidate in steps) {
      final fitsThePhone = seconds / candidate <= 6;
      final canBeRead = span <= 0 ||
          span * candidate / seconds >= timeWide * _leastAir + pushed;
      if (fitsThePhone && canBeRead) {
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
    // The playhead: a line and the handle on top of it. Both are decoration
    // in the strict sense — where the playhead is says nothing a screen
    // reader can act on, and the transport says it in words. IgnorePointer
    // keeps fingers off it but leaves it in the semantics tree, so the
    // exclusion has to be said.
    return Positioned.fill(
      left: leftInset,
      child: ExcludeSemantics(
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
