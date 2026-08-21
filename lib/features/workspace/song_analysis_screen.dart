import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../domain/song_analysis_models.dart';
import '../../services/song_analysis_service.dart';
import '../studio/instrument_chips.dart';
import '../studio/structure_timeline.dart';
import 'continuous_song_editor.dart';
import 'live_performance_screen.dart';
import 'lyric_review_screen.dart';
import 'musician_sheet_logic.dart';
import 'reference_recorder_sheet.dart';
import 'song_sheet_panel.dart';

enum _ReferenceSource { record, file }

class SongAnalysisScreen extends StatefulWidget {
  const SongAnalysisScreen({required this.project, this.autoRecord = false, super.key});

  final SongProject project;

  /// When true (the "Record Audio" song-menu entry), jump straight into the
  /// recorder instead of landing on this screen's "Add/Replace recording"
  /// button first.
  final bool autoRecord;

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
    unawaited(_refresh().then((_) {
      if (widget.autoRecord && mounted && !_working) {
        setState(() => _working = true);
        unawaited(_recordReference());
      }
    }));
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
    // Set _working before the sheet even opens — otherwise this button
    // stays tappable for the whole record/choose-file/attach flow (until
    // _attachLocalFile finally sets it), and repeated taps in that window
    // each independently open their own bottom sheet or push their own
    // recorder screen, stacking duplicates. Same class of bug as the
    // "Remove recording" dialog freeze.
    setState(() => _working = true);
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
                leading: const Icon(Icons.mic_rounded, color: AppColors.gold),
                title: const Text('Record now'),
                subtitle: const Text('Capture a take with this phone\'s microphone'),
                onTap: () => Navigator.pop(sheetContext, _ReferenceSource.record),
              ),
              ListTile(
                key: const Key('pick_source_file'),
                leading: const Icon(Icons.audio_file_rounded, color: AppColors.gold),
                title: const Text('Choose a file'),
                subtitle: const Text('Pick an existing recording, demo, or mix'),
                onTap: () => Navigator.pop(sheetContext, _ReferenceSource.file),
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
    if (path == null || !mounted) {
      if (mounted) setState(() => _working = false);
      return;
    }
    await _attachLocalFile(path: path, displayName: '${widget.project.title} (recorded)');
  }

  Future<void> _chooseRecording() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const <String>['mp3', 'm4a', 'wav', 'flac', 'ogg', 'opus', 'aac'],
    );
    if (file == null || file.path == null || !mounted) {
      if (mounted) setState(() => _working = false);
      return;
    }
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
    // Set _working before the confirmation dialog even opens, not after it
    // resolves — otherwise the "Remove recording" button stays enabled for
    // as long as the dialog is up, and repeated taps each independently
    // call showDialog, stacking duplicate confirmation dialogs on top of
    // each other. Each "Remove" tap then only closes the top one, which
    // looks identical to the one underneath — like the dialog is frozen —
    // and the extra open dialogs can outlive whatever route is beneath them
    // if the screen changes underneath in the meantime.
    setState(() => _working = true);
    final confirmed = await showDialog<bool>(
      context: context,
      // showDialog defaults to the root navigator, but this app also has a
      // nested workspace Navigator (see workspace_shell.dart). Popping with
      // the outer `context` here (instead of this builder's own
      // dialogContext) pops the wrong navigator's top route — it closes
      // this screen instead of the dialog, while the dialog itself is left
      // open and orphaned on top, blocking input. That's the actual "goes
      // back a screen and freezes" bug, not dialog stacking.
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove this recording?'),
        content: const Text(
          'This deletes the reference recording along with its synced lyric and chord timing. You can add a new recording afterward.',
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Keep')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFF718B)),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      if (mounted) setState(() => _working = false);
      return;
    }
    setState(() => _error = null);
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

  Future<void> _reviewLyrics() async {
    final reference = _bundle?.reference;
    if (reference == null) return;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => LyricReviewScreen(project: widget.project, reference: reference),
        fullscreenDialog: true,
      ),
    );
    if (saved == true && mounted) {
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Transcript updated — the Song Sheet and Live Performance now use these corrections.')),
      );
    }
  }

  Future<void> _replaceProjectLyrics() async {
    final reference = _bundle?.reference;
    if (_working || reference == null) return;
    final lines = _service.transcriptLyricLines(reference);
    if (lines.isEmpty) return;
    final hasExisting = widget.project.contributions.any((line) => line.body.trim().isNotEmpty);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Replace project lyrics?'),
        content: Text(
          hasExisting
              ? 'This replaces everything currently in the project\'s lyrics with the words heard in this recording. This can\'t be undone.'
              : 'This writes the words heard in this recording into the project\'s lyrics, so you don\'t have to retype them.',
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _working = true);
    try {
      final controller = BetaScope.of(context);
      for (final line in widget.project.contributions) {
        await controller.deleteContribution(line);
      }
      await controller.importContributions(
        widget.project,
        lines.map((body) => ContributionDraft(body: body)).toList(growable: false),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Project lyrics replaced with this recording\'s transcript.')),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// The mirror of _replaceProjectLyrics: when analysis mis-heard the
  /// recording but the manual workspace already has the right words, this
  /// pushes those words into the transcript instead, so the Song Sheet and
  /// Live Performance end up correct regardless of which side was right.
  /// Lines get proportional timing across the recording (same fallback
  /// _transcriptLines uses for a transcript with no per-word timestamps) —
  /// approximate, but enough to keep Live Performance's scroll roughly in
  /// the right place.
  Future<void> _replaceAnalyzedLyrics() async {
    final reference = _bundle?.reference;
    if (_working || reference == null) return;
    final lyrics = visibleMusicianLyrics(widget.project);
    if (lyrics.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Replace Song Sheet lyrics?'),
        content: const Text(
          'This replaces the analyzed transcript with the project\'s manual lyrics, spread evenly across '
          'the recording. The Song Sheet and Live Performance will use these instead. This can\'t be undone.',
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.gold, foregroundColor: AppColors.ink),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _working = true);
    try {
      final durationMs = reference.durationMs ?? math.max(12000, lyrics.length * 3600);
      final words = <TranscriptWord>[];
      // Live Performance's Song Sheet mode (musician_sheet_logic.dart's
      // _transcriptLines) doesn't use the original contribution lines at
      // all — it re-derives line breaks from the transcript by looking for
      // a >=650ms pause between consecutive words. proportionalSheetRange
      // gives each line a perfectly contiguous span (line i's end exactly
      // equals line i+1's start), so with no gap reserved here it never
      // finds a pause and instead re-chunks by raw word count, producing
      // completely different — and wrong — line groupings than what was
      // actually typed. Reserving a real gap at the end of each line's
      // span is what makes that re-segmentation land back on the real
      // line boundaries.
      const lineGapMs = 700;
      for (var i = 0; i < lyrics.length; i += 1) {
        final text = displayContributionBody(lyrics[i].body).trim();
        if (text.isEmpty) continue;
        final lineWords = text.split(RegExp(r'\s+'));
        final range = proportionalSheetRange(i, lyrics.length, durationMs);
        final span = math.max(120, range.$2 - range.$1 - lineGapMs);
        final step = span / lineWords.length;
        for (var w = 0; w < lineWords.length; w += 1) {
          words.add(TranscriptWord(
            word: lineWords[w],
            startMs: (range.$1 + step * w).round(),
            endMs: (range.$1 + step * (w + 1)).round(),
          ));
        }
      }
      final updated = await _service.updateTranscript(projectId: widget.project.id, words: words);
      if (!mounted) return;
      setState(() => _bundle = updated);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Song Sheet updated with the manual lyrics.')),
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
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
                          color: AppColors.gold.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: AppColors.gold.withValues(alpha: 0.3)),
                        ),
                        child: const Text(
                          'PREMIUM PREVIEW',
                          style: TextStyle(
                            color: AppColors.gold,
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
                    style: GoogleFonts.fraunces(
                      color: AppColors.text,
                      fontSize: 26,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    reference == null
                        ? 'Use a rehearsal, demo, or finished mix. If this project already has lyrics, CoLabRoom times them to the recording; if not, it builds a separate song sheet from what you sing — your project\'s own lyrics stay untouched either way.'
                        : ready
                            ? 'This song now has a timed lyric map and chord map for Live mode.'
                            : 'Ready to analyze the recording. If the project has lyrics, they\'ll be timed to this take — otherwise this builds a separate song sheet from what it hears, without touching the project\'s own lyrics.',
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
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.gold,
                              foregroundColor: AppColors.ink,
                            ),
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
                    LinearProgressIndicator(
                      value: _progress!.fraction.clamp(0, 1),
                      color: AppColors.gold,
                    ),
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
                  if (_error == null && ready && reference?.analysisWarning != null) ...<Widget>[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.orange.withValues(alpha: 0.09),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Icon(Icons.info_outline_rounded, size: 16, color: AppColors.orange),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              reference!.analysisWarning!,
                              style: const TextStyle(color: AppColors.orange, fontSize: 11.5, height: 1.4),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (reference != null && !ready) ...<Widget>[
                    const SizedBox(height: 20),
                    const _QuietNote(
                      icon: Icons.cloud_outlined,
                      text: 'This recording is analyzed off-device to keep results accurate, then stays saved to the Room as its reference track.',
                    ),
                  ],
                  // These two don't require the *latest* analysis attempt to
                  // have succeeded (`ready`) — they only need a reference to
                  // attach a Song Sheet to, plus whichever side (manual or
                  // analyzed) has the words to copy from. Gating them behind
                  // `ready` used to hide them entirely whenever an analysis
                  // attempt errored, even if a usable Song Sheet already
                  // existed from an earlier successful run.
                  if (reference != null && visibleMusicianLyrics(widget.project).isNotEmpty) ...<Widget>[
                    const SizedBox(height: 20),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const Key('replace_analyzed_lyrics'),
                        onPressed: _working ? null : _replaceAnalyzedLyrics,
                        style: TextButton.styleFrom(foregroundColor: AppColors.cyan),
                        icon: const Icon(Icons.edit_note_rounded, size: 18),
                        label: const Text('Fix the Song Sheet using my typed lyrics'),
                      ),
                    ),
                  ],
                  if (reference?.transcriptWords.isNotEmpty ?? false) ...<Widget>[
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const Key('replace_project_lyrics'),
                        onPressed: _working ? null : _replaceProjectLyrics,
                        style: TextButton.styleFrom(foregroundColor: AppColors.gold),
                        icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                        label: const Text('Fill in my lyrics from the Song Sheet'),
                      ),
                    ),
                  ],
                  if (ready) ...<Widget>[
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Icon(Icons.check_rounded, size: 14, color: AppColors.muted),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            'Saved to this project.',
                            style: const TextStyle(color: AppColors.muted, fontSize: 11.5, height: 1.4),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _AnalysisSummary(bundle: bundle!),
                    _SongUnderstanding(reference: bundle.reference!),
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
                      onReviewLyrics: (reference?.transcriptWords.isNotEmpty ?? false) ? _reviewLyrics : null,
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
          _Metric(label: 'BPM', value: ref.bpm != null ? ref.bpm!.round().toString() : '—'),
          _Metric(label: 'Timed lines', value: '${bundle.lyricCues.length}'),
          _Metric(label: 'Chord changes', value: '${bundle.chordCues.length}'),
          _Metric(label: 'Lyric match', value: _percent(ref.lyricConfidence)),
          _Metric(label: 'Chord confidence', value: _percent(ref.chordConfidence)),
        ],
      ),
    );
  }
}

/// "Explain My Song" — the structure/instrument breakdown the Studio engine
/// produces, shown right here rather than behind a separate action: since
/// SongAnalysisService.analyze() already writes bpm/structure/instruments
/// onto this same reference the moment analysis completes, there's nothing
/// left to "put into" the song — it's already in it.
class _SongUnderstanding extends StatelessWidget {
  const _SongUnderstanding({required this.reference});

  final ReferenceTrack reference;

  @override
  Widget build(BuildContext context) {
    if (reference.structureSections.isEmpty && reference.instruments == null) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const SizedBox(height: 18),
        const Text(
          'Structure',
          style: TextStyle(color: AppColors.text, fontSize: 15, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        StructureTimeline(sections: reference.structureSections),
        const SizedBox(height: 18),
        const Text(
          'Instruments',
          style: TextStyle(color: AppColors.text, fontSize: 15, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        InstrumentChips(instruments: reference.instruments),
      ],
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
