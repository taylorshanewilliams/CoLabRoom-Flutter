import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../domain/song_analysis_models.dart';
import '../../domain/studio_draft_models.dart';
import '../../services/audio_analysis_utils.dart';
import '../../services/studio_draft_service.dart';
import '../../widgets/analysis_depth_sheet.dart';
import '../workspace/musician_sheet_logic.dart';
import '../workspace/musician_song_sheet.dart';
import '../workspace/song_workspace_screen.dart';
import '../workspace/stem_player_panel.dart';
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

  Future<void> _renameSection(StudioDraft draft, String label, String? name) async {
    try {
      await _service.renameSection(draft: draft, label: label, name: name);
      await _refresh();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Could not rename that part: $error')));
    }
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
    // Asked before anything starts — see showAnalysisDepthSheet. Dismissing
    // leaves the idea unanalyzed rather than quietly picking one.
    final depth = await showAnalysisDepthSheet(context, title: 'Analyze this idea');
    if (depth == null || !mounted) {
      setState(() => _working = false);
      return;
    }
    setState(() {
      _working = true;
      _error = null;
      _progress = const SongAnalysisProgress('Preparing audio', 0.02);
    });
    try {
      final localPath = widget.localPath ?? await _service.ensureLocalDraftFile(widget.draft);
      final resumeJobId = await _service.resumableJobId(widget.draft.id);
      final bundle = await _service.analyze(
        draft: widget.draft,
        localPath: localPath,
        depth: depth,
        resumeJobId: resumeJobId,
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
              _AudioPreviewPlayer(draft: draft, service: _service),
              const SizedBox(height: 20),
              Wrap(
                spacing: 22,
                runSpacing: 14,
                children: <Widget>[
                  _Metric('Length', _formatDuration(draft.durationMs)),
                  _Metric('Key', draft.musicalKey ?? '—'),
                  _Metric('BPM', draft.bpm != null ? draft.bpm!.round().toString() : 'Not available yet'),
                  // Counted from the gaps between detected downbeats. Shown
                  // as x/4 because a beat tracker knows how many beats are in
                  // a bar but not what note value gets the beat — 6/8 and 6/4
                  // are indistinguishable from timing alone, so claiming the
                  // denominator would be inventing it.
                  _Metric(
                    'Time signature',
                    draft.beatsPerBar != null ? '${draft.beatsPerBar}/4' : 'Not available yet',
                  ),
                  if (draft.downbeatsMs.isNotEmpty)
                    _Metric('Bars', '${draft.downbeatsMs.length}'),
                  // Coverage, not confidence — see chordCoverage(). The old
                  // percentage was a constant, identical on every recording.
                  _Metric(
                    'Chords cover',
                    draft.chordCoverage != null ? '${(draft.chordCoverage! * 100).round()}%' : '—',
                  ),
                ],
              ),
              const SizedBox(height: 22),
              const Text(
                'Structure',
                style: TextStyle(color: AppColors.text, fontSize: 15, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 10),
              StructureTimeline(
                sections: draft.structureSections,
                onRename: (label, name) => unawaited(_renameSection(draft, label, name)),
              ),
              const SizedBox(height: 22),
              const Text(
                'Instruments',
                style: TextStyle(color: AppColors.text, fontSize: 15, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 10),
              InstrumentChips(instruments: draft.instruments),
              // Pulling an idea apart is most useful on a rough take: what
              // exactly did I play under that vocal, and what was the bass
              // doing. Projects have had this since stems were kept; Studio
              // was throwing its stems away.
              StemPlayerPanel(
                stems: bundle.stems,
                ensureLocalStem: _service.ensureLocalStem,
                downbeatsMs: draft.downbeatsMs,
              ),
              const SizedBox(height: 22),
              const Text(
                'Song Sheet',
                style: TextStyle(color: AppColors.text, fontSize: 15, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 10),
              MusicianSongSheet(
                title: draft.displayName,
                lines: transcriptSheetLines(
                  transcriptWords: draft.transcriptWords,
                  transcriptText: draft.transcriptText,
                  chordCues: bundle.chordCues,
                  durationMs: draft.durationMs ?? 0,
                  downbeatsMs: draft.downbeatsMs,
                ),
                musicalKey: draft.musicalKey,
                transpose: 0,
                fontScale: 1,
                showChords: true,
              ),
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

/// Lets you hear the recording while reading the sheet it produced — the
/// player itself is lazy: nothing downloads or plays until the first tap,
/// same lazy-download shape as ensureLocalDraftFile already uses elsewhere.
class _AudioPreviewPlayer extends StatefulWidget {
  const _AudioPreviewPlayer({required this.draft, required this.service});

  final StudioDraft draft;
  final StudioDraftService service;

  @override
  State<_AudioPreviewPlayer> createState() => _AudioPreviewPlayerState();
}

class _AudioPreviewPlayerState extends State<_AudioPreviewPlayer> {
  AudioPlayer? _player;
  bool _loading = false;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<void>? _completeSub;
  String? _error;

  @override
  void dispose() {
    unawaited(_positionSub?.cancel());
    unawaited(_durationSub?.cancel());
    unawaited(_completeSub?.cancel());
    unawaited(_player?.dispose());
    super.dispose();
  }

  Future<void> _togglePlay() async {
    if (_error != null) setState(() => _error = null);
    var player = _player;
    if (player == null) {
      setState(() => _loading = true);
      try {
        final path = await widget.service.ensureLocalDraftFile(widget.draft);
        if (!mounted) return;
        player = AudioPlayer();
        await player.setSource(DeviceFileSource(path));
        _positionSub = player.onPositionChanged.listen((position) {
          if (mounted) setState(() => _position = position);
        });
        _durationSub = player.onDurationChanged.listen((duration) {
          if (mounted) setState(() => _duration = duration);
        });
        _completeSub = player.onPlayerComplete.listen((_) {
          if (mounted) setState(() => _playing = false);
        });
        if (!mounted) {
          await player.dispose();
          return;
        }
        setState(() {
          _player = player;
          _loading = false;
        });
      } catch (error) {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = error.toString();
          });
        }
        return;
      }
    }
    setState(() => _playing = !_playing);
    unawaited(_playing ? player.resume() : player.pause());
  }

  String _formatMs(int ms) {
    final totalSeconds = ms ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final durationMs = _duration.inMilliseconds > 0
        ? _duration.inMilliseconds
        : (widget.draft.durationMs ?? 0);
    final rawPositionMs = _position.inMilliseconds;
    final positionMs = rawPositionMs < 0 ? 0 : (rawPositionMs > durationMs ? durationMs : rawPositionMs);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.raised,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        children: <Widget>[
          IconButton(
            key: const Key('studio_preview_play'),
            onPressed: _loading ? null : _togglePlay,
            icon: _loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.gold),
                  )
                : Icon(
                    _playing ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded,
                    color: AppColors.gold,
                    size: 32,
                  ),
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  ),
                  child: Slider(
                    value: positionMs.toDouble(),
                    max: durationMs > 0 ? durationMs.toDouble() : 1,
                    activeColor: AppColors.gold,
                    inactiveColor: AppColors.line,
                    onChanged: _player == null
                        ? null
                        : (value) {
                            unawaited(_player!.seek(Duration(milliseconds: value.round())));
                          },
                  ),
                ),
                Text(
                  '${_formatMs(positionMs)} / ${_formatMs(durationMs)}',
                  style: const TextStyle(color: AppColors.muted, fontSize: 10.5),
                ),
                if (_error != null)
                  Text(_error!, style: const TextStyle(color: Color(0xFFFFA0B0), fontSize: 10.5)),
              ],
            ),
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
