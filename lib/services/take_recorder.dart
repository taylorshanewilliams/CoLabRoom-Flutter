import 'package:record/record.dart';

import 'phone_audio.dart';

/// The microphone a take is recorded with.
///
/// A class rather than [AudioRecorder] reached for directly, for the reason
/// SpokenNoteRecorder gives: the real recorder throws without a platform
/// behind it, so a screen holding one cannot be pumped at all, and the rules
/// worth a test here are the screen's rather than the plugin's.
///
/// What it adds beyond passing the calls through is [cancel] on a take that
/// never happened. A recording that fails has to let the microphone go --
/// otherwise it keeps running into a file nothing will ever play, and the
/// next press on Record opens a second recorder beside the first.
class TakeRecorder {
  TakeRecorder({AudioRecorder? recorder, PhoneAudio? audio})
      : _recorder = recorder,
        _audio = audio ?? AudioSessionOwner.instance;

  AudioRecorder? _recorder;

  /// The phone's audio, asked before the microphone opens and let go of the
  /// moment the pass is over -- including the paths where it fails. A hold
  /// left out would leave a call with its microphone handed away.
  final PhoneAudio _audio;
  late final AudioHolding _hold = AudioHolding(_audio, AudioNeed.recording);

  /// Whether this has been let go of for good.
  ///
  /// Made-on-use and disposed-once do not go together on their own, and the
  /// first version of this class had the hole: [dispose] dropped the recorder,
  /// and the next call built a fresh one. A recording still in flight when the
  /// screen went away would then open a brand new microphone that nothing
  /// owned -- disposed already, so nobody would dispose it, and on two paths
  /// out of _record nobody would cancel it either. That is the leak this
  /// class was written to close, arriving through the class itself.
  ///
  /// A concrete AudioRecorder used to give this for free: the plugin throws
  /// on a recorder that has been disposed, and _record's catch has always
  /// relied on that ("the throw that brings us here is often a call on a
  /// recorder that is already gone"). The flag keeps that promise.
  bool _disposed = false;

  /// Made on use rather than in the constructor, so opening the takes screen
  /// costs nothing until somebody actually records.
  AudioRecorder get _mic {
    if (_disposed) {
      throw StateError(
        'The recorder was disposed with the screen; it cannot be opened again.',
      );
    }
    return _recorder ??= AudioRecorder();
  }

  Future<bool> hasPermission() async => _mic.hasPermission();

  Future<void> start(RecordConfig config, {required String path}) async {
    // Read first, so a recorder disposed with its screen throws before the
    // phone's audio is moved for a recording that is not going to happen.
    final mic = _mic;
    // Asked for before the microphone opens rather than after, because the
    // session a take needs has to be in place before anything is captured,
    // and because this is what tells a call on this phone to stand down.
    await _hold.take();
    try {
      // The record plugin writes and activates the iOS session itself, and
      // asks Android for focus, unless it is told that somebody else owns
      // the session. With no call that is exactly what a take wants, so
      // nothing changes there; in a call it would undo what the owner just
      // applied. See recordingOn.
      await mic.start(await recordingOn(mic, config, audio: _audio), path: path);
    } catch (_) {
      await _hold.letGo();
      rethrow;
    }
  }

  /// The file that was written, or null when the recorder had nothing to give
  /// back.
  Future<String?> stop() async {
    try {
      return await _mic.stop();
    } finally {
      await _hold.letGo();
    }
  }

  /// Stops and throws away whatever was being recorded.
  ///
  /// Nothing happens when the microphone was never opened: there is no
  /// recording to discard, and asking would open a recorder in order to
  /// cancel it.
  Future<void> cancel() async {
    try {
      await _recorder?.cancel();
    } finally {
      await _hold.letGo();
    }
  }

  Future<void> dispose() async {
    // Set first, so a call racing this one cannot slip a new recorder in
    // between the await below and the field being cleared.
    _disposed = true;
    await _hold.letGo();
    await _recorder?.dispose();
    _recorder = null;
  }
}
