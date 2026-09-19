import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

import 'audio_source_for.dart';
import 'multitrack.dart';

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
  /// [player] is for a screen whose click has to carry an audio session of
  /// its own. The takes screen counts somebody in while its recorder is
  /// running, and a player left on the default session asks Android for sole
  /// audio focus and gets the capture silenced -- see OverdubSession. Owned
  /// from here on either way: [dispose] disposes it.
  WavClickPlayer({AudioPlayer? player}) : _player = player ?? AudioPlayer();

  final AudioPlayer _player;
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
  }

  @override
  Future<void> dispose() => _player.dispose();
}
