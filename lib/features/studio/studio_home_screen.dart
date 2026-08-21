import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/song_analysis_models.dart';
import '../../domain/studio_draft_models.dart';
import '../../services/studio_draft_service.dart';
import '../workspace/reference_recorder_sheet.dart';
import 'studio_results_screen.dart';

enum _UploadSource { record, file }

/// The Studio tab — upload a raw demo with no project yet and get key/BPM/
/// structure/chords/lyrics back, then turn it into a real song project.
/// "Explain My Song" (same engine, run against an *existing* project's
/// reference) lives inside song_analysis_screen.dart instead, since it
/// needs a project context this tab deliberately doesn't have.
class StudioHomeScreen extends StatefulWidget {
  const StudioHomeScreen({super.key});

  @override
  State<StudioHomeScreen> createState() => _StudioHomeScreenState();
}

class _StudioHomeScreenState extends State<StudioHomeScreen> {
  final StudioDraftService _service = StudioDraftService();
  List<StudioDraft>? _drafts;
  bool _working = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      final drafts = await _service.listDrafts();
      if (!mounted) return;
      setState(() {
        _drafts = drafts;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    }
  }

  Future<void> _newRecording() async {
    if (_working) return;
    // Same "set working before the sheet even opens" guard as
    // song_analysis_screen.dart's _pickReferenceSource — otherwise repeated
    // taps while the sheet/recorder/picker is up each independently kick
    // off their own flow.
    setState(() => _working = true);
    final choice = await showModalBottomSheet<_UploadSource>(
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
                key: const Key('studio_pick_record'),
                leading: const Icon(Icons.mic_rounded, color: AppColors.gold),
                title: const Text('Record now'),
                subtitle: const Text('Capture a take with this phone\'s microphone'),
                onTap: () => Navigator.pop(sheetContext, _UploadSource.record),
              ),
              ListTile(
                key: const Key('studio_pick_file'),
                leading: const Icon(Icons.audio_file_rounded, color: AppColors.gold),
                title: const Text('Choose a file'),
                subtitle: const Text('Pick a demo, voice memo, or mix from your phone'),
                onTap: () => Navigator.pop(sheetContext, _UploadSource.file),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || choice == null) {
      if (mounted) setState(() => _working = false);
      return;
    }
    switch (choice) {
      case _UploadSource.record:
        await _record();
      case _UploadSource.file:
        await _pickFile();
    }
  }

  Future<void> _record() async {
    final path = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => Scaffold(
          backgroundColor: AppColors.deepNavy,
          body: const ReferenceRecorderSheet(songTitle: 'New Song'),
        ),
        fullscreenDialog: true,
      ),
    );
    if (path == null || !mounted) {
      if (mounted) setState(() => _working = false);
      return;
    }
    final now = DateTime.now();
    final label =
        'Recording ${now.month}/${now.day} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    await _upload(path: path, displayName: label);
  }

  Future<void> _pickFile() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const <String>['mp3', 'm4a', 'wav', 'flac', 'ogg', 'opus', 'aac'],
    );
    if (file == null || file.path == null || !mounted) {
      if (mounted) setState(() => _working = false);
      return;
    }
    await _upload(path: file.path!, displayName: file.name);
  }

  Future<void> _upload({required String path, required String displayName}) async {
    try {
      final draft = await _service.createDraftAndUpload(localPath: path, displayName: displayName);
      if (!mounted) return;
      setState(() => _working = false);
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => StudioResultsScreen(draft: draft, localPath: path),
          fullscreenDialog: true,
        ),
      );
      unawaited(_refresh());
    } catch (error) {
      if (mounted) {
        setState(() => _working = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> _openDraft(StudioDraft draft) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StudioResultsScreen(draft: draft),
        fullscreenDialog: true,
      ),
    );
    unawaited(_refresh());
  }

  @override
  Widget build(BuildContext context) {
    final drafts = _drafts;
    return CustomScrollView(
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 10),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text('The Studio', style: Theme.of(context).textTheme.displaySmall),
                ),
                FilledButton.icon(
                  key: const Key('studio_new_recording'),
                  onPressed: _working ? null : _newRecording,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.gold,
                    foregroundColor: AppColors.ink,
                  ),
                  icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                  label: const Text('New Recording'),
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 4),
          sliver: SliverToBoxAdapter(
            child: Text(
              'Upload a demo or rough idea — CoLabRoom detects the key, chords, '
              'structure, and lyrics before you\'ve even made it a song yet.',
              style: const TextStyle(color: AppColors.muted, fontSize: 12.5, height: 1.4),
            ),
          ),
        ),
        if (_error != null)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
            sliver: SliverToBoxAdapter(
              child: Text(_error!, style: const TextStyle(color: Color(0xFFFFA0B0), fontSize: 12)),
            ),
          ),
        if (drafts == null)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          )
        else if (drafts.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Text(
                  'No recordings yet. Tap "New Recording" to detect your first song\'s key, chords, and structure.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.muted, fontSize: 13),
                ),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 6, 18, 24),
            sliver: SliverList.separated(
              itemCount: drafts.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) => _DraftTile(
                draft: drafts[index],
                onTap: () => _openDraft(drafts[index]),
              ),
            ),
          ),
      ],
    );
  }
}

class _DraftTile extends StatelessWidget {
  const _DraftTile({required this.draft, required this.onTap});

  final StudioDraft draft;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.raised,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.line),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    draft.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.text, fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    draft.isPromoted
                        ? 'Promoted to a song project'
                        : draft.musicalKey != null
                            ? 'Key ${draft.musicalKey}${draft.bpm != null ? ' · ${draft.bpm!.round()} BPM' : ''}'
                            : _stateLabel(draft.state),
                    style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
                  ),
                ],
              ),
            ),
            _StateChip(state: draft.state, promoted: draft.isPromoted),
          ],
        ),
      ),
    );
  }

  String _stateLabel(SongAnalysisState state) => switch (state) {
        SongAnalysisState.uploaded => 'Uploaded',
        SongAnalysisState.queued => 'Queued',
        SongAnalysisState.processing => 'Analyzing…',
        SongAnalysisState.ready => 'Ready',
        SongAnalysisState.failed => 'Analysis failed',
      };
}

class _StateChip extends StatelessWidget {
  const _StateChip({required this.state, required this.promoted});

  final SongAnalysisState state;
  final bool promoted;

  @override
  Widget build(BuildContext context) {
    final Color color = promoted
        ? AppColors.green
        : switch (state) {
            SongAnalysisState.ready => AppColors.gold,
            SongAnalysisState.failed => const Color(0xFFFF718B),
            SongAnalysisState.processing || SongAnalysisState.queued => AppColors.cyan,
            SongAnalysisState.uploaded => AppColors.muted,
          };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Icon(
        promoted ? Icons.check_circle_rounded : Icons.circle,
        size: promoted ? 14 : 8,
        color: color,
      ),
    );
  }
}
