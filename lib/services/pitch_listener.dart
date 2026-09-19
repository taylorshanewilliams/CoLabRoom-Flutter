import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import 'phone_audio.dart';
import 'pitch.dart';

/// The phone's ear, as a value you can listen to.
///
/// Opens the microphone as a raw stream (or a stream a test hands in), cuts
/// it into frames, asks `detectPitch` one question per frame, and publishes
/// the median of the last three answers on [reading] -- the median because a
/// string's attack is noisy for a frame and nothing should flinch at it. A
/// note that stopped a moment ago is cleared, so nothing sits on screen as
/// if it were still sounding. Nothing is written anywhere.
///
/// Lifted out of the tuner so that Perform can hear the singer with the
/// same ear the tuner hears a string with: one detector, one smoothing
/// rule, one place the microphone is opened and closed.
class PitchListener {
  PitchListener({
    this.openStream,
    this.sampleRate = 44100,
    this.frame = 4096,
    this.hop = 2048,
    PhoneAudio? audio,
  }) : _audio = audio ?? AudioSessionOwner.instance;

  /// The phone's audio. The ear is a recording pass like any other: it opens
  /// the microphone, so a call on this phone has to stand down for it, and
  /// the session has to be record-capable before the stream is asked for.
  final PhoneAudio _audio;
  late final AudioHolding _hold = AudioHolding(_audio, AudioNeed.recording);

  /// Where the samples come from. Production leaves this null and uses the
  /// microphone; a test hands in a sine wave.
  final Future<Stream<Uint8List>> Function()? openStream;

  final int sampleRate;
  final int frame;
  final int hop;

  /// What is sounding now, or null in silence.
  final ValueNotifier<PitchReading?> reading = ValueNotifier<PitchReading?>(null);

  /// Whether the ear is open.
  final ValueNotifier<bool> listening = ValueNotifier<bool>(false);

  /// How long a note may be gone before it stops being shown.
  static const Duration linger = Duration(milliseconds: 900);

  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _samples;
  final List<double> _buffer = <double>[];
  final List<PitchReading> _recent = <PitchReading>[];
  DateTime? _heardAt;
  Timer? _fade;
  bool _disposed = false;

  /// The recorder's own permission check, for a disclosure to ask through.
  Future<bool> hasPermission() => (_recorder ??= AudioRecorder()).hasPermission();

  /// Opens the ear. [allowed] is asked once before the real microphone is
  /// touched and never before a test stream -- the disclosure that goes with
  /// it is the caller's UI, not this class's. Throws when refused or when
  /// the stream cannot be opened; [onError] hears a stream that fails later.
  Future<void> start({
    Future<bool> Function()? allowed,
    void Function(Object error)? onError,
  }) async {
    if (listening.value || _disposed) return;
    final Stream<Uint8List> stream;
    if (openStream != null) {
      stream = await openStream!();
    } else {
      if (allowed != null && !await allowed()) {
        throw StateError('The microphone is needed to hear you.');
      }
      final recorder = _recorder ??= AudioRecorder();
      await _hold.take();
      try {
        // Through the owner, which tells the record plugin to leave the
        // session alone while a call holds it. See recordingOn.
        stream = await recorder.startStream(await recordingOn(
          recorder,
          RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: sampleRate,
            numChannels: 1,
          ),
          audio: _audio,
        ));
      } catch (_) {
        await _hold.letGo();
        rethrow;
      }
    }
    if (_disposed) return;
    listening.value = true;
    _samples = stream.listen(_onSamples, onError: (Object error) => onError?.call(error));
    _fade ??= Timer.periodic(const Duration(milliseconds: 250), (_) {
      final heard = _heardAt;
      if (heard == null || reading.value == null) return;
      if (DateTime.now().difference(heard) > linger) {
        _recent.clear();
        reading.value = null;
      }
    });
  }

  /// Closes the ear and forgets what it heard. Safe to call twice.
  Future<void> stop() async {
    final samples = _samples;
    _samples = null;
    // Not awaited. A subscription's cancel future is completed in the root
    // zone, which a widget test's fake clock never runs -- the stop would
    // hang until the test was over. The recorder's own stop is what gives
    // the microphone back, and that is awaited.
    unawaited(samples?.cancel());
    await _recorder?.stop().catchError((_) => null);
    await _hold.letGo();
    _buffer.clear();
    _recent.clear();
    _heardAt = null;
    if (!_disposed) {
      listening.value = false;
      reading.value = null;
    }
  }

  void dispose() {
    _disposed = true;
    _fade?.cancel();
    unawaited(_samples?.cancel());
    _samples = null;
    unawaited(_recorder?.stop().catchError((_) => null));
    unawaited(_recorder?.dispose());
    unawaited(_hold.letGo());
    reading.dispose();
    listening.dispose();
  }

  void _onSamples(Uint8List bytes) {
    if (_disposed) return;
    _buffer.addAll(pcm16ToFloats(bytes));
    while (_buffer.length >= frame) {
      final samples = Float64List.fromList(_buffer.sublist(0, frame));
      _buffer.removeRange(0, hop);
      final heard = readPitch(detectPitch(samples, sampleRate));
      if (heard == null) continue;
      _recent.add(heard);
      if (_recent.length > 3) _recent.removeAt(0);
      final sorted = List<PitchReading>.of(_recent)..sort((a, b) => a.hz.compareTo(b.hz));
      _heardAt = DateTime.now();
      reading.value = sorted[sorted.length ~/ 2];
    }
    // Do not let a stalled detector hoard memory.
    if (_buffer.length > frame * 4) {
      _buffer.removeRange(0, _buffer.length - frame);
    }
  }
}
