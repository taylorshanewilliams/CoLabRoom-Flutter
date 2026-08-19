import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../domain/song_analysis_models.dart';
import '../../services/song_analysis_service.dart';
import 'live_performance_screen.dart';
import 'reference_recorder_sheet.dart';
import 'song_sheet_panel.dart';

enum _ReferenceSource { record, file }

class SongAnalysisScreen extends StatefulWidget {
  const SongAnalysisScreen({required this.project, super.key});

  final SongProject project;

  @override
  State<SongAnalysisScreen> createState() => _SongAnalysisScreenState();
}

class _SongAnalysisScreenState extends State<SongAnalysisScreen> {
  final SongAnalysisService _service = SongAnalysisService();
  SongAnalysisBundle? _bundle;
  String? _localPath;
  bool _loading = true;
  bool _working = false;
  SongAnalysisProgress? _progress;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      final bundle = await _service.load(widget.project.id);
      if (!mounted) return;
      setState(() {
        _bundle = bundle;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _pickReferenceSource() async {
    if (_working) return;
    final choice = await showModalBottomSheet<_ReferenceSource>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: AppColors.deepNavy,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                key: const Key('pick_source_record'),
                leading: const Icon(Icons.mic_rounded, color: AppColors.cyan),
                title: const Text('Record now'),
                subtitle: const Text('Capture a take with this phone\'s microphone'),
                onTap: () => Navigator.pop(sheetContext, _ReferenceSource.record),
              ),
              ListTile(
                key: const Key('pick_source_file'),
                leading: const Icon(Icons.audio_file_rounded, color: AppColors.cyan),
                title: const Text('Choose a file'),
                subtitle: const Text('Pick an existing recording, demo, or mix'),
                onTap: () => Navigator.pop(sheetContext, _ReferenceSource.file),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case _ReferenceSource.record:
        await _recordReference();
      case _ReferenceSource.file:
        await _chooseRecording();
    }
  }

  Future<void> _recordReference() async {
    final path = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => Scaffold(
          backgroundColor: AppColors.deepNavy,
          body: ReferenceRecorderSheet(songTitle: widget.project.title),
        ),
        fullscreenDialog: true,
      ),
    );
    if (path == null || !mounted) return;
    await _attachLocalFile(path: path, displayName: '${widget.project.title} (recorded)');
  }

  Future<void> _chooseRecording() async {
    if (_working) return;
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const <String>['mp3', 'm4a', 'wav', 'flac', 'ogg', 'opus', 'aac'],
    );
    if (file == null || file.path == null || !mounted) return;
    await _attachLocalFile(path: file.path!, displayName: file.name);
  }

  Future<void> _attachLocalFile({required String path, required String displayName}) async {
    setState(() {
      _working = true;
      _error = null;
      _progress = const SongAnalysisProgress('Uploading reference recording', 0.02);
    });
    try {
      final reference = await _service.attachReference(
        project: widget.project,
        localPath: path,
        displayName: displayName,
      );
      if (!mounted) return;
      setState(() {
        _localPath = path;
        _bundle = SongAnalysisBundle(
          reference: reference,
          lyricCues: const <LyricSyncCue>[],
          chordCues: const <ChordCue>[],
        );
        _progress = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _analyze() async {
    final reference = _bundle?.reference;
    if (_working || reference == null) return;
    setState(() {
      _working = true;
      _error = null;
      _progress = const SongAnalysisProgress('Preparing analysis', 0.01);
    });
    try {
      final localPath = _localPath ?? await _service.ensureLocalReference(reference);
      final bundle = await _service.analyze(
        project: widget.project,
        reference: reference,
        localPath: localPath,
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );
      if (!mounted) return;
      setState(() {
        _bundle = bundle;
        _localPath = localPath;
        _progress = null;
      });
    } catch (error) {
      // Reset _working here, immediately, rather than only in `finally` —
      // the refresh below is a network call, and while it's in flight
      // `_working` staying true kept every action button disabled and the
      // stale progress bar on screen for its whole duration (which reads as
      // "the app is stuck" if that call is slow). Reload the bundle
      // silently afterward without disturbing the error message: _refresh()
      // clears _error on success, which would otherwise wipe the message
      // out from under the user moments after showing it.
      if (mounted) setState(() => _error = error.toString());
      if (mounted) setState(() => _working = false);
      try {
        final bundle = await _service.load(widget.project.id);
        if (mounted) setState(() => _bundle = bundle);
      } catch (_) {
        // Non-fatal: we already have a bundle and an error message to show.
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _removeReference() async {
    final reference = _bundle?.reference;
    if (_working || reference == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove this recording?'),
        content: const Text(
          'This deletes the reference recording along with its synced lyric and chord timing. You can add a new recording afterward.',
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFF718B)),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await _service.removeReference(reference);
      if (!mounted) return;
      setState(() {
        _bundle = const SongAnalysisBundle(
          reference: null,
          lyricCues: <LyricSyncCue>[],
          chordCues: <ChordCue>[],
        );
        _localPath = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _openLive() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => LivePerformanceScreen(project: widget.project, analysis: _bundle),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bundle = _bundle;
    final reference = bundle?.reference;
    final ready = bundle?.ready ?? false;
    return Scaffold(
      backgroundColor: AppColors.deepNavy,
      appBar: AppBar(
        title: const Text('Analyze Song'),
        backgroundColor: AppColors.deepNavy,
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 40),
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                        decoration: BoxDecoration(
                          color: AppColors.cyan.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: AppColors.cyan.withValues(alpha: 0.3)),
                        ),
                        child: const Text(
                          'PREMIUM PREVIEW',
                          style: TextStyle(
                            color: AppColors.cyan,
                            fontSize: 9,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.15,
                          ),
                        ),
                      ),
                      const Spacer(),
                      Text(
                        widget.project.title,
                        style: const TextStyle(color: AppColors.muted, fontSize: 11),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Text(
                    reference == null ? 'Add a reference recording' : reference.displayName,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          color: AppColors.text,
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    reference == null
                        ? 'Use a rehearsal, demo, or finished mix. CoLabRoom will match the sung words to your lyrics and map the chord changes.'
                        : ready
                            ? 'This song now has a timed lyric map and chord map for Live mode.'
                            : 'Ready to analyze the recording against the lyrics in this Room.',
                    style: const TextStyle(color: AppColors.muted, height: 1.45, fontSize: 12),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const Key('choose_reference_recording'),
                          onPressed: _working ? null : _pickReferenceSource,
                          icon: const Icon(Icons.audio_file_rounded),
                          label: Text(reference == null ? 'Add a recording' : 'Replace recording'),
                        ),
                      ),
                      if (reference != null) ...<Widget>[
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton.icon(
                            key: const Key('analyze_reference_recording'),
                            onPressed: _working ? null : _analyze,
                            icon: const Icon(Icons.auto_awesome_rounded),
                            label: Text(ready ? 'Analyze again' : 'Analyze song'),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (reference != null) ...<Widget>[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const Key('remove_reference_recording'),
                        onPressed: _working ? null : _removeReference,
                        style: TextButton.styleFrom(foregroundColor: const Color(0xFFFF9AA9)),
                        icon: const Icon(Icons.delete_outline_rounded, size: 18),
                        label: const Text('Remove recording'),
                      ),
                    ),
                  ],
                  if (_working && _progress != null) ...<Widget>[
                    const SizedBox(height: 18),
                    LinearProgressIndicator(value: _progress!.fraction.clamp(0, 1)),
                    const SizedBox(height: 7),
                    Text(
                      _progress!.label,
                      style: const TextStyle(color: AppColors.muted, fontSize: 10.5),
                    ),
                  ],
                  if (_error != null) ...<Widget>[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF718B).withValues(alpha: 0.09),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        _cleanError(_error!),
                        style: const TextStyle(color: Color(0xFFFFA0B0), fontSize: 11.5),
                      ),
                    ),
                  ],
                  if (reference != null && !ready) ...<Widget>[
                    const SizedBox(height: 20),
                    const _QuietNote(
                      icon: Icons.download_for_offline_outlined,
                      text: 'The first analysis downloads a compact on-device speech model once. Analysis then runs on the phone; the recording stays available to the Room as its reference track.',
                    ),
                  ],
                  if (ready) ...<Widget>[
                    const SizedBox(height: 22),
                    _AnalysisSummary(bundle: bundle!),
                    const SizedBox(height: 18),
                    Text(
                      'Chord sheet',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: AppColors.text,
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const SizedBox(height: 10),
                    SongSheetPanel(
                      project: widget.project,
                      bundle: bundle,
                      onReviewLyrics: () => Navigator.of(context).pop(),
                      onOpenLive: _openLive,
                      onAnalysisChanged: (updated) => setState(() => _bundle = updated),
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}

class _AnalysisSummary extends StatelessWidget {
  const _AnalysisSummary({required this.bundle});

  final SongAnalysisBundle bundle;

  @override
  Widget build(BuildContext context) {
    final ref = bundle.reference!;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.035),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Wrap(
        spacing: 18,
        runSpacing: 12,
        children: <Widget>[
          _Metric(label: 'Length', value: _clockMs(ref.durationMs ?? 0)),
          _Metric(label: 'Key / center', value: ref.musicalKey ?? '—'),
          _Metric(label: 'Timed lines', value: '${bundle.lyricCues.length}'),
          _Metric(label: 'Chord changes', value: '${bundle.chordCues.length}'),
          _Metric(label: 'Lyric match', value: _percent(ref.lyricConfidence)),
          _Metric(label: 'Chord confidence', value: _percent(ref.chordConfidence)),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 92,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 9.5)),
          const SizedBox(height: 3),
          Text(
            value,
            style: const TextStyle(color: AppColors.text, fontSize: 14, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}

class _QuietNote extends StatelessWidget {
  const _QuietNote({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 17, color: AppColors.muted),
        const SizedBox(width: 9),
        Expanded(
          child: Text(text, style: const TextStyle(color: AppColors.muted, fontSize: 10.5, height: 1.4)),
        ),
      ],
    );
  }
}

String _clockMs(int milliseconds) {
  final total = (milliseconds / 1000).round();
  final minutes = total ~/ 60;
  final seconds = total % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

String _percent(double? value) => value == null ? '—' : '${(value * 100).round()}%';

String _cleanError(String value) {
  final cleaned = value.replaceFirst('Exception: ', '').replaceFirst('Bad state: ', '');
  return cleaned.length > 240 ? '${cleaned.substring(0, 240)}…' : cleaned;
}
