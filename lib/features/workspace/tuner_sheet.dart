import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../services/drone_player.dart';
import '../../services/horn_reading.dart';
import '../../services/pitch.dart';
import '../../services/pitch_listener.dart';
import '../../services/user_facing_error.dart';
import '../../widgets/microphone_disclosure.dart';
import 'drone_controls.dart';
import 'tuner_reference_store.dart';

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
  const TunerSheet({
    this.openStream,
    this.reading = HornReading.concert,
    this.songKey,
    this.drone,
    super.key,
  });

  /// Where the samples come from. Production leaves this null and uses the
  /// microphone; a test hands in a sine wave.
  final Future<Stream<Uint8List>> Function()? openStream;

  /// The instrument this person reads the song for, when the tuner was opened
  /// from a song that knows. It only offers a second way of naming the note
  /// that is sounding; the microphone hears concert pitch either way.
  final HornReading reading;

  /// The key of the song the tuner was opened from, when there is one: what
  /// the band said, or what the analysis heard. The drone below offers its 1
  /// first. Null leaves the drone asking which note to hold, which is the
  /// honest answer for a song nobody has named a key for.
  ///
  /// The sounding key, never a reading of it. A capo, a transpose and a horn's
  /// written part are each person's own and none of them moves the note the
  /// room is tuning to (Every Musician, Same Song, 17 September 2026).
  final String? songKey;

  /// What holds the drone. Production leaves this null and makes one; a test
  /// hands in a silent one.
  final DronePlayer? drone;

  static const int sampleRate = 44100;
  static const int frame = 4096;
  static const int hop = 2048;

  static Future<void> show(
    BuildContext context, {
    HornReading reading = HornReading.concert,
    String? songKey,
  }) =>
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: AppColors.deepNavy,
        isScrollControlled: true,
        builder: (_) => TunerSheet(reading: reading, songKey: songKey),
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

  /// What this tuner calls A, kept on this device. See TunerReferenceStore.
  int _a4 = TunerReferenceStore.standard;

  /// Whether the reference was moved before the kept one arrived, so a slow
  /// read cannot undo the press. The same guard the sheet's transpose has:
  /// on a cold launch the first press can land before preferences have
  /// opened, and the screen must not then disagree with what is stored.
  bool _referenceTouched = false;

  /// Whether the note is named the way this person's instrument writes it.
  /// Off until asked for: the note that is sounding is the true answer, and
  /// the written name is the convenience on top of it.
  bool _written = false;

  /// The note this tuner can hold, at the reference above it. Made here and
  /// stopped in [dispose], so leaving the tuner stops the drone — which is
  /// also what keeps it off a take, since the sheet that records is the one
  /// this opens from and it closes before the red button.
  late final DroneVoice _drone = DroneVoice(
    player: widget.drone,
    songKey: widget.songKey,
    a4: _a4,
  );

  @override
  void initState() {
    super.initState();
    _ear.reading.addListener(_changed);
    _ear.listening.addListener(_changed);
    // The hint above the needle depends on whether the drone is sounding, and
    // that is not something the ear can tell this sheet.
    _drone.addListener(_changed);
    unawaited(_loadReference());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_listen());
    });
  }

  Future<void> _loadReference() async {
    final kept = await TunerReferenceStore.load();
    // The level and the fifth this device keeps for its drone.
    unawaited(_drone.load());
    if (!mounted || _referenceTouched || kept == _a4) return;
    setState(() => _a4 = kept);
    _drone.setReference(kept);
  }

  void _shiftReference(int delta) {
    final next = (_a4 + delta)
        .clamp(TunerReferenceStore.lowest, TunerReferenceStore.highest)
        .toInt();
    if (next == _a4) return;
    setState(() {
      _referenceTouched = true;
      _a4 = next;
    });
    // A drone that stayed at 440 while the tuner moved to 442 would be the one
    // thing in the room out of tune with everything else.
    _drone.setReference(next);
    unawaited(TunerReferenceStore.save(next));
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ear.reading.removeListener(_changed);
    _ear.listening.removeListener(_changed);
    _ear.dispose();
    // Closing the tuner stops the drone, so it can never still be sounding
    // when the sheet behind it starts recording.
    _drone.removeListener(_changed);
    _drone.dispose();
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
    // The ear always hears a frequency; what that frequency is *called*
    // depends on what this person is calling A, so the naming happens here
    // rather than inside the listener Perform shares. 440 is a convention,
    // not a fact: a player sitting in with an orchestra at 442, or with a
    // baroque group at 415, should not be told they are sharp all evening.
    // While this sheet is making a sound, it stops believing its own ear.
    //
    // The microphone here is a raw stream with no echo cancellation, a couple
    // of centimetres from the loudspeaker the drone comes out of, so the
    // needle would lock onto the drone and sit in the middle saying "In tune."
    // — about itself. A tuner that reads its own tone back is worse than one
    // that says nothing, because it looks like an answer. So while the drone
    // is held, or a starting pitch is still ringing, the needle rests and the
    // hint says what to do instead. Nothing is announced and nothing is
    // switched off: the ear comes back the moment the tone stops (Every
    // Musician, Same Song, 17 September 2026).
    final ownSound = _drone.sounding;
    final reading =
        ownSound ? null : readPitch(_ear.reading.value?.hz, a4: _a4.toDouble());
    final listening = _ear.listening.value;
    final inTune = reading?.inTune ?? false;
    final accent = inTune ? AppColors.green : AppColors.gold;
    // The note as this person's instrument writes it, when they have asked
    // for that. The pitch underneath is unchanged -- a trumpet's written C
    // is still a concert B♭ coming out of the bell.
    final (String name, int octave) = reading == null
        ? ('', 0)
        : _written
            ? writtenNote(widget.reading, reading.midi)
            : (reading.name, reading.octave);
    return SafeArea(
      // Scrollable since the drone joined the needle: the sheet is already
      // most of a short phone's height, and the phone's own text size is
      // honoured rather than clamped, so at the largest of them the Done
      // button has to be reachable rather than cut off.
      child: SingleChildScrollView(
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
                    (ownSound
                        ? 'Tune to the drone by ear.'
                        : reading == null
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
                                text: name,
                                style: TextStyle(
                                  color: accent,
                                  fontSize: 78,
                                  fontWeight: FontWeight.w900,
                                  height: 1,
                                ),
                              ),
                              TextSpan(
                                text: '$octave',
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
              const SizedBox(height: 10),
              // What A is, one hertz at a time. The same shape as the sheet's
              // transpose control, because it is the same kind of thing: a
              // personal setting on the thing in front of you, not a mode.
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  IconButton(
                    tooltip: 'Lower reference',
                    visualDensity: VisualDensity.compact,
                    onPressed: _a4 <= TunerReferenceStore.lowest
                        ? null
                        : () => _shiftReference(-1),
                    icon: const Icon(Icons.remove_rounded, size: 18),
                  ),
                  Text(
                    'A = $_a4 Hz',
                    key: const Key('tuner_reference'),
                    style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Raise reference',
                    visualDensity: VisualDensity.compact,
                    onPressed: _a4 >= TunerReferenceStore.highest
                        ? null
                        : () => _shiftReference(1),
                    icon: const Icon(Icons.add_rounded, size: 18),
                  ),
                ],
              ),
              // Only offered to somebody who has already said they read for a
              // horn, on the song they said it on. Everybody else has one way
              // of naming a note and does not need to be asked about it.
              if (widget.reading != HornReading.concert)
                TextButton(
                  key: const Key('tuner_written_names'),
                  onPressed: () => setState(() => _written = !_written),
                  style: TextButton.styleFrom(foregroundColor: AppColors.muted),
                  child: Text(
                    _written
                        ? 'Written for ${widget.reading.label}'
                        : 'Concert names',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              const SizedBox(height: 4),
              // A note to tune against rather than a needle to watch: a tanpura
              // under a raga, a pitch pipe in front of a quartet, the note a
              // choir is given before anybody counts. At the reference above,
              // because a drone at 440 under an orchestra at 442 is the thing
              // that is out of tune (Every Musician, Same Song, 17 September
              // 2026).
              DroneControls(voice: _drone),
              const SizedBox(height: 4),
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
