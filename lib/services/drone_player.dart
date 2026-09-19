import 'package:audioplayers/audioplayers.dart';

import 'drone.dart';

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

/// The drone, generated here and played through players of its own.
///
/// **Why two players, and why neither is shared.** The drone loops for as long
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
/// **Why bytes rather than a file.** The click writes a WAV to the temporary
/// directory and plays the path. path_provider has no web implementation, so
/// that path throws in a browser; handing the player the bytes lets
/// audioplayers decide, and it writes its own temporary file on the platforms
/// that need one. The tone is a couple of seconds of mono audio, so there is
/// nothing to be saved by keeping it on disk.
class WavDronePlayer implements DronePlayer {
  WavDronePlayer({AudioPlayer? held, AudioPlayer? once})
      : _heldPlayer = held,
        _oncePlayer = once;

  /// Made when a note is first asked for, the way Perform's click is: opening
  /// the sheet is not the same as wanting a sound, and most of the people who
  /// look at it will never turn the drone on.
  AudioPlayer? _heldPlayer;
  AudioPlayer? _oncePlayer;

  AudioPlayer get _held => _heldPlayer ??= AudioPlayer();
  AudioPlayer get _once => _oncePlayer ??= AudioPlayer();

  /// Which drone is the current one. A second press while the first one's
  /// bytes are still being built must not leave that one to start afterwards,
  /// and the fade below must stop when it is no longer wanted.
  int _generation = 0;

  double _level = 0;
  bool _holding = false;

  /// How long the drone takes to arrive, and in how many steps.
  ///
  /// The fade lives here and not in the file. A loop with an envelope on the
  /// front re-attacks every time round, which is a tremolo; the only place a
  /// soft attack can go for a sound that repeats forever is the volume of the
  /// thing playing it.
  static const Duration fadeIn = Duration(milliseconds: 240);
  static const int fadeSteps = 8;

  @override
  Future<void> hold({
    required double hz,
    bool fifth = false,
    double level = 0.6,
  }) async {
    final generation = ++_generation;
    _level = level.clamp(0.0, 1.0);
    final bytes = droneWav(hz: hz, fifth: fifth);
    if (generation != _generation) return;
    await _held.stop();
    await _held.setReleaseMode(ReleaseMode.loop);
    await _held.setVolume(0);
    await _held.play(BytesSource(bytes, mimeType: 'audio/wav'));
    _holding = true;
    for (var step = 1; step <= fadeSteps; step += 1) {
      await Future<void>.delayed(fadeIn ~/ fadeSteps);
      if (generation != _generation) return;
      await _held.setVolume(_level * step / fadeSteps);
    }
  }

  @override
  Future<void> setLevel(double level) async {
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
    final bytes = startingPitchWav(hz: hz, fifth: fifth);
    await _once.stop();
    await _once.setReleaseMode(ReleaseMode.release);
    await _once.setVolume(level.clamp(0.0, 1.0));
    await _once.play(BytesSource(bytes, mimeType: 'audio/wav'));
  }

  @override
  Future<void> stop() async {
    _generation++;
    _holding = false;
    // Only what was made: stopping a drone nobody started must not make the
    // players that were avoided.
    await _heldPlayer?.stop();
    await _oncePlayer?.stop();
  }

  @override
  Future<void> dispose() async {
    await _heldPlayer?.dispose();
    await _oncePlayer?.dispose();
  }
}
