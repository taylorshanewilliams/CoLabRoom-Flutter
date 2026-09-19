import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

import 'audio_source_for.dart';
import 'multitrack.dart';
import 'phone_audio.dart';

/// Something that clicks at a tempo. The screens talk to this so a test can
/// hand them a silent one.
///
/// It lived inside the metronome sheet until Perform needed the same click
/// to count a band in on the song's own bar (Every Musician, Same Song,
/// 17 September 2026). One click, in one place: a count-in that ticked at a
/// different pitch from the metronome would be a second sound to learn for
/// no reason.
abstract class ClickPlayer {
  /// [bars] bars of [beatsPerBar] beats at [bpm].
  ///
  /// [loop] keeps it going round, which is a metronome. Without it the bars
  /// play once and stop, which is a count-in.
  ///
  /// [accents] are the beats inside each bar, numbered from one, that a band
  /// counting a cycle of its own stresses: a seven counted 3+2+2 has 4 and 6
  /// in here. Empty is the ordinary click, which marks the first beat and
  /// leaves the rest even.
  Future<void> play({
    required double bpm,
    required int beatsPerBar,
    int bars = 8,
    bool loop = true,
    List<int> accents = const <int>[],
  });

  Future<void> stop();
  Future<void> dispose();
}

/// The click the takes console already makes, written to a file and played.
///
/// Bars written to a temporary file rather than struck from a timer: the
/// beats inside one file are exact, and a click fired a beat at a time
/// drifts by however long each play call happens to take. Looped, it is safe
/// in a way a backing track never is, because there is nothing else playing
/// for it to drift against.
class WavClickPlayer implements ClickPlayer {
  /// [player] is for a test that wants to watch one. Owned from here on
  /// either way: [dispose] disposes it.
  ///
  /// The click carries the phone's session itself rather than being handed a
  /// player somebody else configured. The takes screen counts somebody in
  /// while its recorder is running, and a click left on the app's default
  /// asks Android for sole audio focus and gets the capture silenced -- see
  /// [PhoneAudio], which is now the only place that decides such things.
  WavClickPlayer({AudioPlayer? player, PhoneAudio? audio})
      : _player = player ?? AudioPlayer(),
        _audio = audio ?? AudioSessionOwner.instance;

  final AudioPlayer _player;
  final PhoneAudio _audio;
  AudioHold? _hold;
  bool _carriesTheSession = false;
  int _generation = 0;

  @override
  Future<void> play({
    required double bpm,
    required int beatsPerBar,
    int bars = 8,
    bool loop = true,
    List<int> accents = const <int>[],
  }) async {
    final generation = ++_generation;
    // One voice among several: the click sounds under the backing track and
    // under a recording, so it must never ask for audio focus.
    _hold ??= await _audio.need(AudioNeed.playing);
    if (!_carriesTheSession) {
      _carriesTheSession = true;
      await _audio.useOn(_player, amongOthers: true);
    }
    final directory = await getTemporaryDirectory();
    // The bar count is part of the name because audioplayers keys its cache
    // on the path: a one-bar count-in and an eight-bar metronome at the same
    // tempo sharing a filename would hand back whichever was written first.
    // The stresses are in it for the same reason -- a seven counted 3+2+2 and
    // the same seven counted evenly are two different clicks.
    final stressed = accents.isEmpty ? '' : '_${accents.join('-')}';
    final path =
        '${directory.path}/click_${bpm.round()}_${beatsPerBar}_$bars$stressed.wav';
    await Multitrack.writeClickOnly(
      bpm: bpm,
      outputPath: path,
      beatsPerBar: beatsPerBar,
      bars: bars,
      accents: accents,
    );
    // A slower tap arrived while this file was being written.
    if (generation != _generation) return;
    await _player.stop();
    await _player.setReleaseMode(loop ? ReleaseMode.loop : ReleaseMode.release);
    await _player.play(audioSourceFor(path));
  }

  @override
  Future<void> stop() async {
    _generation++;
    await _player.stop();
    await _letGoOfTheAudio();
  }

  @override
  Future<void> dispose() async {
    await _letGoOfTheAudio();
    await _player.dispose();
  }

  /// Cleared before the release is awaited, so a stop and a dispose racing
  /// each other cannot release the same hold twice.
  Future<void> _letGoOfTheAudio() async {
    final hold = _hold;
    _hold = null;
    await hold?.release();
  }
}
