import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/song_analysis_models.dart';
import '../../services/song_analysis_service.dart';

/// Plays the separated instrument stems Demucs produced during analysis —
/// one at a time, deliberately.
///
/// Simultaneous multi-stem playback (a real mixer with mute/solo) needs
/// sample-accurate sync between independent players, which drifts badly on
/// mobile without a shared clock. Soloing a single stem is both the common
/// case — isolate the guitar to learn the part, mute yourself to sing over
/// the band — and the one that's honestly achievable with one player.
class StemPlayerPanel extends StatefulWidget {
  const StemPlayerPanel({required this.stems, required this.service, super.key});

  final List<SongStem> stems;
  final SongAnalysisService service;

  @override
  State<StemPlayerPanel> createState() => _StemPlayerPanelState();
}

class _StemPlayerPanelState extends State<StemPlayerPanel> {
  AudioPlayer? _player;
  StreamSubscription<void>? _completeSubscription;
  StemKind? _playing;
  StemKind? _loading;
  String? _error;

  @override
  void dispose() {
    _completeSubscription?.cancel();
    final player = _player;
    if (player != null) unawaited(player.dispose());
    super.dispose();
  }

  Future<void> _toggle(SongStem stem) async {
    final player = _player ??= AudioPlayer();
    _completeSubscription ??= player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playing = null);
    });

    if (_playing == stem.kind) {
      await player.stop();
      if (mounted) setState(() => _playing = null);
      return;
    }

    await player.stop();
    setState(() {
      _loading = stem.kind;
      _playing = null;
      _error = null;
    });
    try {
      // Cached to a local file on first play — a stem is a few MB, and
      // scrubbing between stems while learning a part would otherwise
      // re-download every time.
      final path = await widget.service.ensureLocalStem(stem);
      await player.play(DeviceFileSource(path));
      if (mounted) {
        setState(() {
          _playing = stem.kind;
          _loading = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = null;
          _error = 'Could not play that stem. $error';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.stems.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const SizedBox(height: 18),
        const Text(
          'Isolated tracks',
          style: TextStyle(color: AppColors.text, fontSize: 15, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        const Text(
          'Play any single instrument on its own — one at a time.',
          style: TextStyle(color: AppColors.muted, fontSize: 12),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final stem in widget.stems)
              _StemChip(
                stem: stem,
                playing: _playing == stem.kind,
                loading: _loading == stem.kind,
                onTap: _loading == null ? () => _toggle(stem) : null,
              ),
          ],
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: 10),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 11.5),
          ),
        ],
      ],
    );
  }
}

class _StemChip extends StatelessWidget {
  const _StemChip({
    required this.stem,
    required this.playing,
    required this.loading,
    required this.onTap,
  });

  final SongStem stem;
  final bool playing;
  final bool loading;
  final VoidCallback? onTap;

  IconData get _icon {
    switch (stem.kind) {
      case StemKind.vocals:
        return Icons.mic_none_rounded;
      case StemKind.drums:
        return Icons.album_rounded;
      case StemKind.bass:
        return Icons.graphic_eq_rounded;
      case StemKind.guitar:
        return Icons.music_note_rounded;
      case StemKind.piano:
        return Icons.piano_rounded;
      case StemKind.other:
        return Icons.blur_on_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = playing ? AppColors.gold : AppColors.muted;
    return Semantics(
      button: true,
      label: '${playing ? 'Stop' : 'Play'} ${stem.kind.label} track',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          decoration: BoxDecoration(
            color: playing ? AppColors.gold.withValues(alpha: 0.14) : Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: playing ? AppColors.gold.withValues(alpha: 0.45) : AppColors.line,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (loading)
                const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.muted),
                )
              else
                Icon(playing ? Icons.stop_rounded : _icon, size: 16, color: accent),
              const SizedBox(width: 8),
              Text(
                stem.kind.label,
                style: TextStyle(
                  color: playing ? AppColors.gold : AppColors.text,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
