import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/name_policy.dart';
import '../../domain/song_analysis_models.dart';
import '../../domain/studio_draft_models.dart';
import '../../services/studio_draft_service.dart';
import '../workspace/reference_recorder_sheet.dart';
import 'draft_search.dart';
import 'studio_results_screen.dart';

enum _UploadSource { record, file }

/// What somebody came here to do, which is a different question from where
/// the audio comes from.
///
/// The sheet used to offer only the two sources — microphone, file — and then
/// every recording walked into the analyzer, because the results screen opens
/// the depth sheet as its first act. Anybody who only wanted to put an idea
/// down had to notice a sheet they had not asked for and refuse it, and
/// refusing a question is not the same as choosing an answer. The cost is
/// ours either way.
///
/// Asked as an intent rather than as a third source, deliberately. "Record
/// now / Choose a file / No analysis" reads as three sources, and nobody can
/// tell whether the third one uses the microphone.
enum _Intent {
  /// Free. An idea to build on, which is what takes are for.
  idea,

  /// The expensive one: separation, chords, key, words.
  workOut,
}

enum _StudioView { active, promoted }

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
  String _query = '';
  String? _keyFilter;
  _StudioView _view = _StudioView.active;

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
    var intent = _Intent.idea;
    final choice = await showModalBottomSheet<_UploadSource>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: AppColors.deepNavy,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'What is this for?',
                  style: TextStyle(
                      color: AppColors.text,
                      fontSize: 17,
                      fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 12),
                SegmentedButton<_Intent>(
                  segments: const <ButtonSegment<_Intent>>[
                    ButtonSegment<_Intent>(
                      value: _Intent.idea,
                      icon: Icon(Icons.graphic_eq_rounded, size: 17),
                      label: Text('An idea'),
                    ),
                    ButtonSegment<_Intent>(
                      value: _Intent.workOut,
                      icon: Icon(Icons.auto_awesome_rounded, size: 17),
                      label: Text('Work it out'),
                    ),
                  ],
                  selected: <_Intent>{intent},
                  onSelectionChanged: (selection) =>
                      setSheetState(() => intent = selection.first),
                ),
                const SizedBox(height: 10),
                Text(
                  intent == _Intent.idea
                      ? 'Put it down and build on it. Nothing is analyzed, '
                          'nothing is charged, and you can add takes over it '
                          'once it belongs to a song.'
                      : 'Separates the instruments, finds the chords and key, '
                          'and transcribes the words. A couple of minutes, and '
                          'it cannot be stopped once it starts.',
                  style: const TextStyle(
                      color: AppColors.muted, fontSize: 12.5, height: 1.45),
                ),
                const SizedBox(height: 14),
                ListTile(
                  key: const Key('studio_pick_record'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.mic_rounded, color: AppColors.gold),
                  title: const Text('Record now'),
                  subtitle:
                      const Text('Using this phone’s microphone'),
                  onTap: () => Navigator.pop(sheetContext, _UploadSource.record),
                ),
                ListTile(
                  key: const Key('studio_pick_file'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.audio_file_rounded,
                      color: AppColors.gold),
                  title: const Text('Choose a file'),
                  subtitle: const Text(
                      'A demo, voice memo, or mix from your phone'),
                  onTap: () => Navigator.pop(sheetContext, _UploadSource.file),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted || choice == null) {
      if (mounted) setState(() => _working = false);
      return;
    }
    final analyze = intent == _Intent.workOut;
    switch (choice) {
      case _UploadSource.record:
        await _record(analyze: analyze);
      case _UploadSource.file:
        await _pickFile(analyze: analyze);
    }
  }

  Future<void> _record({required bool analyze}) async {
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
    await _upload(path: path, displayName: label, analyze: analyze);
  }

  Future<void> _pickFile({required bool analyze}) async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const <String>['mp3', 'm4a', 'wav', 'flac', 'ogg', 'opus', 'aac'],
    );
    if (file == null || file.path == null || !mounted) {
      if (mounted) setState(() => _working = false);
      return;
    }

    // Confirm before starting. Picking a file used to begin analysis on the
    // spot — a multi-minute job with no way to stop it — so tapping the wrong
    // row in a file browser meant waiting it out. Showing the name that was
    // actually picked is the point: it's the only chance to notice the wrong
    // one before the GPU starts.
    //
    // Only for the intent that actually starts one. An idea costs nothing and
    // asking somebody to confirm it teaches them to dismiss this dialog.
    final confirmed = !analyze
        ? true
        : await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Analyze this recording?'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(file.name, style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 10),
              const Text(
                'This separates the instruments, finds the chords and key, and '
                'transcribes the words. It usually takes a couple of minutes and '
                'can’t be stopped once it starts.',
                style: TextStyle(color: AppColors.muted, fontSize: 12.5, height: 1.45),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('studio_confirm_analyze'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Analyze'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      if (mounted) setState(() => _working = false);
      return;
    }

    await _upload(path: file.path!, displayName: file.name, analyze: analyze);
  }

  Future<void> _upload({
    required String path,
    required String displayName,
    required bool analyze,
  }) async {
    try {
      final draft = await _service.createDraftAndUpload(localPath: path, displayName: displayName);
      if (!mounted) return;
      setState(() => _working = false);
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => StudioResultsScreen(
            draft: draft,
            localPath: path,
            autoAnalyze: analyze,
          ),
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
        // Opening something already recorded must not start a job. The
        // screen offers analysis; it no longer assumes it.
        builder: (_) => StudioResultsScreen(draft: draft, autoAnalyze: false),
        fullscreenDialog: true,
      ),
    );
    unawaited(_refresh());
  }

  Future<void> _renameDraft(StudioDraft draft) async {
    final controller = TextEditingController(text: draft.displayName);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename recording'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || !mounted) return;
    String cleaned;
    try {
      NamePolicy.requireUsable(name, label: 'Recording name');
      cleaned = NamePolicy.clean(name);
    } catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
      return;
    }
    final previous = _drafts;
    setState(() {
      _drafts = _drafts
          ?.map((d) => d.id == draft.id ? _withDisplayName(d, cleaned) : d)
          .toList(growable: false);
    });
    try {
      await _service.renameDraft(draft, cleaned);
    } catch (error) {
      if (!mounted) return;
      setState(() => _drafts = previous);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  StudioDraft _withDisplayName(StudioDraft draft, String displayName) {
    return StudioDraft(
      id: draft.id,
      accountId: draft.accountId,
      displayName: displayName,
      storagePath: draft.storagePath,
      state: draft.state,
      createdAt: draft.createdAt,
      mimeType: draft.mimeType,
      byteSize: draft.byteSize,
      durationMs: draft.durationMs,
      bpm: draft.bpm,
      musicalKey: draft.musicalKey,
      analyzerVersion: draft.analyzerVersion,
      chordConfidence: draft.chordConfidence,
      transcriptText: draft.transcriptText,
      transcriptWords: draft.transcriptWords,
      structureSections: draft.structureSections,
      instruments: draft.instruments,
      analysisWarning: draft.analysisWarning,
      lastError: draft.lastError,
      promotedProjectId: draft.promotedProjectId,
    );
  }

  Future<void> _deleteDraft(StudioDraft draft) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this recording?'),
        content: Text(
          'This removes "${draft.displayName}" and its analysis. This can\'t be undone.',
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Keep')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFF718B)),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final previous = _drafts;
    // Remove optimistically — deleteDraft's own storage cleanup is
    // non-fatal-if-it-fails (see StudioDraftService), so the row being gone
    // from the list shouldn't wait on that.
    setState(() => _drafts = _drafts?.where((d) => d.id != draft.id).toList(growable: false));
    try {
      await _service.deleteDraft(draft);
    } catch (error) {
      if (!mounted) return;
      setState(() => _drafts = previous);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    final allDrafts = _drafts;
    final showingActive = _view == _StudioView.active;
    final query = NamePolicy.normalized(_query);
    final inView = allDrafts
        ?.where((draft) => draft.isPromoted != showingActive)
        .toList(growable: false);
    final keys = inView == null ? const <String>[] : availableKeys(inView);
    // A key filter that survives switching views only if that key still
    // exists there — otherwise the list silently reads as empty.
    final activeKey = keys.contains(_keyFilter) ? _keyFilter : null;
    final results = inView == null
        ? null
        : searchDrafts(
            activeKey == null
                ? inView
                : inView.where((draft) => draft.musicalKey == activeKey).toList(growable: false),
            _query,
          );

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
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
          sliver: SliverToBoxAdapter(
            child: SegmentedButton<_StudioView>(
              segments: const <ButtonSegment<_StudioView>>[
                ButtonSegment<_StudioView>(
                  value: _StudioView.active,
                  icon: Icon(Icons.mic_rounded),
                  label: Text('Ideas'),
                ),
                // "Promoted" was the internal word for a draft that became a
                // project, shipped straight to the user as a tab label.
                ButtonSegment<_StudioView>(
                  value: _StudioView.promoted,
                  icon: Icon(Icons.check_circle_rounded),
                  label: Text('Used in a song'),
                ),
              ],
              selected: <_StudioView>{_view},
              onSelectionChanged: (selection) => setState(() => _view = selection.first),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
          sliver: SliverToBoxAdapter(
            child: TextField(
              key: const Key('studio_search_field'),
              onChanged: (value) => setState(() => _query = value),
              decoration: const InputDecoration(
                // Searching the words is what makes a pile of takes usable —
                // audio can't be skimmed, but a half-remembered line is
                // enough to find the recording it came from.
                hintText: 'Search by name or a line you sang',
                prefixIcon: Icon(Icons.search_rounded),
              ),
            ),
          ),
        ),
        // Only keys that actually occur are offered. "Something in A minor
        // for the bridge" is a real question a writer has, and nothing else
        // can answer it — but a chip for a key you have nothing in is noise.
        if (keys.length > 1)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
            sliver: SliverToBoxAdapter(
              child: SizedBox(
                height: 34,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: <Widget>[
                    _KeyChip(
                      label: 'Any key',
                      selected: activeKey == null,
                      onTap: () => setState(() => _keyFilter = null),
                    ),
                    for (final key in keys)
                      _KeyChip(
                        label: key,
                        selected: activeKey == key,
                        onTap: () => setState(
                          () => _keyFilter = activeKey == key ? null : key,
                        ),
                      ),
                  ],
                ),
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
        if (results == null)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          )
        else if (results.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Text(
                  _emptyStateMessage(showingActive: showingActive, hasQuery: query.isNotEmpty),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.muted, fontSize: 13),
                ),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 6, 18, 24),
            sliver: SliverList.separated(
              itemCount: results.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) => _DraftTile(
                draft: results[index].draft,
                lyricSnippet: results[index].lyricSnippet,
                onTap: () => _openDraft(results[index].draft),
                onRename: () => _renameDraft(results[index].draft),
                onDelete: () => _deleteDraft(results[index].draft),
              ),
            ),
          ),
      ],
    );
  }

  String _emptyStateMessage({required bool showingActive, required bool hasQuery}) {
    if (hasQuery) return 'No recordings match “$_query”.';
    if (showingActive) {
      return 'No recordings yet. Tap "New Recording" to detect your first song\'s key, chords, and structure.';
    }
    return 'Nothing promoted yet — recordings show up here once you tap "Create Song Project" on them.';
  }
}

/// Key · tempo · length, skipping whatever isn't known yet rather than
/// printing a row of dashes. Falls back to the analysis state so a draft
/// that hasn't been analyzed still says something true about itself.
String _draftSummary(StudioDraft draft) {
  final parts = <String>[
    if ((draft.musicalKey ?? '').isNotEmpty) draft.musicalKey!,
    if (draft.bpm != null) '${draft.bpm!.round()} BPM',
    if (draft.durationMs != null && draft.durationMs! > 0) _clock(draft.durationMs!),
  ];
  if (parts.isEmpty) return _stateLabel(draft.state);
  if (draft.isPromoted) parts.add('used in a song');
  return parts.join(' · ');
}

String _clock(int ms) {
  final totalSeconds = ms ~/ 1000;
  return '${totalSeconds ~/ 60}:${(totalSeconds % 60).toString().padLeft(2, '0')}';
}

String _stateLabel(SongAnalysisState state) => switch (state) {
      SongAnalysisState.uploaded => 'Uploaded',
      SongAnalysisState.queued => 'Queued',
      SongAnalysisState.processing => 'Analyzing…',
      SongAnalysisState.ready => 'Ready',
      SongAnalysisState.failed => 'Analysis failed',
    };

class _KeyChip extends StatelessWidget {
  const _KeyChip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(17),
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: selected ? AppColors.gold.withValues(alpha: 0.16) : AppColors.surface,
            borderRadius: BorderRadius.circular(17),
            border: Border.all(color: selected ? AppColors.gold : AppColors.line),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? AppColors.gold : AppColors.muted,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _DraftTile extends StatelessWidget {
  const _DraftTile({
    required this.draft,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
    this.lyricSnippet,
  });

  final StudioDraft draft;

  /// Set when this row matched on the words rather than the title — shown so
  /// the result explains why it's here.
  final String? lyricSnippet;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 6, 14),
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
                  // Key, tempo and length on every row, so eighty ideas can
                  // be scanned with your eyes instead of played one by one.
                  // That skim is the difference between a library and a pile.
                  Text(
                    _draftSummary(draft),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
                  ),
                  if (lyricSnippet != null) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      '“$lyricSnippet”',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.gold,
                        fontSize: 11.5,
                        fontStyle: FontStyle.italic,
                        height: 1.35,
                      ),
                    ),
                  ] else if (draft.transcriptText != null &&
                      draft.transcriptText!.trim().isNotEmpty) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      draft.transcriptText!.trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 11.5,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            _StateChip(state: draft.state, promoted: draft.isPromoted),
            PopupMenuButton<VoidCallback>(
              key: const Key('studio_draft_menu'),
              tooltip: 'Recording options',
              icon: const Icon(Icons.more_vert_rounded, size: 19, color: AppColors.muted),
              onSelected: (action) => action(),
              itemBuilder: (_) => <PopupMenuEntry<VoidCallback>>[
                PopupMenuItem<VoidCallback>(
                  value: onRename,
                  child: const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.edit_rounded),
                    title: Text('Rename'),
                  ),
                ),
                PopupMenuItem<VoidCallback>(
                  value: onDelete,
                  child: const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.delete_outline_rounded, color: Color(0xFFFF718B)),
                    title: Text('Delete'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

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
