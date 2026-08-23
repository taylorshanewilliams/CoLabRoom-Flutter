import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show FontFeature;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/song_analysis_models.dart';
import '../../services/chord_beat_grid.dart';

/// Plays the separated instrument stems Demucs produced during analysis —
/// one at a time, deliberately.
///
/// Simultaneous multi-stem playback (a real mixer with mute/solo) needs
/// sample-accurate sync between independent players, which drifts badly on
/// mobile without a shared clock. Soloing a single stem is both the common
/// case — isolate the guitar to learn the part, mute yourself to sing over
/// the band — and the one that's honestly achievable with one player.
///
/// The transport below the chips belongs to whichever stem is soloed, and the
/// position survives switching between them: every stem is the same
/// recording, so landing on the same moment of the bass that you just left in
/// the guitar is the only behaviour that makes sense when you're working out
/// a part.
class StemPlayerPanel extends StatefulWidget {
  const StemPlayerPanel({
    required this.stems,
    required this.ensureLocalStem,
    this.downbeatsMs = const <int>[],
    super.key,
  });

  final List<SongStem> stems;

  /// Downloads (and caches) a stem, returning a local file path. Passed in
  /// rather than taking a service, because project stems and Studio stems
  /// live in different buckets and the player has no business knowing which
  /// it's looking at.
  final Future<String> Function(SongStem) ensureLocalStem;

  /// The recording's bar lines, when analysis found them. Turns the playhead
  /// from a stopwatch reading into a position in the song — which is what you
  /// want when the thing you're trying to learn is "the fill in bar 33".
  final List<int> downbeatsMs;

  @override
  State<StemPlayerPanel> createState() => _StemPlayerPanelState();
}

class _StemPlayerPanelState extends State<StemPlayerPanel> {
  AudioPlayer? _player;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<void>? _completeSubscription;

  SongStem? _selected;
  StemKind? _loading;
  bool _playing = false;
  String? _error;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  /// Where the thumb is while a drag is in progress. Non-null means the
  /// position stream is ignored — otherwise the playhead and the finger fight
  /// over the slider.
  int? _scrubbingMs;

  @override
  void dispose() {
    unawaited(_positionSubscription?.cancel());
    unawaited(_durationSubscription?.cancel());
    unawaited(_completeSubscription?.cancel());
    final player = _player;
    if (player != null) unawaited(player.dispose());
    super.dispose();
  }

  AudioPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final player = AudioPlayer();
    _positionSubscription = player.onPositionChanged.listen((position) {
      if (!mounted || _scrubbingMs != null) return;
      setState(() => _position = position);
    });
    _durationSubscription = player.onDurationChanged.listen((duration) {
      if (!mounted) return;
      setState(() => _duration = duration);
    });
    _completeSubscription = player.onPlayerComplete.listen((_) {
      if (!mounted) return;
      setState(() {
        _playing = false;
        _position = Duration.zero;
      });
    });
    _player = player;
    return player;
  }

  Future<void> _select(SongStem stem) async {
    if (_selected?.kind == stem.kind) {
      await _togglePlayPause();
      return;
    }
    final player = _ensurePlayer();
    // Where you were in the song, which is where you still want to be.
    final resumeAt = _position;
    setState(() {
      _loading = stem.kind;
      _error = null;
    });
    try {
      // Cached to a local file on first play — a stem is a few MB, and
      // switching between stems while learning a part would otherwise
      // re-download every time.
      final path = await widget.ensureLocalStem(stem);
      await player.stop();
      await player.setSource(DeviceFileSource(path));
      final keepPosition = resumeAt > Duration.zero && resumeAt < _duration;
      if (keepPosition) await player.seek(resumeAt);
      await player.resume();
      if (mounted) {
        setState(() {
          _selected = stem;
          _loading = null;
          _playing = true;
          _position = keepPosition ? resumeAt : Duration.zero;
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

  Future<void> _togglePlayPause() async {
    final player = _player;
    if (player == null || _selected == null) return;
    if (_playing) {
      await player.pause();
      if (mounted) setState(() => _playing = false);
    } else {
      await player.resume();
      if (mounted) setState(() => _playing = true);
    }
  }

  Future<void> _seekTo(int milliseconds) async {
    final player = _player;
    final target = Duration(milliseconds: milliseconds);
    setState(() {
      _position = target;
      _scrubbingMs = null;
    });
    if (player != null) await player.seek(target);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.stems.isEmpty) return const SizedBox.shrink();
    final selected = _selected;
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
                selected: _selected?.kind == stem.kind,
                playing: _playing && _selected?.kind == stem.kind,
                loading: _loading == stem.kind,
                onTap: _loading == null ? () => _select(stem) : null,
              ),
          ],
        ),
        if (selected != null) ...<Widget>[
          const SizedBox(height: 12),
          _StemTransport(
            stemLabel: selected.kind.label,
            playing: _playing,
            positionMs: _scrubbingMs ?? _position.inMilliseconds,
            durationMs: _duration.inMilliseconds,
            downbeatsMs: widget.downbeatsMs,
            onPlayPause: _togglePlayPause,
            onScrub: (milliseconds) => setState(() => _scrubbingMs = milliseconds),
            onScrubEnd: _seekTo,
          ),
        ],
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

String _clock(int milliseconds) {
  final total = milliseconds < 0 ? 0 : milliseconds ~/ 1000;
  final minutes = total ~/ 60;
  final seconds = total % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// Play/pause and a scrub bar for the stem currently soloed.
class _StemTransport extends StatelessWidget {
  const _StemTransport({
    required this.stemLabel,
    required this.playing,
    required this.positionMs,
    required this.durationMs,
    required this.downbeatsMs,
    required this.onPlayPause,
    required this.onScrub,
    required this.onScrubEnd,
  });

  final String stemLabel;
  final bool playing;
  final int positionMs;
  final int durationMs;
  final List<int> downbeatsMs;
  final Future<void> Function() onPlayPause;
  final ValueChanged<int> onScrub;
  final ValueChanged<int> onScrubEnd;

  @override
  Widget build(BuildContext context) {
    // Until the file reports its length there is nothing to scrub along, so
    // the bar sits inert rather than jumping about at a made-up length.
    final ready = durationMs > 0;
    final value = positionMs.clamp(0, math.max(1, durationMs)).toDouble();
    final bar = barNumberAt(positionMs, downbeatsMs);
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.035),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        children: <Widget>[
          Semantics(
            button: true,
            label: '${playing ? 'Pause' : 'Play'} $stemLabel track',
            child: IconButton(
              onPressed: () => unawaited(onPlayPause()),
              iconSize: 28,
              padding: const EdgeInsets.all(6),
              constraints: const BoxConstraints(),
              icon: Icon(
                playing ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded,
                color: AppColors.gold,
              ),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                activeTrackColor: AppColors.gold,
                inactiveTrackColor: Colors.white.withValues(alpha: 0.12),
                thumbColor: AppColors.gold,
                overlayColor: AppColors.gold.withValues(alpha: 0.14),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                value: ready ? value : 0,
                max: math.max(1, durationMs).toDouble(),
                // The readout sits to the right of the bar, which is exactly
                // where a thumb covers it mid-drag — so the thumb carries it
                // too.
                label: _clock(positionMs),
                onChanged: ready ? (next) => onScrub(next.round()) : null,
                onChangeEnd: ready ? (next) => onScrubEnd(next.round()) : null,
                semanticFormatterCallback: (next) =>
                    '${_clock(next.round())} of ${_clock(durationMs)}',
              ),
            ),
          ),
          const SizedBox(width: 2),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                ready ? '${_clock(positionMs)} / ${_clock(durationMs)}' : '—',
                style: const TextStyle(
                  color: AppColors.text,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  // Tabular figures so the readout doesn't twitch sideways
                  // every time a digit changes while it counts up.
                  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
              if (bar != null)
                Text(
                  'bar $bar',
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StemChip extends StatelessWidget {
  const _StemChip({
    required this.stem,
    required this.selected,
    required this.playing,
    required this.loading,
    required this.onTap,
  });

  final SongStem stem;
  final bool selected;
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
    final accent = selected ? AppColors.gold : AppColors.muted;
    return Semantics(
      button: true,
      selected: selected,
      label: 'Solo ${stem.kind.label} track',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? AppColors.gold.withValues(alpha: 0.14) : Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? AppColors.gold.withValues(alpha: 0.45) : AppColors.line,
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
                Icon(
                  // A chip says what the stem is; whether it's sounding right
                  // now is the transport's job. Only the soloed chip swaps its
                  // instrument for a state, and it shows pause rather than
                  // stop because pause is what tapping it does now.
                  playing ? Icons.pause_rounded : _icon,
                  size: 16,
                  color: accent,
                ),
              const SizedBox(width: 8),
              Text(
                stem.kind.label,
                style: TextStyle(
                  color: selected ? AppColors.gold : AppColors.text,
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
