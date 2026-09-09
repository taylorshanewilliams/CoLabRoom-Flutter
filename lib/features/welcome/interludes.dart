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
/// A row of channel meters climbs until it clips. Notes fall down the screen. None of it explains anything, which is the
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

  /// Channel meters climbing until they clip.
  meters,

  /// Notes falling in columns.
  notes;

  /// The next one, so a flow never plays the same twice in a row.
  Interlude get next => switch (this) {
        Interlude.sticks => Interlude.picks,
        Interlude.picks => Interlude.meters,
        Interlude.meters => Interlude.notes,
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
      // Longer, because a meter has to be watched rather than glanced at.
      // The whole point of it is the climb.
      Interlude.meters => const Duration(milliseconds: 2100),
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
              Interlude.meters => _MetersPainter(_controller.value),
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

    final travel = size.width * 0.42;

    /// How far apart the sticks are at [at].
    ///
    /// A function of time rather than a value, because the trails need the
    /// same answer for a moment that has already passed — and two ghosts a
    /// frame behind is most of what makes this read as a swing rather than a
    /// diagram of one.
    ///
    /// easeInOut rather than easeIn: the acceleration into the middle was the
    /// part that read as a lurch.
    double gapAt(double at) {
      final closingThen = at < 0.5;
      final phaseThen = closingThen
          ? Curves.easeInOutCubic.transform(_unit(at / 0.5))
          : 1 - Curves.easeInOutCubic.transform(_unit((at - 0.5) / 0.5));
      return (1 - phaseThen) * travel + 8;
    }

    final gap = gapAt(t);

    // Trails, which is most of what makes this read as a hit rather than a
    // diagram. Two ghosts a frame or two behind, faint, and the sticks stop
    // looking like they are being placed and start looking like they are
    // being swung.
    for (final behind in const <double>[0.055, 0.028]) {
      final ghostGap = gapAt(_unit(t - behind));
      final ghostAlpha = veil * (behind > 0.04 ? 0.13 : 0.24);
      _stick(canvas, centre.translate(-ghostGap, 26), -0.34, ghostAlpha);
      _stick(canvas, centre.translate(ghostGap, 26), 0.34, ghostAlpha);
    }

    _stick(canvas, centre.translate(-gap, 26), -0.34, veil);
    _stick(canvas, centre.translate(gap, 26), 0.34, veil);

    // The click, and everything that comes off it.
    if (!closing) {
      final since = _unit((t - 0.5) / 0.5);

      // The flash. Two frames of white, gone before anybody registers it as a
      // shape — which is exactly why the hit lands. Rings alone read as a
      // ripple in water; this reads as something being struck.
      if (since < 0.16) {
        final flash = 1 - since / 0.16;
        canvas.drawCircle(
          centre,
          18 + (1 - flash) * 40,
          Paint()
            ..color = Colors.white.withValues(alpha: flash * 0.9 * veil)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, 10 + flash * 26),
        );
      }

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
      // Sparks. Longer, more of them, and uneven — a ring of eight identical
      // spokes is a diagram of an impact rather than one.
      final sparks = math.Random(31);
      for (var i = 0; i < 16; i += 1) {
        final angle = (i / 16) * math.pi * 2 + sparks.nextDouble() * 0.5;
        final length = 60 + sparks.nextDouble() * 110;
        final reach = Curves.easeOutCubic.transform(since) * length;
        final direction = Offset(math.cos(angle), math.sin(angle));
        final from = centre + direction * (12 + reach * 0.55);
        final to = centre + direction * reach;
        canvas.drawLine(
          from,
          to,
          Paint()
            // Tapering: a spark that keeps its width all the way out is a
            // line, and lines are not sparks.
            ..strokeWidth = 2.6 * (1 - since)
            ..strokeCap = StrokeCap.round
            ..color = Color.lerp(Colors.white, AppColors.gold, since)!
                .withValues(alpha: (1 - since) * (1 - since) * veil),
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
    // Worn hickory rather than pale maple. The light version looked like a
    // toy drumstick from a gift shop; a stick somebody actually plays with is
    // darker, and the contrast between the lit edge and the shaded underside
    // is what sells it.
    const pale = Color(0xFFE0BC86);
    const wood = Color(0xFFA8794A);
    const shade = Color(0xFF5E4023);

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

  /// What picks are made of.
  ///
  /// Lit face and shaded face for each. Weighted by repetition rather than by
  /// a random roll, so the mix is the same every time and the bright ones stay
  /// occasional: five neutrals to two brights.
  static const List<List<Color>> _materials = <List<Color>>[
    <Color>[Color(0xFFF0E7D3), Color(0xFFB2A48C)], // cream celluloid
    <Color>[Color(0xFFCE8F42), Color(0xFF6B3F16)], // tortoiseshell
    <Color>[Color(0xFF3B3F49), Color(0xFF15181F)], // black
    <Color>[Color(0xFFF0E7D3), Color(0xFFB2A48C)], // cream again
    <Color>[Color(0xFF6E7788), Color(0xFF2A303B)], // graphite
    <Color>[Color(0xFFCE8F42), Color(0xFF6B3F16)], // tortoiseshell again
    <Color>[Color(0xFFE3B34D), Color(0xFF8A6420)], // the app's gold
    <Color>[Color(0xFF9FDCF2), Color(0xFF3E6E85)], // pearl, tinted to brand
  ];

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
      final inbound = (i / _count) * math.pi * 2 + random.nextDouble() * 0.75;
      // Each one arrives on its own beat.
      //
      // The tidy ring was the cheesiest thing here: twenty-six picks leaving
      // at the same instant, travelling the same distance, arriving together.
      // Nothing thrown by hand does that. A per-pick head start of up to a
      // tenth of the run breaks the circle into a scatter without changing
      // anything about where they end up.
      final early = random.nextDouble() * 0.11;
      final ownTime = _unit(t + early);
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
      final material = _materials[i % _materials.length];

      final double distance;
      final double fade;
      if (ownTime < 0.54) {
        // In, fast, from off screen — arriving at 0.46 rather than 0.5, so
        // there is a moment where they are actually together. Sampled across
        // eight frames the collision previously fell in the gap between two
        // of them, which is a fair sign that it was too brief to read at
        // sixty frames a second either.
        final closing =
            Curves.easeInOutCubic.transform(_unit(ownTime / 0.46));
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
        final flying =
            Curves.easeOutQuad.transform(_unit((ownTime - 0.54) / 0.46));
        distance = huddle + (reach - huddle) * flying;
        // Held solid for most of the flight and dropped at the end. Fading in
        // step with the distance meant they were ghosts by the time they were
        // halfway out, and the second half of the interlude was an empty
        // screen with a veil over it.
        fade = 1 - _unit((flying - 0.55) / 0.45);
      }
      final angle = ownTime < 0.54 ? inbound : outbound;
      final at = centre + Offset(math.cos(angle), math.sin(angle)) * distance;

      canvas.save();
      canvas.translate(at.dx, at.dy);
      canvas.rotate(ownTime * spin * 1.7 + i.toDouble());
      _pick(canvas, material, fade * veil, scale);
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

  /// A plectrum, in something a pick is actually made of.
  ///
  /// This was drawn in `AppColors.memberPalette`, which was lazy in a way that
  /// showed: that palette is the *collaborator identity* set — ten bright
  /// hues chosen so two people writing on the same line never share a colour.
  /// Borrowing it for decoration produced confetti, which belongs to a
  /// different app than this one.
  ///
  /// These are the materials picks come in. Tortoiseshell, cream celluloid,
  /// black and graphite carry it, with the app's own gold and a brand-tinted
  /// pearl as the occasional bright one — so a handful reads as something
  /// tipped out of a case rather than a party.
  ///
  /// The shape is the standard 351: a broad rounded top, sides tapering in,
  /// and a tip with a real radius on it. The previous outline was three
  /// quadratics and read as a rounded triangle, which is the shape people
  /// draw when they have not looked at a pick recently.
  void _pick(Canvas canvas, List<Color> material, double alpha, double scale) {
    final w = 15.5 * scale;
    final h = 16.5 * scale;

    final path = Path()
      ..moveTo(0, h)
      // Down the left side and up to the shoulder.
      ..cubicTo(-w * 0.52, h * 0.62, -w * 0.99, -h * 0.08, -w * 0.66, -h * 0.62)
      // Over the top.
      ..cubicTo(-w * 0.34, -h * 1.02, w * 0.34, -h * 1.02, w * 0.66, -h * 0.62)
      // And back down to the tip.
      ..cubicTo(w * 0.99, -h * 0.08, w * 0.52, h * 0.62, 0, h)
      ..close();

    final lit = material[0].withValues(alpha: alpha);
    final deep = material[1].withValues(alpha: alpha);

    canvas.drawPath(
      path,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(-w * 0.7, -h * 0.9),
          Offset(w * 0.7, h * 0.9),
          <Color>[lit, Color.lerp(lit, deep, 0.55)!, deep],
          <double>[0, 0.5, 1],
        ),
    );

    // A bevel on the lit shoulder only. A stroke all the way round is an
    // outline; a stroke on one side is an edge catching the light — and it is
    // the only thing that keeps a near-black pick visible on a navy screen.
    final rim = Path()
      ..moveTo(-w * 0.66, -h * 0.62)
      ..cubicTo(-w * 0.34, -h * 1.02, w * 0.34, -h * 1.02, w * 0.66, -h * 0.62);
    canvas.drawPath(
      rim,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 * scale
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withValues(alpha: alpha * 0.5),
    );

    // Celluloid is glossy. One soft highlight sitting on the surface rather
    // than on the outline is what says so.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(-w * 0.2, -h * 0.4),
        width: w * 0.4,
        height: h * 0.24,
      ),
      Paint()
        ..color = Colors.white.withValues(alpha: alpha * 0.3)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.6),
    );
  }

  @override
  bool shouldRepaint(_PicksPainter old) => old.t != t;
}

// ------------------------------------------------------------------- meters

/// A row of channel meters, climbing until they clip.
///
/// The only one of these four that is a picture of the app's own subject.
/// Sticks and picks and falling notes say "music" in general; a desk with the
/// levels moving says *this* — takes, layers, somebody riding a fader while
/// three other people play.
///
/// Everything here is the honest anatomy of a meter, because the details are
/// what makes one recognisable at a glance:
///
///   * **Segments, not a bar.** A smooth gradient is a progress indicator. A
///     stack of lit blocks with dark gaps between them is a meter.
///   * **Green, amber, red, in that order and at those proportions.** The
///     colour tells you how close you are to trouble, and putting the red
///     anywhere but the last fifth makes it decoration.
///   * **Peak hold.** The single bright segment that hangs above the level
///     and sinks slowly is the thing every real meter does and no drawing of
///     one ever remembers. It is also what gives the eye something to track
///     while the level itself is flickering.
///   * **Unlit segments stay visible.** A meter you can only see the lit part
///     of is a bar chart; the dark stack is what shows you the headroom.
class _MetersPainter extends CustomPainter {
  _MetersPainter(this.t);

  final double t;

  static const int _channels = 11;
  static const int _segments = 20;

  /// Where the colour changes, as a fraction of the stack.
  static const double _amberFrom = 0.62;
  static const double _redFrom = 0.84;

  static const Color _red = Color(0xFFFF6B6B);

  @override
  void paint(Canvas canvas, Size size) {
    final veil = _veil(t);
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = AppColors.ink.withValues(alpha: veil),
    );

    final stackTop = size.height * 0.24;
    final stackBottom = size.height * 0.76;
    final stackHeight = stackBottom - stackTop;
    final pitch = stackHeight / _segments;
    final segmentHeight = pitch * 0.62;

    final channelPitch = size.width / (_channels + 1);
    final barWidth = math.min(channelPitch * 0.52, 26.0);

    for (var c = 0; c < _channels; c += 1) {
      final x = channelPitch * (c + 1);
      final level = _levelAt(c, t);
      final peak = _peakAt(c, t);

      for (var i = 0; i < _segments; i += 1) {
        final position = i / (_segments - 1);
        final lit = position <= level;
        final isPeak = (peak * (_segments - 1)).round() == i && peak > 0.02;
        if (!lit && !isPeak) {
          // The dark stack. Without it there is no headroom to read.
          _segment(canvas, x, stackBottom - i * pitch, barWidth, segmentHeight,
              _colourAt(position).withValues(alpha: 0.10 * veil));
          continue;
        }
        final colour = _colourAt(position);
        _segment(canvas, x, stackBottom - i * pitch, barWidth, segmentHeight,
            colour.withValues(alpha: (isPeak && !lit ? 0.85 : 1) * veil),
            glow: position >= _redFrom && lit);
      }
    }
  }

  Color _colourAt(double position) {
    if (position >= _redFrom) return _red;
    if (position >= _amberFrom) {
      final into = (position - _amberFrom) / (_redFrom - _amberFrom);
      return Color.lerp(AppColors.gold, AppColors.orange, into)!;
    }
    return Color.lerp(
      AppColors.green,
      AppColors.gold,
      (position / _amberFrom) * 0.55,
    )!;
  }

  void _segment(Canvas canvas, double x, double y, double width, double height,
      Color colour,
      {bool glow = false}) {
    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(x, y), width: width, height: height),
      const Radius.circular(2),
    );
    if (glow) {
      canvas.drawRRect(
        rect,
        Paint()
          ..color = colour.withValues(alpha: colour.a * 0.7)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
      );
    }
    canvas.drawRRect(rect, Paint()..color = colour);
  }

  /// How loud channel [c] is at [at].
  ///
  /// An envelope over the whole interlude so the desk arrives, peaks and
  /// falls away — the loudest moment lands on the midpoint, which is also
  /// when the screen is fully covered and the question underneath changes.
  ///
  /// Two sine components per channel at unrelated rates, so no two channels
  /// move together and none of them is periodic enough to look like a
  /// waveform. Music does not, and a meter that pulses in time reads as a
  /// loading animation.
  static double _levelAt(int c, double at) {
    if (at <= 0) return 0;
    final seed = math.Random(c * 7919 + 11);
    final rate1 = 5.5 + seed.nextDouble() * 6;
    final rate2 = 12.0 + seed.nextDouble() * 14;
    final phase = seed.nextDouble() * math.pi * 2;
    final ceiling = 0.78 + seed.nextDouble() * 0.42;

    final envelope = math.sin(_unit(at) * math.pi);
    final wobble = 0.66 +
        0.24 * math.sin(at * rate1 + phase) +
        0.10 * math.sin(at * rate2 + phase * 1.7);
    return _unit(envelope * wobble * ceiling * 1.45);
  }

  /// The peak-hold marker: the highest level recently, sinking slowly.
  ///
  /// Sampled backwards rather than remembered, because a painter has no
  /// memory between frames — and a fixed decay per step is exactly what the
  /// hardware does anyway.
  static double _peakAt(int c, double at) {
    var peak = 0.0;
    for (var k = 0; k <= 14; k += 1) {
      final back = at - k * 0.025;
      if (back < 0) break;
      final decayed = _levelAt(c, back) - k * 0.014;
      if (decayed > peak) peak = decayed;
    }
    return peak;
  }

  @override
  bool shouldRepaint(_MetersPainter old) => old.t != t;
}

// -------------------------------------------------------------------- notes

class _NotesPainter extends CustomPainter {
  _NotesPainter(this.t);

  final double t;

  // Denser than it was, twice.
  //
  // "Could use more notes falling" — and the fix is columns rather than speed.
  // A faster fall reads as fewer things moving quicker; more columns with
  // longer tails is what makes it look like weather.
  static const int _columns = 27;
  static const int _trail = 15;

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
      final speed = 1.35 + random.nextDouble() * 1.9;
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
        final y = head - i * 29.0;
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
