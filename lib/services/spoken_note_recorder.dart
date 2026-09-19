import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'phone_audio.dart';

/// The microphone, for a note that is said rather than typed (0152).
///
/// Every Musician, Same Song, 17 September 2026. A teacher with a guitar in
/// their hands would rather say it, so this is the whole of what the takes
/// screen needs: open the microphone, close it, hand back the bytes. Exactly
/// the way a line voice note is captured — wav, 44.1 kHz, one channel —
/// because that is the one recording path proven on all three platforms
/// (the workspace records a line's voice note on the web too).
///
/// A class rather than three calls on [AudioRecorder] so that a test can
/// stand in for the microphone: the screen's rules about holding, letting
/// go and the one-minute cap are worth a test, and the real recorder
/// throws without a platform behind it.
class SpokenNoteRecorder {
  SpokenNoteRecorder({AudioRecorder? recorder, PhoneAudio? audio})
      : _recorder = recorder,
        _audio = audio ?? AudioSessionOwner.instance;

  AudioRecorder? _recorder;

  /// The phone's audio, asked before the microphone opens. A note said
  /// during a call is a recording pass like any other, and the call has to
  /// stand down for it.
  final PhoneAudio _audio;
  AudioHold? _hold;

  /// Resolved on use, not in the constructor, so making the screen costs
  /// nothing until somebody actually holds the button.
  AudioRecorder get _mic => _recorder ??= AudioRecorder();

  /// Fewer bytes than this is a wav header and a breath: a tap rather than
  /// a hold, or a microphone that opened and heard nothing. Not saved,
  /// and said so — the takes memory records what a recording that reaches
  /// the database with nothing in it costs to find.
  static const int shortestNote = 1024;

  Future<bool> hasPermission() => _mic.hasPermission();

  Future<void> start() async {
    final path = await _path();
    _hold ??= await _audio.need(AudioNeed.recording);
    try {
      await _mic.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 44100,
          numChannels: 1,
        ),
        path: path,
      );
    } catch (_) {
      await _letGoOfTheAudio();
      rethrow;
    }
  }

  /// What was said, or null when the recorder had nothing to give back.
  Future<Uint8List?> stop() async {
    final String? path;
    try {
      path = await _mic.stop();
    } finally {
      await _letGoOfTheAudio();
    }
    if (path == null) return null;
    final bytes = await XFile(path).readAsBytes();
    if (!kIsWeb) {
      // The bytes are in hand; the file was only ever a way of getting them.
      try {
        await File(path).delete();
      } catch (_) {}
    }
    return bytes;
  }

  /// Stops and throws the recording away.
  Future<void> cancel() async {
    try {
      await _mic.cancel();
    } finally {
      await _letGoOfTheAudio();
    }
  }

  Future<void> dispose() async {
    await _letGoOfTheAudio();
    await _recorder?.dispose();
    _recorder = null;
  }

  /// Cleared before the release is awaited, so two ways out of one recording
  /// cannot release the same hold twice.
  Future<void> _letGoOfTheAudio() async {
    final hold = _hold;
    _hold = null;
    await hold?.release();
  }

  Future<String> _path() async {
    final name = 'colabroom_said_${DateTime.now().microsecondsSinceEpoch}.wav';
    // No filesystem in a browser; the recorder there ignores the path and
    // hands back a blob URL, which XFile reads.
    if (kIsWeb) return name;
    final directory = await getTemporaryDirectory();
    return '${directory.path}/$name';
  }
}
