import 'package:record/record.dart';

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
  TakeRecorder({AudioRecorder? recorder}) : _recorder = recorder;

  AudioRecorder? _recorder;

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

  Future<void> start(RecordConfig config, {required String path}) async =>
      _mic.start(config, path: path);

  /// The file that was written, or null when the recorder had nothing to give
  /// back.
  Future<String?> stop() => _mic.stop();

  /// Stops and throws away whatever was being recorded.
  ///
  /// Nothing happens when the microphone was never opened: there is no
  /// recording to discard, and asking would open a recorder in order to
  /// cancel it.
  Future<void> cancel() async => _recorder?.cancel();

  Future<void> dispose() async {
    // Set first, so a call racing this one cannot slip a new recorder in
    // between the await below and the field being cleared.
    _disposed = true;
    await _recorder?.dispose();
    _recorder = null;
  }
}
