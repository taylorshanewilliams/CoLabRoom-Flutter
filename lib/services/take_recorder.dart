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

  /// Made on use rather than in the constructor, so opening the takes screen
  /// costs nothing until somebody actually records.
  AudioRecorder get _mic => _recorder ??= AudioRecorder();

  Future<bool> hasPermission() => _mic.hasPermission();

  Future<void> start(RecordConfig config, {required String path}) =>
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
    await _recorder?.dispose();
    _recorder = null;
  }
}
