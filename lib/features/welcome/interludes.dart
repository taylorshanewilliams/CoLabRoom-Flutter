import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';

/// The bit between the questions.
///
/// A first-run questionnaire is the least popular screen in any app, and the
/// reason is never the questions — five taps is nothing. It is that a form
/// announces itself as work, and work before you have seen the thing you came
/// for is work you decline.
///
/// So the answers are one tap each and the *space between them* is where the
/// app shows what it is. Drumsticks count you in. A handful of picks collide.
/// Notes fall down the screen. None of it explains anything, which is the
/// point: nobody reads an onboarding, but they will happily tap through one
/// that is enjoyable to look at.
///
/// All three are drawn, not animated assets — a `CustomPainter` and a
/// controller, nothing to download and nothing to keep in a pubspec.
enum Interlude {
  /// Two sticks swing in and click. The count-in before a take.
  sticks,

  /// A handful of picks collide mid-air and scatter.
  picks,

  /// Notes falling in columns.
  notes;

  /// The next one, so a flow never plays the same twice in a row.
  Interlude get next => switch (this) {
        Interlude.sticks => Interlude.picks,
        Interlude.picks => Interlude.notes,
        Interlude.notes => Interlude.sticks,
      };
}

/// Plays [kind] over whatever is on screen, swapping the content underneath at
/// the moment the screen is fully covered.
///
/// The swap goes through [onMidpoint] rather than being the caller's problem,
/// because the whole illusion depends on it happening while nobody can see.
class InterludeCurtain extends StatefulWidget {
  const InterludeCurtain({
    required this.kind,
    required this.onMidpoint,
    required this.onDone,
    super.key,
  });

  final Interlude kind;

  /// Called once, when the veil is at its most opaque.
  final VoidCallback onMidpoint;

  /// Called when there is nothing left to draw.
  final VoidCallback onDone;

  @override
  State<InterludeCurtain> createState() => _InterludeCurtainState();
}

class _InterludeCurtainState extends State<InterludeCurtain>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: switch (widget.kind) {
      // The sticks are a count-in and have to feel like one; hurrying them
      // makes the click land as a stumble.
      Interlude.sticks => const Duration(milliseconds: 1050),
      Interlude.picks => const Duration(milliseconds: 950),
      Interlude.notes => const Duration(milliseconds: 1100),
    },
  );

  bool _swapped = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      if (!_swapped && _controller.value >= 0.5) {
        _swapped = true;
        widget.onMidpoint();
      }
    });
    _controller.forward().whenComplete(() {
      // `whenComplete` fires even when the controller was disposed on the way,
      // and both callbacks reach into a widget that may be gone — which comes
      // back as "looking up a deactivated widget's ancestor is unsafe" from
      // somewhere with no obvious connection to this file.
      if (!mounted) return;
      // Belt and braces: a controller stopped mid-flight never reaches 1.0,
      // and a flow stuck behind a curtain is unrecoverable.
      if (!_swapped) widget.onMidpoint();
      widget.onDone();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => CustomPaint(
            painter: switch (widget.kind) {
              Interlude.sticks => _SticksPainter(_controller.value),
              Interlude.picks => _PicksPainter(_controller.value),
              Interlude.notes => _NotesPainter(_controller.value),
            },
            size: Size.infinite,
          ),
        ),
      ),
    );
  }
}

/// A parametric value a `Curve` will accept.
///
/// `Curves.transform` asserts `t >= 0 && t <= 1`, and every phase in this file
/// is a division that lands on 1.0000000000000002 at the end of its range.
/// Every interlude threw on its final frame — in debug only, which is the
/// worst place for it: invisible in a release build, and an exception during
/// paint on the machine of anybody testing it.
double _unit(double v) => v.clamp(0.0, 1.0);

/// How solid the veil is at [t] — up at the start, down at the end, and fully
/// opaque across the middle so the content swap is never glimpsed.
double _veil(double t) {
  if (t < 0.42) return Curves.easeIn.transform(_unit(t / 0.42));
  if (t < 0.58) return 1;
  return 1 - Curves.easeOut.transform(_unit((t - 0.58) / 0.42));
}

// ------------------------------------------------------------------- sticks

class _SticksPainter extends CustomPainter {
  _SticksPainter(this.t);

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final veil = _veil(t);
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = AppColors.ink.withValues(alpha: veil),
    );

    final centre = Offset(size.width / 2, size.height / 2);
    // Closing for the first half, withdrawing for the second, with the click
    // exactly on the boundary.
    final closing = t < 0.5;
    final phase = closing
        ? Curves.easeInCubic.transform(_unit(t / 0.5))
        : 1 - Curves.easeOutCubic.transform(_unit((t - 0.5) / 0.5));

    final travel = size.width * 0.42;
    final gap = (1 - phase) * travel + 8;

    _stick(canvas, centre.translate(-gap, 26), -0.34, veil);
    _stick(canvas, centre.translate(gap, 26), 0.34, veil);

    // The click, and everything that comes off it.
    if (!closing) {
      final since = _unit((t - 0.5) / 0.5);
      for (var i = 0; i < 3; i += 1) {
        final ring = (since - i * 0.12).clamp(0.0, 1.0);
        if (ring <= 0) continue;
        final eased = Curves.easeOutCubic.transform(ring);
        canvas.drawCircle(
          centre,
          eased * size.shortestSide * 0.55,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3.5 * (1 - eased)
            ..color = AppColors.cyan.withValues(alpha: (1 - eased) * veil),
        );
      }
      // Sparks, because a click is percussive and rings alone read as a
      // ripple in water.
      for (var i = 0; i < 8; i += 1) {
        final angle = (i / 8) * math.pi * 2 + 0.2;
        final reach = Curves.easeOutCubic.transform(since) * 78;
        final from = centre + Offset(math.cos(angle), math.sin(angle)) * 16;
        final to = centre + Offset(math.cos(angle), math.sin(angle)) * reach;
        canvas.drawLine(
          from,
          to,
          Paint()
            ..strokeWidth = 2
            ..strokeCap = StrokeCap.round
            ..color = AppColors.gold.withValues(alpha: (1 - since) * veil),
        );
      }
    }
  }

  /// One stick: a long tapered capsule with the bead on the inner end.
  void _stick(Canvas canvas, Offset tip, double lean, double alpha) {
    canvas.save();
    canvas.translate(tip.dx, tip.dy);
    canvas.rotate(lean);

    final wood = Paint()..color = const Color(0xFFD8B27A).withValues(alpha: alpha);
    final length = 132.0;
    final side = lean < 0 ? 1.0 : -1.0;

    // Taper: the shaft is wider at the butt than at the tip.
    final shaft = Path()
      ..moveTo(0, -4.5)
      ..lineTo(side * length, -7)
      ..lineTo(side * length, 7)
      ..lineTo(0, 4.5)
      ..close();
    canvas.drawPath(shaft, wood);
    canvas.drawCircle(Offset.zero, 6.5, wood);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SticksPainter old) => old.t != t;
}

// -------------------------------------------------------------------- picks

class _PicksPainter extends CustomPainter {
  _PicksPainter(this.t);

  final double t;

  static const int _count = 26;

  @override
  void paint(Canvas canvas, Size size) {
    final veil = _veil(t);
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = AppColors.deepNavy.withValues(alpha: veil),
    );

    final centre = Offset(size.width / 2, size.height / 2);
    final reach = size.longestSide * 0.62;
    // Deterministic, so the same interlude looks the same twice and a
    // screenshot of it means something.
    final random = math.Random(7);

    for (var i = 0; i < _count; i += 1) {
      final inbound = (i / _count) * math.pi * 2 + random.nextDouble() * 0.4;
      final outbound = inbound + math.pi + (random.nextDouble() - 0.5);
      final spin = (random.nextDouble() - 0.5) * 9;
      final colour = AppColors.memberPalette[i % AppColors.memberPalette.length];

      final double distance;
      final double fade;
      if (t < 0.54) {
        // In, fast, from off screen — arriving at 0.46 rather than 0.5, so
        // there is a moment where they are actually together. Sampled across
        // eight frames the collision previously fell in the gap between two
        // of them, which is a fair sign that it was too brief to read at
        // sixty frames a second either.
        final closing = Curves.easeInCubic.transform(_unit(t / 0.46));
        distance = reach * (1 - closing);
        fade = 1;
      } else {
        // Out, and deliberately not eased-out.
        //
        // `easeOutCubic` front-loads almost all of the travel into the first
        // fifth of the phase, so on the contact sheet the picks were simply
        // gone by the frame after the collision — half the interlude spent
        // showing an empty screen. A gentler curve keeps them in flight, and
        // the fade trails the distance rather than matching it so they are
        // still solid while they are still on screen.
        final flying = Curves.easeOutQuad.transform(_unit((t - 0.54) / 0.46));
        distance = reach * flying;
        fade = 1 - _unit(flying * 1.35 - 0.35);
      }
      final angle = t < 0.54 ? inbound : outbound;
      final at = centre + Offset(math.cos(angle), math.sin(angle)) * distance;

      canvas.save();
      canvas.translate(at.dx, at.dy);
      canvas.rotate(t * spin + i.toDouble());
      _pick(canvas, colour.withValues(alpha: fade * veil));
      canvas.restore();
    }

    // The moment of collision.
    //
    // A big soft disc read as a grey smudge rather than an impact. What
    // reads is a small hot core that dies quickly and a ring that carries
    // the energy outward — the same shape as the sticks' click, which is
    // what makes the three interludes feel like one family.
    if (t >= 0.46 && t <= 0.70) {
      final since = _unit((t - 0.46) / 0.24);
      canvas.drawCircle(
        centre,
        26 * (1 - since),
        Paint()..color = Colors.white.withValues(alpha: (1 - since) * veil),
      );
      final ring = Curves.easeOutCubic.transform(since);
      canvas.drawCircle(
        centre,
        20 + ring * size.shortestSide * 0.5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4 * (1 - ring)
          ..color = Colors.white.withValues(alpha: (1 - ring) * 0.8 * veil),
      );
    }
  }

  /// A plectrum: two shoulders and a point, all softened.
  void _pick(Canvas canvas, Color colour) {
    const w = 15.0;
    const h = 17.0;
    final path = Path()
      ..moveTo(0, h)
      ..quadraticBezierTo(-w * 0.95, h * 0.28, -w * 0.72, -h * 0.5)
      ..quadraticBezierTo(0, -h * 1.05, w * 0.72, -h * 0.5)
      ..quadraticBezierTo(w * 0.95, h * 0.28, 0, h)
      ..close();
    canvas.drawPath(path, Paint()..color = colour);
    // A highlight down one shoulder, so a flat fill reads as an object.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.white.withValues(alpha: colour.a * 0.35),
    );
  }

  @override
  bool shouldRepaint(_PicksPainter old) => old.t != t;
}

// -------------------------------------------------------------------- notes

class _NotesPainter extends CustomPainter {
  _NotesPainter(this.t);

  final double t;

  static const int _columns = 19;
  static const int _trail = 11;

  @override
  void paint(Canvas canvas, Size size) {
    final veil = _veil(t);
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = AppColors.ink.withValues(alpha: veil),
    );

    final random = math.Random(19);
    final columnWidth = size.width / _columns;

    for (var c = 0; c < _columns; c += 1) {
      final speed = 1.5 + random.nextDouble() * 1.6;
      final offset = random.nextDouble();
      final x = columnWidth * (c + 0.5);
      // Wraps, so a fast column keeps falling rather than leaving a gap —
      // and starts already part-way down, because a column that begins above
      // the screen leaves the left third of the first frames empty while it
      // catches up. The whole effect is only a second long; there is no time
      // for anything to be getting started.
      final head =
          ((t * speed + offset + 0.35) % 1.15) * (size.height + 300) - 150;

      for (var i = 0; i < _trail; i += 1) {
        final y = head - i * 34.0;
        if (y < -40 || y > size.height + 40) continue;
        final depth = i / _trail;
        final glyph = _glyphs[(c + i) % _glyphs.length];
        // The head is bright and the tail is not, which is the whole read of
        // a falling column: it has a direction.
        final colour = i == 0
            ? Colors.white
            : Color.lerp(AppColors.cyan, AppColors.blue, depth)!;
        _glyph(canvas, glyph, Offset(x, y),
            colour.withValues(alpha: (1 - depth) * veil),
            size: i == 0 ? 26 : 22);
      }
    }
  }

  static final List<int> _glyphs = <int>[
    Icons.music_note_rounded.codePoint,
    Icons.queue_music_rounded.codePoint,
    Icons.audiotrack_rounded.codePoint,
    Icons.graphic_eq_rounded.codePoint,
  ];

  void _glyph(Canvas canvas, int codePoint, Offset at, Color colour,
      {required double size}) {
    // The icon font rather than a musical Unicode character, because the
    // app already ships this one and ♪ is at the mercy of whatever the
    // device happens to have installed.
    final painter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(codePoint),
        style: TextStyle(
          fontSize: size,
          fontFamily: Icons.music_note_rounded.fontFamily,
          package: Icons.music_note_rounded.fontPackage,
          color: colour,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, at - Offset(painter.width / 2, painter.height / 2));
  }

  @override
  bool shouldRepaint(_NotesPainter old) => old.t != t;
}
