import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../domain/song_analysis_models.dart';
import '../../domain/studio_draft_models.dart';
import '../../services/audio_analysis_utils.dart';
import '../../services/studio_draft_service.dart';
import '../workspace/song_workspace_screen.dart';
import 'instrument_chips.dart';
import 'structure_timeline.dart';

/// "NEW SONG DETECTED" — shown right after uploading to The Studio (runs
/// analysis immediately if the draft isn't already `ready`), or when
/// reopening a past draft from the list. Mirrors song_analysis_screen.dart's
/// upload -> progress -> summary-metrics -> results shape, but has no
/// project/room to render a full chord+lyric sheet against yet — that's
/// exactly what "Create Song Project" produces.
class StudioResultsScreen extends StatefulWidget {
  const StudioResultsScreen({required this.draft, this.localPath, super.key});

  final StudioDraft draft;

  /// Local file path for a just-uploaded recording, so analysis doesn't
  /// need to re-download it. Null when reopening an existing draft later —
  /// [StudioDraftService.ensureLocalDraftFile] re-downloads then.
  final String? localPath;

  @override
  State<StudioResultsScreen> createState() => _StudioResultsScreenState();
}

class _StudioResultsScreenState extends State<StudioResultsScreen> {
  final StudioDraftService _service = StudioDraftService();
  StudioDraftBundle? _bundle;
  bool _working = true;
  bool _promoting = false;
  SongAnalysisProgress? _progress;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(widget.draft.state == SongAnalysisState.ready ? _refresh() : _runAnalysis());
  }

  Future<void> _refresh() async {
    try {
      final bundle = await _service.load(widget.draft.id);
      if (!mounted) return;
      setState(() {
        _bundle = bundle;
        _working = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _working = false;
      });
    }
  }

  Future<void> _runAnalysis() async {
    setState(() {
      _working = true;
      _error = null;
      _progress = const SongAnalysisProgress('Preparing audio', 0.02);
    });
    try {
      final localPath = widget.localPath ?? await _service.ensureLocalDraftFile(widget.draft);
      final bundle = await _service.analyze(
        draft: widget.draft,
        localPath: localPath,
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );
      if (!mounted) return;
      setState(() {
        _bundle = bundle;
        _progress = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
      try {
        final bundle = await _service.load(widget.draft.id);
        if (mounted) setState(() => _bundle = bundle);
      } catch (_) {
        // Non-fatal: we already have an error message to show.
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _createSongProject() async {
    final bundle = _bundle;
    if (bundle == null || _promoting) return;
    setState(() => _promoting = true);
    try {
      final controller = BetaScope.of(context);
      final project = await _service.promoteToProject(context, controller, bundle.draft);
      if (project == null || !mounted) return; // user cancelled room/title selection
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => SongWorkspaceScreen(projectId: project.id)),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _promoting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bundle = _bundle;
    final draft = bundle?.draft ?? widget.draft;
    return Scaffold(
      backgroundColor: AppColors.deepNavy,
      appBar: AppBar(
        title: const Text('New Song Detected'),
        backgroundColor: AppColors.deepNavy,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 100),
          children: <Widget>[
            Text(
              draft.displayName,
              style: const TextStyle(color: AppColors.text, fontSize: 24, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 18),
            if (_working) _AnalyzingRing(progress: _progress),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF718B).withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(_error!, style: const TextStyle(color: Color(0xFFFFA0B0), fontSize: 11.5)),
              ),
            ],
            if (draft.analysisWarning != null) ...<Widget>[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.orange.withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  draft.analysisWarning!,
                  style: const TextStyle(color: AppColors.orange, fontSize: 11.5, height: 1.4),
                ),
              ),
            ],
            if (bundle != null) ...<Widget>[
              const SizedBox(height: 20),
              Wrap(
                spacing: 22,
                runSpacing: 14,
                children: <Widget>[
                  _Metric('Length', _formatDuration(draft.durationMs)),
                  _Metric('Key', draft.musicalKey ?? '—'),
                  _Metric('BPM', draft.bpm != null ? draft.bpm!.round().toString() : 'Not available yet'),
                  _Metric('Time signature', 'Not available yet'),
                  _Metric(
                    'Chord confidence',
                    draft.chordConfidence != null ? '${(draft.chordConfidence! * 100).round()}%' : '—',
                  ),
                ],
              ),
              const SizedBox(height: 22),
              const Text(
                'Structure',
                style: TextStyle(color: AppColors.text, fontSize: 15, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 10),
              StructureTimeline(sections: draft.structureSections),
              const SizedBox(height: 22),
              const Text(
                'Instruments',
                style: TextStyle(color: AppColors.text, fontSize: 15, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 10),
              InstrumentChips(instruments: draft.instruments),
              const SizedBox(height: 22),
              const Text(
                'Chords',
                style: TextStyle(color: AppColors.text, fontSize: 15, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(
                _chordProgression(bundle.chordCues),
                style: const TextStyle(color: AppColors.gold, fontSize: 14, fontWeight: FontWeight.w700),
              ),
              if (draft.hasTranscript) ...<Widget>[
                const SizedBox(height: 22),
                const Text(
                  'Lyrics',
                  style: TextStyle(color: AppColors.text, fontSize: 15, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                Text(
                  draft.transcriptText ?? '',
                  style: const TextStyle(color: AppColors.muted, fontSize: 13, height: 1.5),
                ),
              ],
            ],
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
          child: FilledButton(
            key: const Key('create_song_project'),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.gold,
              foregroundColor: AppColors.ink,
              minimumSize: const Size.fromHeight(50),
            ),
            onPressed: bundle == null || _working || _promoting ? null : _createSongProject,
            child: _promoting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.ink),
                  )
                : const Text('Create Song Project', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ),
      ),
    );
  }

  String _formatDuration(int? ms) {
    if (ms == null) return '—';
    final totalSeconds = ms ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  String _chordProgression(List<ChordCue> cues) {
    if (cues.isEmpty) return 'No chords detected';
    final unique = <String>[];
    for (final cue in cues) {
      if (unique.isEmpty || unique.last != cue.chord) unique.add(cue.chord);
    }
    return unique.join('  –  ');
  }
}

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 130,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 11)),
          const SizedBox(height: 3),
          Text(
            value,
            style: const TextStyle(color: AppColors.text, fontSize: 17, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}

/// A progress ring + step checklist rather than a flat linear bar — matches
/// the premium-tier "studio" feel used elsewhere (Analyze/Song Sheet/Live),
/// and gives the wait something to look at beyond a percentage.
class _AnalyzingRing extends StatelessWidget {
  const _AnalyzingRing({required this.progress});

  final SongAnalysisProgress? progress;

  static const _steps = <(String, double)>[
    ('Preparing audio', 0.05),
    ('Listening & transcribing', 0.2),
    ('Analyzing chords & structure', 0.55),
    ('Saving your song map', 0.9),
  ];

  @override
  Widget build(BuildContext context) {
    final fraction = progress?.fraction ?? 0.0;
    return Column(
      children: <Widget>[
        AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          width: 108,
          height: 108,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            // Bloom grows with progress — a bare sliver of glow at the
            // start, a proper gold halo by the time it's nearly done.
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: AppColors.gold.withValues(alpha: 0.18 + fraction * 0.32),
                blurRadius: 22 + fraction * 26,
                spreadRadius: 1 + fraction * 3,
              ),
            ],
          ),
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              SizedBox(
                width: 108,
                height: 108,
                child: CircularProgressIndicator(
                  value: fraction,
                  strokeWidth: 6,
                  backgroundColor: AppColors.raised,
                  color: AppColors.gold,
                ),
              ),
              Text(
                '${(fraction * 100).round()}%',
                style: const TextStyle(color: AppColors.text, fontSize: 20, fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text(
          progress?.label ?? 'Working…',
          style: const TextStyle(color: AppColors.gold, fontSize: 13, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 18),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final step in _steps)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: <Widget>[
                    Icon(
                      fraction >= step.$2 ? Icons.check_circle_rounded : Icons.circle_outlined,
                      size: 16,
                      color: fraction >= step.$2 ? AppColors.gold : AppColors.muted,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      step.$1,
                      style: TextStyle(
                        color: fraction >= step.$2 ? AppColors.text : AppColors.muted,
                        fontSize: 12.5,
                        fontWeight: fraction >= step.$2 ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}
