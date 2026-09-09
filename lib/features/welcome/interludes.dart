import 'dart:math' as math;
import 'dart:ui' as ui;

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
    // Slower than they were, by about two thirds.
    //
    // The first pass moved at the speed that looked right in a still frame,
    // which is not the speed that feels right on a screen thirty centimetres
    // from somebody's face. Fast motion across a whole viewport is the exact
    // recipe for making a person queasy, and an interlude nobody can watch
    // comfortably is worse than no interlude — it is a thing they will start
    // skipping, and the questions go with it.
    duration: switch (widget.kind) {
      // A count-in has a tempo. This one is about 70bpm: slow enough to read
      // as deliberate, quick enough that it is still a count-in and not a
      // pause.
      Interlude.sticks => const Duration(milliseconds: 1750),
      Interlude.picks => const Duration(milliseconds: 1600),
      Interlude.notes => const Duration(milliseconds: 1900),
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
    // easeInOut rather than easeIn: the sticks swing rather than snap, and
    // the acceleration into the middle was the part that read as a lurch.
    final phase = closing
        ? Curves.easeInOutCubic.transform(_unit(t / 0.5))
        : 1 - Curves.easeInOutCubic.transform(_unit((t - 0.5) / 0.5));

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

  /// One stick: a tapered shaft, a bead, and light coming from above.
  ///
  /// A flat fill reads as a shape rather than an object. What makes a drawn
  /// stick look like wood is that it is lit: brighter along the top edge,
  /// darker underneath, with a soft shadow beneath it and no hard corners
  /// anywhere.
  void _stick(Canvas canvas, Offset tip, double lean, double alpha) {
    canvas.save();
    canvas.translate(tip.dx, tip.dy);
    canvas.rotate(lean);

    const length = 138.0;
    final side = lean < 0 ? 1.0 : -1.0;
    const pale = Color(0xFFEBCB9C);
    const wood = Color(0xFFCEA470);
    const shade = Color(0xFF9C7443);

    // Taper: wider at the butt than at the tip.
    final shaft = Path()
      ..moveTo(0, -4.8)
      ..lineTo(side * length, -7.4)
      ..lineTo(side * length, 7.4)
      ..lineTo(0, 4.8)
      ..close();

    // Underneath first, so the stick sits on something.
    canvas.drawPath(
      shaft.shift(const Offset(0, 5)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.35 * alpha)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );

    canvas.drawPath(
      shaft,
      Paint()
        ..shader = ui.Gradient.linear(
          const Offset(0, -8),
          const Offset(0, 8),
          <Color>[
            pale.withValues(alpha: alpha),
            wood.withValues(alpha: alpha),
            shade.withValues(alpha: alpha),
          ],
          <double>[0, 0.45, 1],
        ),
    );
    // The specular line along the top edge — one stroke, and the whole thing
    // stops being a polygon.
    canvas.drawLine(
      Offset(side * 6, -4.2),
      Offset(side * (length - 6), -6.4),
      Paint()
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withValues(alpha: 0.32 * alpha),
    );

    canvas.drawCircle(
      Offset.zero,
      7,
      Paint()
        ..shader = ui.Gradient.radial(
          const Offset(-2.5, -2.5),
          9,
          <Color>[
            pale.withValues(alpha: alpha),
            shade.withValues(alpha: alpha),
          ],
        ),
    );
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
      // A handful thrown by hand are not all the same size.
      final scale = 0.78 + random.nextDouble() * 0.5;
      // Where this one ends up at the moment of impact.
      //
      // Without it every pick converges on the exact centre and twenty-six of
      // them stack into a single dot — which is what the contact sheet showed
      // and it read as one small blob rather than a collision. A handful of
      // pixels of huddle, different for each, and the same instant becomes a
      // tight rosette of picks touching.
      final huddle = 17 + random.nextDouble() * 15;
      final colour = AppColors.memberPalette[i % AppColors.memberPalette.length];

      final double distance;
      final double fade;
      if (t < 0.54) {
        // In, fast, from off screen — arriving at 0.46 rather than 0.5, so
        // there is a moment where they are actually together. Sampled across
        // eight frames the collision previously fell in the gap between two
        // of them, which is a fair sign that it was too brief to read at
        // sixty frames a second either.
        final closing = Curves.easeInOutCubic.transform(_unit(t / 0.46));
        distance = reach * (1 - closing) + huddle * closing;
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
        distance = huddle + (reach - huddle) * flying;
        // Held solid for most of the flight and dropped at the end. Fading in
        // step with the distance meant they were ghosts by the time they were
        // halfway out, and the second half of the interlude was an empty
        // screen with a veil over it.
        fade = 1 - _unit((flying - 0.55) / 0.45);
      }
      final angle = t < 0.54 ? inbound : outbound;
      final at = centre + Offset(math.cos(angle), math.sin(angle)) * distance;

      canvas.save();
      canvas.translate(at.dx, at.dy);
      canvas.rotate(t * spin + i.toDouble());
      _pick(canvas, colour.withValues(alpha: fade * veil), scale);
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

  /// A plectrum: two shoulders and a point, lit from the top left.
  ///
  /// Celluloid is glossy, and gloss is the whole reason a pick reads as a
  /// pick rather than a coloured triangle. Three things do it: a gradient
  /// across the body, a bright edge on the lit side only, and a small
  /// highlight sitting on the surface rather than on the outline.
  void _pick(Canvas canvas, Color colour, double scale) {
    final w = 15.0 * scale;
    final h = 17.0 * scale;
    final path = Path()
      ..moveTo(0, h)
      ..quadraticBezierTo(-w * 0.95, h * 0.28, -w * 0.72, -h * 0.5)
      ..quadraticBezierTo(0, -h * 1.05, w * 0.72, -h * 0.5)
      ..quadraticBezierTo(w * 0.95, h * 0.28, 0, h)
      ..close();

    final lit = Color.lerp(colour, Colors.white, 0.35)!
        .withValues(alpha: colour.a);
    final deep = Color.lerp(colour, const Color(0xFF06101F), 0.35)!
        .withValues(alpha: colour.a);

    canvas.drawPath(
      path,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(-w * 0.6, -h * 0.8),
          Offset(w * 0.6, h * 0.8),
          <Color>[lit, colour, deep],
          <double>[0, 0.45, 1],
        ),
    );
    // Bright on the lit shoulder, nothing on the shaded one. A stroke all the
    // way round is an outline; a stroke on one side is a bevel.
    final rim = Path()
      ..moveTo(-w * 0.72, -h * 0.5)
      ..quadraticBezierTo(0, -h * 1.05, w * 0.72, -h * 0.5);
    canvas.drawPath(
      rim,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4 * scale
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withValues(alpha: colour.a * 0.55),
    );
    canvas.drawOval(
      Rect.fromCenter(
          center: Offset(-w * 0.22, -h * 0.34),
          width: w * 0.34,
          height: h * 0.22),
      Paint()..color = Colors.white.withValues(alpha: colour.a * 0.4),
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
        // The head carries a glow. It is the only part of a falling column
        // the eye actually tracks, and without it the whole thing reads as a
        // list of icons rather than something moving.
        if (i == 0) {
          _glyph(canvas, glyph, Offset(x, y),
              AppColors.cyan.withValues(alpha: 0.55 * veil),
              size: 30, blur: 9);
        }
        _glyph(canvas, glyph, Offset(x, y),
            colour.withValues(alpha: (1 - depth) * veil),
            size: i == 0 ? 26 : 21.5);
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
      {required double size, double blur = 0}) {
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
          shadows: blur == 0
              ? null
              : <Shadow>[Shadow(color: colour, blurRadius: blur)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, at - Offset(painter.width / 2, painter.height / 2));
  }

  @override
  bool shouldRepaint(_NotesPainter old) => old.t != t;
}
