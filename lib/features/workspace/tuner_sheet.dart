import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../services/pitch_listener.dart';
import '../../services/user_facing_error.dart';
import '../../widgets/microphone_disclosure.dart';

/// A tuner, on the sheet you record from.
///
/// The one thing every musician opens every day, and the reason a tuner
/// belongs here rather than in a toolbox: you tune *before* you record, on
/// the screen you are already standing on, and then you press the other
/// button. No account, no analysis, no server -- the phone's own ear.
///
/// The microphone is opened as a raw stream rather than a recording, four
/// thousand samples at a time, and each frame is asked one question by
/// `detectPitch`. Nothing is written anywhere.
class TunerSheet extends StatefulWidget {
  const TunerSheet({this.openStream, super.key});

  /// Where the samples come from. Production leaves this null and uses the
  /// microphone; a test hands in a sine wave.
  final Future<Stream<Uint8List>> Function()? openStream;

  static const int sampleRate = 44100;
  static const int frame = 4096;
  static const int hop = 2048;

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        backgroundColor: AppColors.deepNavy,
        isScrollControlled: true,
        builder: (_) => const TunerSheet(),
      );

  @override
  State<TunerSheet> createState() => _TunerSheetState();
}

class _TunerSheetState extends State<TunerSheet> {
  /// The phone's ear: the microphone, the detector and the smoothing, shared
  /// with Perform. See PitchListener.
  late final PitchListener _ear = PitchListener(
    openStream: widget.openStream,
    sampleRate: TunerSheet.sampleRate,
    frame: TunerSheet.frame,
    hop: TunerSheet.hop,
  );
  String? _error;

  @override
  void initState() {
    super.initState();
    _ear.reading.addListener(_changed);
    _ear.listening.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_listen());
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ear.reading.removeListener(_changed);
    _ear.listening.removeListener(_changed);
    _ear.dispose();
    super.dispose();
  }

  Future<void> _listen() async {
    try {
      await _ear.start(
        allowed: () => MicrophoneAccess.ensureGranted(
          context,
          purpose: 'to hear the note you are playing',
          request: _ear.hasPermission,
          use: MicrophoneUse.listen,
        ),
        onError: (Object error) {
          if (mounted) {
            setState(() => _error = reportAndDescribe(error,
                service: 'app', stage: 'tuner.stream', route: 'Tuner'));
          }
        },
      );
    } catch (error) {
      if (mounted) {
        setState(() => _error = reportAndDescribe(error,
            service: 'app', stage: 'tuner.open', route: 'Tuner'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final reading = _ear.reading.value;
    final listening = _ear.listening.value;
    final inTune = reading?.inTune ?? false;
    final accent = inTune ? AppColors.green : AppColors.gold;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Tuner',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: AppColors.text,
                    fontWeight: FontWeight.w900,
                  ),
            ),
            const SizedBox(height: 6),
            Text(
              _error ??
                  (reading == null
                      ? (listening ? 'Play one string, or sing one note.' : 'Opening the microphone…')
                      : inTune
                          ? 'In tune.'
                          : reading.cents < 0
                              ? 'A little flat — tighten.'
                              : 'A little sharp — loosen.'),
              key: const Key('tuner_hint'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _error != null ? const Color(0xFFFF9CAA) : AppColors.muted,
                fontSize: 12,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 26),
            // The note, large enough to read from where the guitar is.
            SizedBox(
              height: 96,
              child: Center(
                child: reading == null
                    ? Icon(Icons.hearing_rounded,
                        size: 44, color: AppColors.muted.withValues(alpha: 0.6))
                    : RichText(
                        key: const Key('tuner_note'),
                        text: TextSpan(
                          children: <InlineSpan>[
                            TextSpan(
                              text: reading.name,
                              style: TextStyle(
                                color: accent,
                                fontSize: 78,
                                fontWeight: FontWeight.w900,
                                height: 1,
                              ),
                            ),
                            TextSpan(
                              text: '${reading.octave}',
                              style: const TextStyle(
                                color: AppColors.muted,
                                fontSize: 26,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 14),
            _Needle(cents: reading?.cents, accent: accent),
            const SizedBox(height: 8),
            Text(
              reading == null
                  ? ' '
                  : '${reading.cents >= 0 ? '+' : ''}${reading.cents.round()} cents  ·  ${reading.hz.toStringAsFixed(1)} Hz',
              key: const Key('tuner_cents'),
              style: const TextStyle(
                color: AppColors.muted,
                fontSize: 12,
                fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Where the needle is, in words, in the four answers a tuner actually has.
///
/// Every Musician, Same Song, 17 September 2026: a tuner whose only answer is
/// a line on a track is a tuner nobody using a screen reader can tune with.
/// Said as a live region, because the interesting thing about this one is
/// that it keeps changing while the string is still ringing.
///
/// Coarse on purpose. PitchListener publishes a new median every hop -- 2048
/// frames at 44100 Hz, about twenty-one readings a second -- and a live
/// region announces every time its words change. Reading the exact cents
/// would interrupt itself twenty times a second and never finish a phrase,
/// which is worse than silence: you could not hear the string decaying under
/// it, let alone anything else on the sheet. Bands mean a ringing string
/// produces a handful of announcements, each of which gets said. The exact
/// number is still on screen for anyone who lands on it.
String needleReading(double? cents) {
  if (cents == null) return 'No note yet.';
  final off = cents.abs();
  // The same five cents PitchReading.inTune uses, so the words and the green
  // the needle turns never disagree.
  if (off <= 5) return 'In tune.';
  final way = cents < 0 ? 'flat' : 'sharp';
  if (off <= 15) return 'A little $way.';
  if (off <= 35) return 'Quite $way.';
  return 'Very $way.';
}

/// Flat on the left, sharp on the right, a tick in the middle where the
/// note is. The needle is drawn, not animated to, because a tuner that
/// glides is a tuner that lies for a quarter of a second.
class _Needle extends StatelessWidget {
  const _Needle({required this.cents, required this.accent});

  final double? cents;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: needleReading(cents),
      liveRegion: true,
      child: SizedBox(
        height: 44,
        child: CustomPaint(
          painter: _NeedlePainter(cents: cents, accent: accent),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _NeedlePainter extends CustomPainter {
  _NeedlePainter({required this.cents, required this.accent});

  final double? cents;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final midY = size.height / 2;
    final track = Paint()
      ..color = AppColors.line
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(8, midY), Offset(size.width - 8, midY), track);
    // Ticks every ten cents; the centre one taller.
    final tick = Paint()..color = AppColors.muted.withValues(alpha: 0.5)..strokeWidth = 1.5;
    for (var c = -50; c <= 50; c += 10) {
      final x = _x(c.toDouble(), size.width);
      final h = c == 0 ? 14.0 : 6.0;
      canvas.drawLine(Offset(x, midY - h), Offset(x, midY + h), tick);
    }
    // The in-tune band.
    final band = Paint()..color = AppColors.green.withValues(alpha: 0.18);
    canvas.drawRect(
      Rect.fromLTRB(_x(-5, size.width), midY - 12, _x(5, size.width), midY + 12),
      band,
    );
    final value = cents;
    if (value == null) return;
    final x = _x(value.clamp(-50, 50).toDouble(), size.width);
    final needle = Paint()
      ..color = accent
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(x, midY - 18), Offset(x, midY + 18), needle);
  }

  double _x(double cents, double width) => 8 + (cents + 50) / 100 * (width - 16);

  @override
  bool shouldRepaint(_NeedlePainter old) => old.cents != cents || old.accent != accent;
}
