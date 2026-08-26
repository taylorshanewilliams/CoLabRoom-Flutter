import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../services/multitrack.dart';
import '../../services/take_naming.dart';
import '../../widgets/player_face.dart';

/// One take on the timeline: who played it, and what it looks like.
///
/// This replaces the list row, and the difference is not decoration. A list
/// has nowhere for *time* to live — every take is the same width whether it
/// runs eight seconds or four minutes, and there is no place to put a
/// playhead. That is why scrubbing and punching in had nowhere to go: the
/// screen had no opinion about when anything happened.
///
/// Borrowed from a desk deliberately, and only so far. Time runs left to
/// right, the take is a lane, the waveform shows where the playing is. What
/// is *not* borrowed is everything that would make this an editor — the lane
/// cannot be dragged along the timeline, trimmed or faded. A take starts
/// where it was played and stays there, which is what keeps "whose lead is
/// that" answerable months later.
class TakeLane extends StatelessWidget {
  const TakeLane({
    required this.take,
    required this.onToggle,
    this.wave = const <double>[],
    this.playedFraction = 0,
    this.spansFraction = 1,
    this.silent = false,
    this.playerColor,
    this.playerPhoto,
    this.onDelete,
    this.onAdjust,
    this.subtitle,
    super.key,
  });

  final Take take;

  /// Peaks from [Multitrack.envelope], or empty while they are still being
  /// read. An empty lane draws a flat rule rather than nothing, so the row
  /// does not change height when the shape arrives.
  final List<double> wave;

  /// How far through the *song* the playhead is, 0..1.
  final double playedFraction;

  /// How much of the song's width this take occupies, 0..1.
  ///
  /// A forty-second harmony on a three-minute song is a short lane, not a
  /// full-width one — which is the fact a list could never show.
  final double spansFraction;

  final bool silent;
  final Color? playerColor;
  final Uint8List? playerPhoto;
  final VoidCallback onToggle;
  final VoidCallback? onDelete;

  /// Opens the take's own levels — volume and timing.
  ///
  /// Not on the lane itself. A fader per row is what the list did, and it is
  /// what left no width for a waveform; a desk keeps levels on the desk. But
  /// a phone in portrait is the common case, and rotating to change one
  /// volume is a poor trade — so the controls stay one tap away rather than
  /// one orientation away.
  final VoidCallback? onAdjust;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final name = TakeNaming.describe(take);
    final tint = playerColor ?? AppColors.cyan;
    final live = take.enabled && !silent;

    return Container(
      height: 78,
      padding: const EdgeInsets.fromLTRB(9, 8, 10, 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: silent
              ? AppColors.orange.withValues(alpha: 0.45)
              : take.enabled
                  ? tint.withValues(alpha: 0.30)
                  : AppColors.line,
        ),
      ),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 104,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    PlayerFace(
                      name: take.performer,
                      color: playerColor,
                      photo: playerPhoto,
                      size: 22,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: take.enabled ? AppColors.text : AppColors.muted,
                          fontSize: 10.5,
                          height: 1.15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
                Row(
                  children: <Widget>[
                    _LaneButton(
                      onTap: onToggle,
                      tooltip: take.enabled ? 'Mute $name' : 'Unmute $name',
                      background: take.enabled
                          ? tint.withValues(alpha: 0.16)
                          : AppColors.raised,
                      child: Icon(
                        take.enabled
                            ? Icons.volume_up_rounded
                            : Icons.volume_off_rounded,
                        size: 13,
                        color: take.enabled ? tint : AppColors.muted,
                      ),
                    ),
                    if (onAdjust != null) ...<Widget>[
                      const SizedBox(width: 4),
                      _LaneButton(
                        onTap: onAdjust!,
                        tooltip: 'Levels for $name',
                        background: AppColors.raised,
                        child: const Icon(Icons.tune_rounded,
                            size: 13, color: AppColors.muted),
                      ),
                    ],
                    if (onDelete != null) ...<Widget>[
                      const SizedBox(width: 4),
                      _LaneButton(
                        onTap: onDelete!,
                        tooltip: 'Delete $name',
                        background: AppColors.raised,
                        child: const Icon(Icons.delete_outline_rounded,
                            size: 13, color: Color(0xFFFF718B)),
                      ),
                    ],
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        silent ? 'silent' : (subtitle ?? _length),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color:
                              silent ? AppColors.orange : AppColors.muted,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: CustomPaint(
              size: Size.infinite,
              painter: _WavePainter(
                wave: wave,
                tint: live ? tint : AppColors.line,
                played: playedFraction,
                spans: spansFraction.clamp(0.02, 1.0),
                dim: live ? 0.28 : 0.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String get _length {
    final seconds = (take.durationMs / 1000).round();
    if (seconds <= 0) return '';
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}

class _LaneButton extends StatelessWidget {
  const _LaneButton({
    required this.onTap,
    required this.tooltip,
    required this.background,
    required this.child,
  });

  final VoidCallback onTap;
  final String tooltip;
  final Color background;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 26,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(6),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// The take's shape, lit behind the playhead and dimmed ahead of it.
class _WavePainter extends CustomPainter {
  const _WavePainter({
    required this.wave,
    required this.tint,
    required this.played,
    required this.spans,
    required this.dim,
  });

  final List<double> wave;
  final Color tint;
  final double played;
  final double spans;
  final double dim;

  @override
  void paint(Canvas canvas, Size size) {
    final laneWidth = size.width * spans;
    final middle = size.height / 2;

    if (wave.isEmpty) {
      // Still reading. A rule rather than nothing, so the lane does not
      // change shape when the waveform arrives.
      canvas.drawLine(
        Offset(0, middle),
        Offset(laneWidth, middle),
        Paint()
          ..color = tint.withValues(alpha: dim * 0.7)
          ..strokeWidth = 1.5,
      );
      return;
    }

    const gap = 1.0;
    final barWidth = math.max(1.0, (laneWidth - gap * wave.length) / wave.length);
    final lit = Paint()..color = tint;
    final unlit = Paint()..color = tint.withValues(alpha: dim);

    for (var i = 0; i < wave.length; i += 1) {
      final x = i * (barWidth + gap);
      if (x > laneWidth) break;
      // Square-rooted rather than linear. Peaks are absolute, so a quiet take
      // is genuinely shorter than a loud one — but linear would draw a
      // fingerpicked part as a flat line, and the point of a waveform is
      // seeing where the playing starts.
      final height = math.max(2.0, math.sqrt(wave[i]) * (size.height - 6));
      final playedThrough = (i + 0.5) / wave.length * spans < played;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, middle - height / 2, barWidth, height),
          const Radius.circular(1),
        ),
        playedThrough ? lit : unlit,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.played != played ||
      old.tint != tint ||
      old.spans != spans ||
      old.dim != dim ||
      !identical(old.wave, wave);
}
