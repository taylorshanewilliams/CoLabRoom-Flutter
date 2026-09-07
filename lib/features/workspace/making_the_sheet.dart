import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../services/audio_analysis_utils.dart';

/// The best minute in this app, given a minute's worth of screen.
///
/// Somebody has just handed over a recording of themselves. For the next few
/// minutes the app pulls the instruments apart, works out every chord, finds
/// the beat, and writes down the words they sang. Then it hands back a song
/// sheet with their music on it.
///
/// It used to show that as a hairline progress bar and a ten-point grey label.
/// The app was doing the most remarkable thing it does and describing it in a
/// font size reserved for disclaimers — and the arrival, the actual payoff,
/// was a bar disappearing.
///
/// **The stages are already true.** "Separating the instruments" is not
/// marketing; it is what is happening at that second, reported by the pipeline
/// itself. So this does not invent anything. It gives the sentence the size it
/// deserves, keeps the finished ones on screen so the wait accumulates into
/// something rather than looping, and lets the last one land.
///
/// **Nobody has to watch it.** The note about leaving stays, and stays
/// prominent: this is a nice thing to look at, not a thing to be held by.
class MakingTheSheet extends StatelessWidget {
  const MakingTheSheet({
    required this.progress,
    required this.songTitle,
    super.key,
  });

  final SongAnalysisProgress progress;
  final String songTitle;

  /// The pipeline's own stages, in the order they happen.
  ///
  /// Matched on the fraction rather than the label, because the labels are
  /// written where the work is and should stay free to change without
  /// silently emptying this list.
  static const List<({double at, String said})> _stages =
      <({double at, String said})>[
    (at: 0.05, said: 'Listening to your recording'),
    (at: 0.15, said: 'Separating the instruments'),
    (at: 0.50, said: 'Working out every chord'),
    (at: 0.75, said: 'Writing down the words you sang'),
    (at: 0.90, said: 'Putting the song sheet together'),
  ];

  @override
  Widget build(BuildContext context) {
    final fraction = progress.fraction.clamp(0.0, 1.0);
    final done = <String>[
      for (final stage in _stages)
        if (fraction > stage.at) stage.said,
    ];
    final nowDoing = _stages
        .where((s) => fraction <= s.at)
        .map((s) => s.said)
        .firstOrNull;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 26, 20, 22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.gold.withValues(alpha: 0.3)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            AppColors.gold.withValues(alpha: 0.09),
            AppColors.raised,
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _Pulse(fraction: fraction),
          const SizedBox(height: 22),

          // The line that is true right now, at the size the sentence
          // deserves. Keyed so it animates when the stage changes rather than
          // swapping silently.
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 420),
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.28),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
            child: Text(
              nowDoing ?? 'Almost there',
              key: ValueKey<String>(nowDoing ?? 'done'),
              style: const TextStyle(
                color: AppColors.text,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                height: 1.2,
                letterSpacing: -0.3,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            songTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.muted, fontSize: 13),
          ),

          // What is already done, kept on screen. The wait stops being a bar
          // that loops and becomes a list that grows — which is the difference
          // between waiting and watching something happen.
          if (done.isNotEmpty) ...<Widget>[
            const SizedBox(height: 18),
            for (final said in done)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: <Widget>[
                    const Icon(Icons.check_rounded,
                        size: 14, color: AppColors.green),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        said,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppColors.muted, fontSize: 12.5),
                      ),
                    ),
                  ],
                ),
              ),
          ],

          const SizedBox(height: 16),
          // Kept, and kept prominent. This is a nice thing to look at, not a
          // thing to be held by, and the wait is minutes long.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Icon(Icons.edit_note_rounded,
                  size: 14, color: AppColors.muted),
              const SizedBox(width: 7),
              const Expanded(
                child: Text(
                  'Go and write. This keeps going without you — come back '
                  'when it is done.',
                  style: TextStyle(
                      color: AppColors.muted, fontSize: 12, height: 1.4),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Something alive while the machine works.
///
/// A ring rather than a bar, because a bar's job is to say how long is left
/// and this genuinely does not know — the GPU queue is the slowest part and
/// nothing can see into it. A ring that turns says *working* without
/// pretending to say *nearly done*, and the filled arc still carries the real
/// fraction for anybody watching closely.
class _Pulse extends StatefulWidget {
  const _Pulse({required this.fraction});

  final double fraction;

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  )..repeat();

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 64,
      width: 64,
      child: AnimatedBuilder(
        animation: _spin,
        builder: (context, _) => CustomPaint(
          painter: _RingPainter(
            fraction: widget.fraction,
            turn: _spin.value,
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({required this.fraction, required this.turn});

  final double fraction;
  final double turn;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 4;
    final rect = Rect.fromCircle(center: centre, radius: radius);

    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = AppColors.line,
    );

    // The real progress, drawn from the top.
    canvas.drawArc(
      rect,
      -math.pi / 2,
      2 * math.pi * fraction.clamp(0.0, 1.0),
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = AppColors.gold,
    );

    // And a short arc that keeps turning, so the ring is alive even during
    // the long stretch where the fraction does not move — which is most of
    // the wait, because the GPU queue is opaque.
    canvas.drawArc(
      rect,
      2 * math.pi * turn,
      0.6,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = AppColors.cyan,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.turn != turn || old.fraction != fraction;
}
