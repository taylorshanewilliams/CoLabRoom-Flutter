import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Something that says a chord name out loud. Perform talks to this so a test
/// can hand it one that keeps what it was told instead of speaking.
///
/// The same seam ClickPlayer is, and for the same reason: the one thing in
/// this app that makes a sound on a platform channel must not be the thing a
/// test has to have a device for (Every Musician, Same Song, 17 September
/// 2026).
abstract class ChordVoice {
  /// Says [words], cutting off whatever it was in the middle of.
  ///
  /// Cutting off rather than queueing is the point. A chord call is only
  /// worth anything in the beat before its chord lands, so a name still being
  /// said when the next one is due is already too late — finishing it would
  /// put the voice a chord behind the song and keep it there.
  Future<void> say(String words);

  /// Stops mid-word. The song moved, or it stopped.
  Future<void> stop();

  Future<void> dispose();
}

/// The platform's own voice, through flutter_tts.
///
/// Its own instance rather than a shared one: this is the only thing in the
/// app that speaks, it belongs to the screen that is calling chords, and it
/// goes when that screen does.
///
/// The web included. flutter_tts speaks through the browser's own speech
/// synthesis there, and the desk is a real place to play a song from, so the
/// control is offered rather than hidden — the one difference is the speed,
/// which the platforms count on two different scales.
class TtsChordVoice implements ChordVoice {
  TtsChordVoice({FlutterTts? tts}) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;

  /// Set the first time something is said, because every one of these is a
  /// call over a platform channel and the answer does not change.
  bool _ready = false;

  Future<void> _prepare() async {
    if (_ready) return;
    _ready = true;
    // A chord name is two or three words in the beat before a change, so it
    // is said a little quicker than the platform's default reading voice —
    // which is set for sentences — and never quicker than that: a name
    // nobody can make out is the same as no name.
    await _tts.setSpeechRate(kIsWeb ? 1.0 : 0.55);
    await _tts.setVolume(1);
    await _tts.setPitch(1);
  }

  @override
  Future<void> say(String words) async {
    if (words.trim().isEmpty) return;
    await _prepare();
    await _tts.stop();
    await _tts.speak(words);
  }

  @override
  Future<void> stop() => _tts.stop();

  @override
  Future<void> dispose() async {
    await _tts.stop();
  }
}
