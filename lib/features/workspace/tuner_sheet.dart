import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:record/record.dart';

import '../../app/colabroom_theme.dart';
import '../../services/pitch.dart';
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
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _samples;
  final List<double> _buffer = <double>[];

  /// The last few readings, so one bad frame does not swing the needle.
  final List<PitchReading> _recent = <PitchReading>[];
  PitchReading? _shown;
  DateTime? _heardAt;
  Timer? _fade;
  String? _error;
  bool _listening = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_listen());
    });
    // A note that stopped a moment ago should not sit on screen as if it
    // were still sounding.
    _fade = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final heard = _heardAt;
      if (heard == null || !mounted) return;
      if (DateTime.now().difference(heard) > const Duration(milliseconds: 900) &&
          _shown != null) {
        setState(() {
          _shown = null;
          _recent.clear();
        });
      }
    });
  }

  @override
  void dispose() {
    _fade?.cancel();
    unawaited(_samples?.cancel());
    unawaited(_recorder.stop().catchError((_) => null));
    unawaited(_recorder.dispose());
    super.dispose();
  }

  Future<void> _listen() async {
    try {
      final Stream<Uint8List> stream;
      if (widget.openStream != null) {
        stream = await widget.openStream!();
      } else {
        if (!mounted) return;
        final allowed = await MicrophoneAccess.ensureGranted(
          context,
          purpose: 'to hear the note you are playing',
          request: _recorder.hasPermission,
        );
        if (!allowed) {
          throw StateError('The tuner needs the microphone to hear you.');
        }
        stream = await _recorder.startStream(const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: TunerSheet.sampleRate,
          numChannels: 1,
        ));
      }
      if (!mounted) return;
      setState(() => _listening = true);
      _samples = stream.listen(_onSamples, onError: (Object error) {
        if (mounted) {
          setState(() => _error = reportAndDescribe(error,
              service: 'app', stage: 'tuner.stream', route: 'Tuner'));
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() => _error = reportAndDescribe(error,
            service: 'app', stage: 'tuner.open', route: 'Tuner'));
      }
    }
  }

  void _onSamples(Uint8List bytes) {
    _buffer.addAll(pcm16ToFloats(bytes));
    while (_buffer.length >= TunerSheet.frame) {
      final frame = Float64List.fromList(_buffer.sublist(0, TunerSheet.frame));
      _buffer.removeRange(0, TunerSheet.hop);
      final reading = readPitch(detectPitch(frame, TunerSheet.sampleRate));
      if (reading == null) continue;
      _recent.add(reading);
      if (_recent.length > 3) _recent.removeAt(0);
      // The median of the last three: a string's attack is noisy for a
      // frame, and the needle should not flinch at it.
      final sorted = List<PitchReading>.of(_recent)
        ..sort((a, b) => a.hz.compareTo(b.hz));
      final middle = sorted[sorted.length ~/ 2];
      _heardAt = DateTime.now();
      if (mounted) setState(() => _shown = middle);
    }
    // Do not let a stalled detector hoard memory.
    if (_buffer.length > TunerSheet.frame * 4) {
      _buffer.removeRange(0, _buffer.length - TunerSheet.frame);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reading = _shown;
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
                      ? (_listening ? 'Play one string, or sing one note.' : 'Opening the microphone…')
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

/// Flat on the left, sharp on the right, a tick in the middle where the
/// note is. The needle is drawn, not animated to, because a tuner that
/// glides is a tuner that lies for a quarter of a second.
class _Needle extends StatelessWidget {
  const _Needle({required this.cents, required this.accent});

  final double? cents;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: CustomPaint(
        painter: _NeedlePainter(cents: cents, accent: accent),
        child: const SizedBox.expand(),
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
