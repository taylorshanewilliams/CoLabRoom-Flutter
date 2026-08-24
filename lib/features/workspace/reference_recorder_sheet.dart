import 'dart:async';
import 'dart:io';

import 'package:colabroom/app/colabroom_theme.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../widgets/microphone_disclosure.dart';

class ReferenceRecorderSheet extends StatefulWidget {
  const ReferenceRecorderSheet({required this.songTitle, super.key});

  final String songTitle;

  @override
  State<ReferenceRecorderSheet> createState() =>
      _ReferenceRecorderSheetState();
}

class _ReferenceRecorderSheetState extends State<ReferenceRecorderSheet> {
  final AudioRecorder _recorder = AudioRecorder();
  Timer? _timer;
  DateTime? _startedAt;
  String? _path;
  String? _error;
  bool _recording = false;
  bool _saving = false;
  Duration _elapsed = Duration.zero;

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_recorder.dispose());
    super.dispose();
  }

  Future<void> _start() async {
    if (_recording || _saving) return;
    setState(() => _error = null);
    try {
      if (!mounted) return;
      final allowed = await MicrophoneAccess.ensureGranted(
        context,
        purpose: 'to capture a take of this song',
        request: _recorder.hasPermission,
      );
      if (!allowed) {
        throw StateError('Microphone permission is needed to record a song.');
      }
      final directory = await getTemporaryDirectory();
      final title = widget.songTitle
          .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
          .replaceAll(RegExp(r'_+'), '_');
      final path =
          '${directory.path}/${title}_${DateTime.now().millisecondsSinceEpoch}.wav';
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 44100,
          numChannels: 1,
        ),
        path: path,
      );
      _path = path;
      _startedAt = DateTime.now();
      _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
        final started = _startedAt;
        if (!mounted || started == null) return;
        final elapsed = DateTime.now().difference(started);
        setState(() => _elapsed = elapsed);
        if (elapsed >= const Duration(minutes: 15)) unawaited(_finish());
      });
      if (mounted) setState(() => _recording = true);
    } catch (error) {
      if (mounted) setState(() => _error = _plainError(error));
    }
  }

  Future<void> _finish() async {
    if (!_recording || _saving) return;
    setState(() => _saving = true);
    _timer?.cancel();
    try {
      final stopped = await _recorder.stop();
      final path = stopped ?? _path;
      if (path == null || !await File(path).exists()) {
        throw StateError('The recording could not be saved.');
      }
      final file = File(path);
      if (_elapsed < const Duration(seconds: 2) || await file.length() < 4096) {
        await file.delete();
        throw StateError('Record at least a few seconds before analyzing.');
      }
      if (mounted) Navigator.pop(context, path);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _recording = false;
        _saving = false;
        _error = _plainError(error);
      });
    }
  }

  Future<void> _cancel() async {
    if (_saving) return;
    _timer?.cancel();
    if (_recording) await _recorder.stop();
    final path = _path;
    if (path != null && await File(path).exists()) await File(path).delete();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_recording && !_saving,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(height: 22),
              Text(
                'Record the song',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: AppColors.text,
                      fontWeight: FontWeight.w900,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                _recording
                    ? 'Play the full arrangement naturally. Stop when the song is finished.'
                    : 'Capture a rehearsal, acoustic take, or performance directly from this phone.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.muted,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 26),
              Container(
                width: 112,
                height: 112,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: (_recording ? const Color(0xFFFF6178) : AppColors.cyan)
                      .withValues(alpha: 0.1),
                  border: Border.all(
                    color: _recording
                        ? const Color(0xFFFF6178)
                        : AppColors.cyan,
                    width: 2,
                  ),
                ),
                child: Icon(
                  _recording ? Icons.graphic_eq_rounded : Icons.mic_rounded,
                  color: _recording ? const Color(0xFFFF6178) : AppColors.cyan,
                  size: 46,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                _clock(_elapsed),
                key: const Key('reference_recording_clock'),
                style: const TextStyle(
                  color: AppColors.text,
                  fontSize: 34,
                  fontWeight: FontWeight.w300,
                ),
              ),
              if (_error != null) ...<Widget>[
                const SizedBox(height: 14),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFFFF9CAA),
                    fontSize: 11,
                  ),
                ),
              ],
              const SizedBox(height: 24),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextButton(
                      onPressed: _saving ? null : _cancel,
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      key: Key(_recording
                          ? 'stop_reference_recording'
                          : 'start_reference_recording'),
                      onPressed: _saving
                          ? null
                          : _recording
                              ? _finish
                              : _start,
                      icon: _saving
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(_recording
                              ? Icons.stop_rounded
                              : Icons.fiber_manual_record_rounded),
                      label: Text(_saving
                          ? 'Saving…'
                          : _recording
                              ? 'Stop & use take'
                              : 'Start recording'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _clock(Duration value) {
  final minutes = value.inMinutes;
  final seconds = value.inSeconds.remainder(60);
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

String _plainError(Object error) => error
    .toString()
    .replaceFirst('Bad state: ', '')
    .replaceFirst('Exception: ', '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
