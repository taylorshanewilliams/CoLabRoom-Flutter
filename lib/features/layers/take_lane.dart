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
    this.startsFraction = 0,
    this.spansFraction = 1,
    this.silent = false,
    this.playerColor,
    this.playerPhoto,
    this.onDelete,
    this.onAdjust,
    this.onShare,
    this.shareLabel = 'Share',
    this.subtitle,
    this.noteMarks = const <double>[],
    this.focusedMark,
    super.key,
  });

  final Take take;

  /// Peaks from [Multitrack.envelope], or empty while they are still being
  /// read. An empty lane draws a flat rule rather than nothing, so the row
  /// does not change height when the shape arrives.
  /// Offered only on a take of your own that the room has not heard.
  ///
  /// Its presence is the signal as much as its label: a lane with a Share
  /// button on it is one nobody else can hear yet, and a lane without one has
  /// either been shared or belongs to somebody else.
  final VoidCallback? onShare;

  /// What that button says. "Share" in a band room, and "Send to Ms. Rivera"
  /// in a lesson room, where sharing reaches exactly one person — see
  /// sending_a_take.dart, and Every Musician, Same Song, 17 September 2026.
  final String shareLabel;

  final List<double> wave;

  /// How far through the *song* the playhead is, 0..1.
  final double playedFraction;

  /// How far into the song this take begins, 0..1.
  ///
  /// A harmony punched in over the last chorus draws at the right-hand end of
  /// the lane, where it was played, rather than at the left with everything
  /// else. Seeing that is most of why the timeline is worth having.
  final double startsFraction;

  /// How much of the song's width this take occupies, 0..1.
  ///
  /// A forty-second harmony on a three-minute song is a short lane, not a
  /// full-width one — which is the fact a list could never show.
  final double spansFraction;

  /// Where the notes pinned to this take are, 0..1 through the *song* — the
  /// same measure as [playedFraction], so a mark sits under the playhead
  /// when the playhead reaches it.
  ///
  /// Drawn on the lane rather than listed only underneath, because the thing
  /// worth seeing at a glance is that the notes cluster in the last chorus.
  final List<double> noteMarks;

  /// The one being played, drawn taller so the row and the lane agree about
  /// which note is open.
  final double? focusedMark;

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
                        silent
                            ? 'silent'
                            : (onShare != null
                                ? 'only you'
                                : (subtitle ?? _length)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: silent
                              ? AppColors.orange
                              : (onShare != null
                                  ? AppColors.cyan
                                  : AppColors.muted),
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
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: Semantics(
                    label: _whenItPlays,
                    image: true,
                    child: CustomPaint(
                      size: Size.infinite,
                      painter: _WavePainter(
                        wave: wave,
                        tint: live ? tint : AppColors.line,
                        played: playedFraction,
                        starts: startsFraction.clamp(0.0, 0.98),
                        spans: spansFraction.clamp(0.02, 1.0),
                        dim: live ? 0.28 : 0.5,
                        notes: noteMarks,
                        focused: focusedMark,
                      ),
                    ),
                  ),
                ),
                // Said in the lane rather than only in a menu. Somebody
                // deciding whether to record again needs to know at a
                // glance that nobody has heard the last one — the whole
                // value of a private take is knowing it is private.
                //
                // Over the waveform rather than in the column of buttons on
                // the left, which is 104 pixels wide and was already 52
                // pixels short of holding mute, levels, delete and a word:
                // the lane overflowed on every take of your own that nobody
                // had heard, which is every take at the moment it matters.
                // A name makes that worse — "Send to Ms. Rivera" is four
                // times the width of "Share" — and there is room here. The
                // waveform keeps its full width, so every lane still draws
                // against the same clock, which is the one thing about this
                // view that must not bend.
                if (onShare != null)
                  Positioned.fill(
                    // Filled rather than pinned to the right edge, so the
                    // button is bounded by the lane it sits in. On the desk
                    // panel this area can be narrow, and a name too long for
                    // it should shorten rather than run off the end.
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 140),
                        child: TextButton(
                          onPressed: onShare,
                          style: TextButton.styleFrom(
                            foregroundColor: AppColors.cyan,
                            backgroundColor: AppColors.raised,
                            padding:
                                const EdgeInsets.symmetric(horizontal: 10),
                            minimumSize: const Size(0, 28),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                              side: BorderSide(
                                color: AppColors.cyan.withValues(alpha: 0.35),
                              ),
                            ),
                          ),
                          child: Text(
                            shareLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
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

  /// Where in the song this take sits, in words.
  ///
  /// Every Musician, Same Song, 17 September 2026: the lane's whole reason to
  /// exist is that a list "has nowhere for time to live", and that fact was
  /// painted and nowhere else — the row says who played it and how long it
  /// runs, and nothing at all says a harmony covers only the last chorus. To
  /// a screen reader the lane was a blank rectangle. The shape of the
  /// waveform itself is not described, because a peak is not information.
  String get _whenItPlays {
    final from = startsFraction.clamp(0.0, 1.0);
    final to = (from + spansFraction).clamp(0.0, 1.0);
    if (from <= 0.05 && to >= 0.95) return 'Plays right through the song.';
    final start = _placeInSong(from);
    final end = _placeInSong(to);
    // A nine-second punch-in starts and ends in the same place, as far as
    // these words can tell, and "from halfway to halfway" is a sentence
    // nobody should have to listen to. "Near" is already an "around", so it
    // does not get a second one.
    if (start == end) {
      return start.startsWith('near') ? 'Plays $start.' : 'Plays around $start.';
    }
    return 'Plays from $start to $end.';
  }

  static String _placeInSong(double at) {
    if (at <= 0.05) return 'the start';
    if (at < 0.2) return 'near the start';
    if (at < 0.4) return 'a quarter of the way in';
    if (at < 0.6) return 'halfway';
    if (at < 0.8) return 'three quarters of the way in';
    if (at < 0.95) return 'near the end';
    return 'the end';
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
    required this.starts,
    required this.spans,
    required this.dim,
    this.notes = const <double>[],
    this.focused,
  });

  final List<double> wave;
  final Color tint;
  final double played;
  final double starts;
  final double spans;
  final double dim;
  final List<double> notes;
  final double? focused;

  @override
  void paint(Canvas canvas, Size size) {
    final left = size.width * starts;
    final laneWidth = math.min(size.width - left, size.width * spans);
    final middle = size.height / 2;

    _paintNotes(canvas, size);

    if (wave.isEmpty) {
      // Still reading. A rule rather than nothing, so the lane does not
      // change shape when the waveform arrives.
      canvas.drawLine(
        Offset(left, middle),
        Offset(left + laneWidth, middle),
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
      final x = left + i * (barWidth + gap);
      if (x > left + laneWidth) break;
      // Square-rooted rather than linear. Peaks are absolute, so a quiet take
      // is genuinely shorter than a loud one — but linear would draw a
      // fingerpicked part as a flat line, and the point of a waveform is
      // seeing where the playing starts.
      final height = math.max(2.0, math.sqrt(wave[i]) * (size.height - 6));
      final playedThrough =
          starts + (i + 0.5) / wave.length * spans < played;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, middle - height / 2, barWidth, height),
          const Radius.circular(1),
        ),
        playedThrough ? lit : unlit,
      );
    }
  }

  /// A short gold tick at every pinned moment, floor to ceiling of the lane.
  ///
  /// Under the waveform rather than over it: a note marks where in the
  /// playing something happens, and covering the playing to say so would be
  /// the wrong way round.
  void _paintNotes(Canvas canvas, Size size) {
    if (notes.isEmpty) return;
    final mark = Paint()..color = AppColors.gold.withValues(alpha: 0.5);
    final lit = Paint()..color = AppColors.gold;
    for (final at in notes) {
      final x = size.width * at.clamp(0.0, 1.0);
      final open = focused != null && (focused! - at).abs() < 0.0005;
      canvas.drawRect(
        Rect.fromLTWH(x - 1, open ? 0 : size.height * 0.22, 2,
            open ? size.height : size.height * 0.56),
        open ? lit : mark,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.played != played ||
      old.tint != tint ||
      old.starts != starts ||
      old.spans != spans ||
      old.dim != dim ||
      old.focused != focused ||
      !identical(old.notes, notes) ||
      !identical(old.wave, wave);
}
