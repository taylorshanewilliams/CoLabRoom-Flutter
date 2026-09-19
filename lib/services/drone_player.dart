import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import 'drone.dart';
import 'phone_audio.dart';

/// Something that holds one note. The screens talk to this so a test can hand
/// them a silent one, the same shape ClickPlayer has.
///
/// Two sounds and no others: a drone held until it is stopped, and a starting
/// pitch let go of after two seconds. Neither is ever part of a take — see
/// [WavDronePlayer].
abstract class DronePlayer {
  /// Holds [hz] until [stop], fading in rather than arriving.
  ///
  /// [level] is 0 to 1, the person's own. Called again with a different note
  /// or fifth while it is already sounding, it changes to the new one.
  Future<void> hold({
    required double hz,
    bool fifth = false,
    double level = 0.6,
  });

  /// Moves the level of a drone that is already sounding, without restarting
  /// it. A drone that restarted every time the slider moved would be a series
  /// of attacks, which is the opposite of a drone.
  Future<void> setLevel(double level);

  /// Sounds [hz] once, for about two seconds.
  Future<void> sound({
    required double hz,
    bool fifth = false,
    double level = 0.6,
  });

  Future<void> stop();
  Future<void> dispose();
}

/// One sound, and the few things a drone ever does to it.
///
/// Small on purpose. Everything in [WavDronePlayer] that can go wrong goes
/// wrong in the gaps between these calls — a switch turned off while a source
/// is still being prepared — and a test cannot open those gaps in a real
/// AudioPlayer. Behind this it can.
abstract class DroneOutput {
  /// Starts [bytes], from the beginning, at [volume], looping or not.
  Future<void> play(
    Uint8List bytes, {
    required bool loop,
    required double volume,
  });

  Future<void> setVolume(double volume);
  Future<void> stop();
  Future<void> dispose();
}

/// A [DroneOutput] on an audioplayers player of its own.
///
/// **Why it asks for no audio focus.** This is the first place in the app that
/// deliberately runs two sounds at once, and Android's default is the opposite
/// of that: audioplayers gives every player its own focus request, and the
/// default is `AUDIOFOCUS_GAIN` — "this app is the only thing you are
/// listening to". Each new request takes focus off the last one, and
/// audioplayers pauses a player that loses focus and never starts it again.
/// Left alone, turning the drone on under a song would stop the song, pressing
/// the starting pitch would stop the drone, and pressing play would stop both,
/// with every switch on screen still saying on. The drone has nothing to say
/// to other apps: it is one voice among several inside this one, which is what
/// `amongOthers` means to [PhoneAudio].
///
/// The session itself comes from [PhoneAudio] and nowhere else, so a drone
/// sounding in a call is on the call's session rather than one of its own.
class AudioPlayerOutput implements DroneOutput {
  AudioPlayerOutput([AudioPlayer? player, PhoneAudio? audio])
      : _player = player,
        _audio = audio ?? AudioSessionOwner.instance;

  /// Made when a note is first asked for, the way Perform's click is: opening
  /// the sheet is not the same as wanting a sound, and most of the people who
  /// look at it will never turn the drone on.
  AudioPlayer? _player;
  final PhoneAudio _audio;
  late final AudioHolding _hold = AudioHolding(_audio, AudioNeed.playing);
  bool _prepared = false;

  @override
  Future<void> play(
    Uint8List bytes, {
    required bool loop,
    required double volume,
  }) async {
    final player = _player ??= AudioPlayer();
    await _hold.take();
    // Awaited before the first sound rather than applied at construction: a
    // focus request that landed after the source had started would already
    // have taken focus off whatever else was going.
    if (!_prepared) {
      _prepared = true;
      await _audio.useOn(player, amongOthers: true);
    }
    await player.stop();
    await player.setReleaseMode(loop ? ReleaseMode.loop : ReleaseMode.release);
    await player.setVolume(volume);
    // Bytes rather than a path. The click writes a WAV to the temporary
    // directory and plays that; path_provider has no web implementation, so
    // the same route throws in a browser. Handing over the bytes lets
    // audioplayers decide, and it writes its own temporary file on the
    // platforms that need one.
    await player.play(BytesSource(bytes, mimeType: 'audio/wav'));
  }

  @override
  Future<void> setVolume(double volume) async => _player?.setVolume(volume);

  /// Only what was made: stopping a drone nobody started must not make the
  /// player that was avoided.
  @override
  Future<void> stop() async {
    await _player?.stop();
    await _hold.letGo();
  }

  @override
  Future<void> dispose() async {
    await _hold.letGo();
    await _player?.dispose();
  }
}

/// How the tone gets built. Production builds it off the main thread; a test
/// hands in something immediate rather than spawning an isolate for a note
/// nobody is going to hear.
typedef DroneToneBuilder = Future<Uint8List> Function(
  Uint8List Function(DroneRequest) make,
  DroneRequest request,
);

/// The drone, generated here and played through outputs of its own.
///
/// **Why two outputs, and why neither is shared.** The drone loops for as long
/// as somebody wants it; the starting pitch is a single note somebody presses
/// for while the drone may already be going. One player would make the second
/// press silence the first sound, which is not what either button says. And
/// neither may be the player the song is on: Perform seeks, rates and disposes
/// that one, and a drone that followed a song being scrubbed would be a siren.
///
/// **Why it can never land on a take.** Nothing here writes a take, holds a
/// take id or is offered to Multitrack, so no mixdown can include it — the
/// same way the metronome's click is not in one. The drone is only offered on
/// the tuner sheet and in Perform, and both stop and dispose it when they are
/// left, so it cannot still be sounding when a record button is pressed (Every
/// Musician, Same Song, 17 September 2026).
///
/// **Why the bytes are kept.** Asking for the same note again — a reference
/// nudged up and back, a kept setting arriving late — would otherwise rebuild
/// half a minute of tone, and on iOS every play of a fresh byte array is
/// another temporary file audioplayers never comes back for.
class WavDronePlayer implements DronePlayer {
  WavDronePlayer({
    DroneOutput? held,
    DroneOutput? once,
    DroneToneBuilder build = _offThread,
  })  : _held = held ?? AudioPlayerOutput(),
        _once = once ?? AudioPlayerOutput(),
        _build = build;

  final DroneOutput _held;
  final DroneOutput _once;
  final DroneToneBuilder _build;

  /// Which drone is the current one, and which starting pitch.
  ///
  /// Everything below re-checks these after every await. Building the tone and
  /// handing it to a player both take long enough for a second tap to arrive
  /// in the middle — on Android, preparing a source is tens to hundreds of
  /// milliseconds — and a hold that carried on regardless would leave a loop
  /// sounding with the switch showing off, which nothing on screen could then
  /// silence.
  int _generation = 0;
  int _pitchGeneration = 0;

  /// Which hold owns the held output, and which press owns the other one. A
  /// sound that finds itself stale has to tidy up after itself, but only when
  /// a newer one has not already taken the output over — otherwise an old note
  /// leaving would silence the new one.
  int _owner = 0;
  int _pitchOwner = 0;

  double _level = 0;
  bool _holding = false;
  bool _disposed = false;

  DroneRequest? _loopKey;
  Uint8List? _loopBytes;

  /// How long the drone takes to arrive, and in how many steps.
  ///
  /// The fade lives here and not in the file. A loop with an envelope on the
  /// front re-attacks every time round, which is a tremolo; the only place a
  /// soft attack can go for a sound that repeats forever is the volume of the
  /// thing playing it.
  static const Duration fadeIn = Duration(milliseconds: 240);
  static const int fadeSteps = 8;

  /// Half a minute of tone is a few million sine calls, which is long enough
  /// to drop frames if it happens between a finger and a switch. Web has no
  /// isolates and `compute` there runs it in place, so that is spelled out
  /// rather than left to chance.
  static Future<Uint8List> _offThread(
    Uint8List Function(DroneRequest) make,
    DroneRequest request,
  ) async =>
      kIsWeb ? make(request) : compute(make, request);

  /// Whether the drone that started as [generation] is still the wanted one.
  bool _stale(int generation) => _disposed || generation != _generation;

  @override
  Future<void> hold({
    required double hz,
    bool fifth = false,
    double level = 0.6,
  }) async {
    if (_disposed) return;
    final generation = ++_generation;
    _level = level.clamp(0.0, 1.0);
    // Whatever was sounding is not what has just been asked for, so nothing
    // below may treat it as the drone that is up: giving up part way through
    // has to leave this silent rather than half-started.
    _holding = false;
    final request = (hz: hz, fifth: fifth);
    final kept = _loopKey == request ? _loopBytes : null;
    final bytes = kept ?? await _build(droneWavFor, request);
    if (_stale(generation)) return;
    _loopKey = request;
    _loopBytes = bytes;
    _owner = generation;
    await _held.play(bytes, loop: true, volume: 0);
    if (_stale(generation)) {
      // Stopped, or moved to another note, while the source was being
      // prepared. Without this the loop would run on at volume zero, and the
      // next touch of the level slider would fade up a drone whose switch says
      // off — with no way back to it but turning the switch on and off again.
      if (_owner == generation) await _held.stop();
      return;
    }
    _holding = true;
    for (var step = 1; step <= fadeSteps; step += 1) {
      await Future<void>.delayed(fadeIn ~/ fadeSteps);
      if (_stale(generation)) return;
      await _held.setVolume(_level * step / fadeSteps);
    }
  }

  @override
  Future<void> setLevel(double level) async {
    if (_disposed) return;
    _level = level.clamp(0.0, 1.0);
    // Nothing is sounding, so there is no volume to move: the next [hold]
    // fades up to whatever the level is by then.
    if (!_holding) return;
    await _held.setVolume(_level);
  }

  @override
  Future<void> sound({
    required double hz,
    bool fifth = false,
    double level = 0.6,
  }) async {
    if (_disposed) return;
    final generation = ++_pitchGeneration;
    final bytes = await _build(startingPitchWavFor, (hz: hz, fifth: fifth));
    if (_disposed || generation != _pitchGeneration) return;
    _pitchOwner = generation;
    await _once.play(bytes, loop: false, volume: level.clamp(0.0, 1.0));
    // Let go of, or the screen left, while this was being prepared. Two
    // seconds is short, but a note that starts after the sheet has closed is
    // still a note nobody has a button for.
    if ((_disposed || generation != _pitchGeneration) &&
        _pitchOwner == generation) {
      await _once.stop();
    }
  }

  @override
  Future<void> stop() async {
    _generation++;
    _pitchGeneration++;
    _holding = false;
    await _held.stop();
    await _once.stop();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _generation++;
    _pitchGeneration++;
    _holding = false;
    _loopBytes = null;
    await _held.dispose();
    await _once.dispose();
  }
}
