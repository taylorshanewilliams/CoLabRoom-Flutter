import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/colabroom_theme.dart';
import '../services/now_playing.dart';

/// The play button, everywhere there is something to hear.
///
/// One widget rather than one per screen, because the behaviour that matters
/// is shared: it knows whether *this* recording is the one playing, and it
/// draws how far through it is. Two of these on screen at once cannot both
/// be playing, and neither needs to know the other exists — they are both
/// looking at [NowPlaying].
///
/// Drawn as a ring that fills rather than a bar underneath, so a row in a
/// list keeps its height while a song plays. A list that reflows when you
/// press play is a list you lose your place in.
class PlayButton extends StatelessWidget {
  const PlayButton({
    required this.storagePath,
    this.size = 40,
    this.durationMs,
    this.title,
    super.key,
  });

  /// Where the audio is. Empty means this song has none, and the button
  /// draws as a quiet disabled circle rather than not at all — the row keeps
  /// its shape, and a missing recording is visible instead of implied.
  final String storagePath;

  final double size;
  final int? durationMs;

  /// For the screen reader, so "Play" is "Play Ladder Of Life".
  final String? title;

  @override
  Widget build(BuildContext context) {
    final now = NowPlaying.instance;
    if (storagePath.isEmpty) {
      return _Disc(
        size: size,
        color: AppColors.line,
        child: Icon(
          Icons.music_off_rounded,
          size: size * 0.42,
          color: AppColors.muted,
        ),
      );
    }

    return AnimatedBuilder(
      animation: now,
      builder: (context, _) {
        final mine = now.isCurrent(storagePath);
        final loading = mine && now.loading;
        final playing = mine && now.playing;
        final fraction = mine ? (now.fraction ?? 0) : 0.0;
        final label =
            '${playing ? 'Pause' : 'Play'}${title != null ? ' $title' : ''}';

        return Semantics(
          button: true,
          label: label,
          child: Tooltip(
            message: label,
            child: InkResponse(
              onTap: () => unawaited(now.toggle(
                storagePath,
                knownLength: durationMs != null
                    ? Duration(milliseconds: durationMs!)
                    : null,
              )),
              radius: size * 0.62,
              customBorder: const CircleBorder(),
              child: SizedBox(
                width: size,
                height: size,
                child: Stack(
                  alignment: Alignment.center,
                  children: <Widget>[
                    // How far through, only once this is the one playing.
                    if (mine)
                      SizedBox(
                        width: size,
                        height: size,
                        child: CustomPaint(
                          painter: _ProgressRing(fraction: fraction),
                        ),
                      ),
                    _Disc(
                      size: size * 0.82,
                      color: mine
                          ? AppColors.cyan
                          : AppColors.cyan.withValues(alpha: 0.14),
                      child: loading
                          ? SizedBox(
                              width: size * 0.34,
                              height: size * 0.34,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: mine ? AppColors.ink : AppColors.cyan,
                              ),
                            )
                          : Icon(
                              playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              size: size * 0.46,
                              color: mine ? AppColors.ink : AppColors.cyan,
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Disc extends StatelessWidget {
  const _Disc({required this.size, required this.color, required this.child});

  final double size;
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      child: child,
    );
  }
}

class _ProgressRing extends CustomPainter {
  const _ProgressRing({required this.fraction});

  final double fraction;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 1;
    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = AppColors.line,
    );
    if (fraction <= 0) return;
    canvas.drawArc(
      Rect.fromCircle(center: centre, radius: radius),
      -math.pi / 2,
      2 * math.pi * fraction.clamp(0.0, 1.0),
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..color = AppColors.cyan,
    );
  }

  @override
  bool shouldRepaint(_ProgressRing old) => old.fraction != fraction;
}
