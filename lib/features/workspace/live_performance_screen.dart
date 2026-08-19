import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../domain/song_analysis_models.dart';
import 'continuous_song_editor.dart';

enum LiveScrollMode { off, synced, slow, medium, fast, timed }

class LivePerformanceScreen extends StatefulWidget {
  const LivePerformanceScreen({required this.project, this.analysis, super.key});

  final SongProject project;

  /// Analyzed sync data for this song (from Song Analysis), if any. When
  /// this has real per-line timing (`hasSyncedLyrics`), Live mode drives the
  /// scroll position off the actual lyric timestamps instead of a constant
  /// speed, and highlights the line that should be sung right now.
  final SongAnalysisBundle? analysis;

  @override
  State<LivePerformanceScreen> createState() => _LivePerformanceScreenState();
}

class _LivePerformanceScreenState extends State<LivePerformanceScreen> {
  final ScrollController _scroll = ScrollController();
  final GlobalKey _contentKey = GlobalKey();
  final Map<String, GlobalKey> _lineKeys = <String, GlobalKey>{};
  Map<String, double> _lineOffsets = <String, double>{};
  bool _offsetsDirty = true;

  Timer? _ticker;
  Timer? _hideControls;
  DateTime? _lastTick;
  LiveScrollMode _mode = LiveScrollMode.off;
  bool _playing = false;
  bool _controlsVisible = true;
  double _fontScale = 1;
  Duration _songDuration = const Duration(minutes: 3, seconds: 30);
  Duration _elapsed = Duration.zero;
  String? _activeContributionId;
  String? _lastLayoutKey;

  bool get _hasSync => widget.analysis?.hasSyncedLyrics ?? false;

  List<LyricSyncCue> get _sortedCues {
    final cues = List<LyricSyncCue>.from(widget.analysis?.lyricCues ?? const <LyricSyncCue>[]);
    cues.sort((a, b) => a.startMs.compareTo(b.startMs));
    return cues;
  }

  @override
  void initState() {
    super.initState();
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    _mode = _hasSync ? LiveScrollMode.synced : LiveScrollMode.off;
    if (_hasSync) {
      final track = widget.analysis?.reference;
      final lastCueEnd = _sortedCues.isEmpty ? 0 : _sortedCues.last.endMs;
      final durationMs = track?.durationMs ?? lastCueEnd;
      if (durationMs > 0) _songDuration = Duration(milliseconds: durationMs);
    }
    _ticker = Timer.periodic(const Duration(milliseconds: 50), (_) => _tick());
    _armControlHide();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _hideControls?.cancel();
    _scroll.dispose();
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  /// Measures the vertical offset of each lyric line within the scrollable
  /// content so synced mode can map a cue timestamp to a scroll position.
  void _captureLineOffsets() {
    final contentBox = _contentKey.currentContext?.findRenderObject() as RenderBox?;
    if (contentBox == null || !contentBox.hasSize) return;
    final offsets = <String, double>{};
    for (final entry in _lineKeys.entries) {
      final lineBox = entry.value.currentContext?.findRenderObject() as RenderBox?;
      if (lineBox == null || !lineBox.attached) continue;
      offsets[entry.key] = lineBox.localToGlobal(Offset.zero, ancestor: contentBox).dy;
    }
    if (offsets.isEmpty) return;
    _lineOffsets = offsets;
    _offsetsDirty = false;
  }

  void _markOffsetsDirty() {
    _offsetsDirty = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _captureLineOffsets();
    });
  }

  void _tick() {
    if (!_playing || !_scroll.hasClients) {
      _lastTick = null;
      return;
    }
    final now = DateTime.now();
    final previous = _lastTick ?? now;
    _lastTick = now;
    final delta = now.difference(previous);
    if (delta <= Duration.zero) return;
    _elapsed += delta;

    if (_offsetsDirty && _mode == LiveScrollMode.synced) _captureLineOffsets();

    final position = _scroll.position;
    final maxExtent = position.maxScrollExtent;
    if (maxExtent <= 0) return;

    if (_mode == LiveScrollMode.synced) {
      _tickSynced(position, maxExtent);
      return;
    }

    final pixelsPerSecond = switch (_mode) {
      LiveScrollMode.slow => 9.5,
      LiveScrollMode.medium => 17.0,
      LiveScrollMode.fast => 27.0,
      LiveScrollMode.timed => _timedPixelsPerSecond(maxExtent),
      LiveScrollMode.synced || LiveScrollMode.off => 0.0,
    };
    if (pixelsPerSecond <= 0) return;

    final next = math
        .min(
          maxExtent,
          position.pixels +
              pixelsPerSecond * delta.inMicroseconds / Duration.microsecondsPerSecond,
        )
        .toDouble();
    if ((next - position.pixels).abs() > 0.01) {
      position.jumpTo(next);
    }
    if (next >= maxExtent - 0.5) {
      setState(() => _playing = false);
      _lastTick = null;
    } else if (_mode == LiveScrollMode.timed && _elapsed >= _songDuration) {
      position.jumpTo(maxExtent);
      setState(() => _playing = false);
      _lastTick = null;
    } else if (mounted && _mode == LiveScrollMode.timed) {
      setState(() {});
    }
  }

  void _tickSynced(ScrollPosition position, double maxExtent) {
    final elapsedMs = _elapsed.inMilliseconds;
    final cues = _sortedCues;
    if (cues.isEmpty) {
      setState(() => _playing = false);
      _lastTick = null;
      return;
    }

    final target = _syncedScrollTarget(cues, elapsedMs, maxExtent);
    if (target != null && (target - position.pixels).abs() > 0.01) {
      position.jumpTo(target.clamp(0.0, maxExtent));
    }

    final activeCue = _cueAt(cues, elapsedMs);
    final nextActiveId = activeCue?.contributionId;
    final songEndMs = _songDuration.inMilliseconds;
    final finished = songEndMs > 0 ? elapsedMs >= songEndMs : elapsedMs >= cues.last.endMs;

    if (finished) {
      position.jumpTo(maxExtent);
      setState(() {
        _playing = false;
        _activeContributionId = nextActiveId;
      });
      _lastTick = null;
    } else if (mounted) {
      setState(() => _activeContributionId = nextActiveId);
    }
  }

  /// Finds the cue that should be highlighted as "currently sung" at [elapsedMs].
  LyricSyncCue? _cueAt(List<LyricSyncCue> cues, int elapsedMs) {
    LyricSyncCue? current;
    for (final cue in cues) {
      if (cue.startMs <= elapsedMs) {
        current = cue;
      } else {
        break;
      }
    }
    return current;
  }

  /// Maps [elapsedMs] to a scroll pixel offset by interpolating between the
  /// measured positions of the surrounding cued lines. This keeps the
  /// current line in view and naturally slows through instrumental gaps
  /// instead of assuming lyrics are spread evenly through the song.
  double? _syncedScrollTarget(List<LyricSyncCue> cues, int elapsedMs, double maxExtent) {
    if (_lineOffsets.isEmpty) return null;

    double? offsetFor(LyricSyncCue cue) => _lineOffsets[cue.contributionId];

    // Before the first cue: hold at the top of the first cued line.
    final first = cues.first;
    if (elapsedMs <= first.startMs) {
      return offsetFor(first) ?? 0;
    }
    // After the last cue: settle at the very bottom.
    final last = cues.last;
    if (elapsedMs >= last.endMs) {
      return maxExtent;
    }

    for (var i = 0; i < cues.length - 1; i++) {
      final current = cues[i];
      final next = cues[i + 1];
      if (elapsedMs >= current.startMs && elapsedMs < next.startMs) {
        final currentOffset = offsetFor(current);
        final nextOffset = offsetFor(next);
        if (currentOffset == null || nextOffset == null) return currentOffset ?? nextOffset;
        final span = next.startMs - current.startMs;
        if (span <= 0) return currentOffset;
        final progress = (elapsedMs - current.startMs) / span;
        return currentOffset + (nextOffset - currentOffset) * progress.clamp(0.0, 1.0);
      }
    }
    return offsetFor(last) ?? maxExtent;
  }

  double _timedPixelsPerSecond(double maxExtent) {
    final remainingTime = _songDuration - _elapsed;
    if (remainingTime <= Duration.zero) return maxExtent;
    final remainingPixels = math.max(0.0, maxExtent - _scroll.position.pixels).toDouble();
    return remainingPixels / (remainingTime.inMilliseconds / 1000);
  }

  void _armControlHide() {
    _hideControls?.cancel();
    if (!_playing) return;
    _hideControls = Timer(const Duration(seconds: 4), () {
      if (mounted && _playing) setState(() => _controlsVisible = false);
    });
  }

  void _showControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _armControlHide();
  }

  void _togglePlay() {
    setState(() {
      if (_mode == LiveScrollMode.off) {
        _mode = _hasSync ? LiveScrollMode.synced : LiveScrollMode.medium;
      }
      _playing = !_playing;
      _controlsVisible = true;
    });
    if (_mode == LiveScrollMode.synced) _markOffsetsDirty();
    _lastTick = null;
    _armControlHide();
  }

  void _restart() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() {
      _elapsed = Duration.zero;
      _playing = false;
      _controlsVisible = true;
      _activeContributionId = null;
    });
    _lastTick = null;
  }

  Future<void> _chooseTimedDuration() async {
    final result = await showModalBottomSheet<Duration>(
      context: context,
      backgroundColor: AppColors.deepNavy,
      showDragHandle: true,
      builder: (sheetContext) => _DurationSheet(initial: _songDuration),
    );
    if (result == null || !mounted) return;
    setState(() {
      _songDuration = result;
      _elapsed = Duration.zero;
      _mode = LiveScrollMode.timed;
      _playing = false;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _selectMode(LiveScrollMode mode) {
    if (mode == LiveScrollMode.timed) {
      unawaited(_chooseTimedDuration());
      return;
    }
    setState(() {
      _mode = mode;
      if (mode == LiveScrollMode.off) _playing = false;
      _elapsed = Duration.zero;
      _activeContributionId = null;
    });
    _lastTick = null;
    if (mode == LiveScrollMode.synced) _markOffsetsDirty();
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final landscape = media.orientation == Orientation.landscape;
    final baseSize = landscape ? 22.0 : 25.0;
    final lyricSize = baseSize * _fontScale;
    final sidePadding = landscape ? media.size.width * 0.12 : 24.0;
    final lines = widget.project.contributions;
    // If a layout-affecting input changed since the last measurement, the
    // line offsets used by synced-scroll need to be recaptured post-frame.
    final layoutKey = '$landscape:${_fontScale.toStringAsFixed(2)}:${lines.length}';
    if (layoutKey != _lastLayoutKey) {
      _lastLayoutKey = layoutKey;
      _markOffsetsDirty();
    }

    return PopScope(
      onPopInvokedWithResult: (_, __) {
        unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF01050C),
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _showControls,
          child: SafeArea(
            minimum: EdgeInsets.zero,
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: SingleChildScrollView(
                    key: const Key('live_lyrics_scroll'),
                    controller: _scroll,
                    physics: _playing
                        ? const NeverScrollableScrollPhysics()
                        : const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                    padding: EdgeInsets.fromLTRB(
                      sidePadding,
                      landscape ? 42 : 74,
                      sidePadding,
                      landscape ? 90 : 128,
                    ),
                    child: Column(
                      key: _contentKey,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Text(
                          widget.project.title,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.muted.withValues(alpha: 0.78),
                            fontSize: lyricSize * 0.48,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.1,
                          ),
                        ),
                        SizedBox(height: landscape ? 22 : 34),
                        for (final line in lines)
                          _PerformanceLine(
                            key: _lineKeys.putIfAbsent(line.id, () => GlobalKey()),
                            contribution: line,
                            fontSize: lyricSize,
                            compact: landscape,
                            active: _mode == LiveScrollMode.synced &&
                                line.id == _activeContributionId,
                          ),
                        SizedBox(height: media.size.height * 0.52),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: AnimatedSlide(
                    duration: const Duration(milliseconds: 180),
                    offset: _controlsVisible ? Offset.zero : const Offset(0, -1.2),
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 180),
                      opacity: _controlsVisible ? 1 : 0,
                      child: _TopLiveBar(
                        onClose: () => Navigator.maybePop(context),
                        onRestart: _restart,
                        onSmaller: () => setState(
                          () => _fontScale = (_fontScale - 0.08).clamp(0.72, 1.35).toDouble(),
                        ),
                        onLarger: () => setState(
                          () => _fontScale = (_fontScale + 0.08).clamp(0.72, 1.35).toDouble(),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 10,
                  child: AnimatedSlide(
                    duration: const Duration(milliseconds: 180),
                    offset: _controlsVisible ? Offset.zero : const Offset(0, 1.4),
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 180),
                      opacity: _controlsVisible ? 1 : 0,
                      child: _LiveControls(
                        mode: _mode,
                        playing: _playing,
                        elapsed: _elapsed,
                        duration: _songDuration,
                        hasSync: _hasSync,
                        onPlay: _togglePlay,
                        onMode: _selectMode,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PerformanceLine extends StatelessWidget {
  const _PerformanceLine({
    required this.contribution,
    required this.fontSize,
    required this.compact,
    this.active = false,
    super.key,
  });

  final Contribution contribution;
  final double fontSize;
  final bool compact;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final body = displayContributionBody(contribution.body);
    final section = contribution.kind == ContributionKind.section ||
        RegExp(r'^\s*\[[^\]]+\]\s*$').hasMatch(body);
    if (body.isEmpty) {
      return SizedBox(height: compact ? fontSize * 0.65 : fontSize * 0.9);
    }
    final baseColor = section ? AppColors.cyan.withValues(alpha: 0.92) : AppColors.text;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      padding: EdgeInsets.symmetric(vertical: compact ? 3 : 5, horizontal: active ? 8 : 0),
      margin: EdgeInsets.symmetric(vertical: active ? 2 : 0),
      decoration: BoxDecoration(
        color: active ? AppColors.cyan.withValues(alpha: 0.1) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.only(top: fontSize * 0.48, right: compact ? 9 : 12),
            child: Container(
              width: compact ? 5 : 6,
              height: compact ? 5 : 6,
              decoration: BoxDecoration(
                color: active ? AppColors.cyan : Color(contribution.colorValue),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Expanded(
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 220),
              style: TextStyle(
                color: active ? AppColors.text : baseColor.withValues(alpha: active ? 1 : 0.82),
                fontSize: section ? fontSize * 0.72 : fontSize,
                height: section ? 1.25 : 1.3,
                fontWeight: section
                    ? FontWeight.w800
                    : (active ? FontWeight.w700 : FontWeight.w500),
                letterSpacing: section ? 0.6 : 0.05,
              ),
              child: Text(body),
            ),
          ),
        ],
      ),
    );
  }
}

class _TopLiveBar extends StatelessWidget {
  const _TopLiveBar({
    required this.onClose,
    required this.onRestart,
    required this.onSmaller,
    required this.onLarger,
  });

  final VoidCallback onClose;
  final VoidCallback onRestart;
  final VoidCallback onSmaller;
  final VoidCallback onLarger;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            const Color(0xFF01050C).withValues(alpha: 0.96),
            const Color(0xFF01050C).withValues(alpha: 0.78),
          ],
        ),
      ),
      child: Row(
        children: <Widget>[
          IconButton(
            key: const Key('close_live_mode'),
            onPressed: onClose,
            tooltip: 'Exit Live mode',
            icon: const Icon(Icons.close_rounded),
          ),
          const Expanded(
            child: Text(
              'LIVE',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.cyan,
                fontSize: 11,
                fontWeight: FontWeight.w900,
                letterSpacing: 2.2,
              ),
            ),
          ),
          IconButton(
            onPressed: onRestart,
            tooltip: 'Restart song',
            icon: const Icon(Icons.restart_alt_rounded, size: 20),
          ),
          IconButton(
            onPressed: onSmaller,
            tooltip: 'Smaller lyrics',
            icon: const Icon(Icons.text_decrease_rounded, size: 19),
          ),
          IconButton(
            onPressed: onLarger,
            tooltip: 'Larger lyrics',
            icon: const Icon(Icons.text_increase_rounded, size: 19),
          ),
        ],
      ),
    );
  }
}

class _LiveControls extends StatelessWidget {
  const _LiveControls({
    required this.mode,
    required this.playing,
    required this.elapsed,
    required this.duration,
    required this.hasSync,
    required this.onPlay,
    required this.onMode,
  });

  final LiveScrollMode mode;
  final bool playing;
  final Duration elapsed;
  final Duration duration;
  final bool hasSync;
  final VoidCallback onPlay;
  final ValueChanged<LiveScrollMode> onMode;

  bool get _showProgress => mode == LiveScrollMode.timed || mode == LiveScrollMode.synced;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xE6091424),
      borderRadius: BorderRadius.circular(22),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                FilledButton.tonalIcon(
                  key: const Key('live_play_pause'),
                  onPressed: onPlay,
                  icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 19),
                  label: Text(playing ? 'Pause' : 'Start'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: <Widget>[
                        if (hasSync)
                          _ModeChip(
                            key: const Key('live_mode_synced'),
                            label: 'Synced',
                            icon: Icons.graphic_eq_rounded,
                            selected: mode == LiveScrollMode.synced,
                            onTap: () => onMode(LiveScrollMode.synced),
                          ),
                        _ModeChip(
                          label: 'Slow',
                          selected: mode == LiveScrollMode.slow,
                          onTap: () => onMode(LiveScrollMode.slow),
                        ),
                        _ModeChip(
                          label: 'Medium',
                          selected: mode == LiveScrollMode.medium,
                          onTap: () => onMode(LiveScrollMode.medium),
                        ),
                        _ModeChip(
                          label: 'Fast',
                          selected: mode == LiveScrollMode.fast,
                          onTap: () => onMode(LiveScrollMode.fast),
                        ),
                        // "Song time" is a manual fallback for songs without
                        // analyzed sync data; once synced timing exists it's
                        // strictly worse, so it's hidden to keep this row short.
                        if (!hasSync)
                          _ModeChip(
                            label: 'Song time',
                            selected: mode == LiveScrollMode.timed,
                            onTap: () => onMode(LiveScrollMode.timed),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (_showProgress) ...<Widget>[
              const SizedBox(height: 6),
              Row(
                children: <Widget>[
                  Text(_clock(elapsed), style: const TextStyle(color: AppColors.muted, fontSize: 10)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: LinearProgressIndicator(
                      value: duration.inMilliseconds <= 0
                          ? 0
                          : (elapsed.inMilliseconds / duration.inMilliseconds)
                              .clamp(0, 1)
                              .toDouble(),
                      minHeight: 2,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(_clock(duration), style: const TextStyle(color: AppColors.muted, fontSize: 10)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({required this.label, required this.selected, required this.onTap, this.icon, super.key});

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        selected: selected,
        avatar: icon == null
            ? null
            : Icon(icon, size: 14, color: selected ? AppColors.text : AppColors.muted),
        label: Text(label),
        onSelected: (_) => onTap(),
        labelStyle: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
          color: selected ? AppColors.text : AppColors.muted,
        ),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class _DurationSheet extends StatefulWidget {
  const _DurationSheet({required this.initial});

  final Duration initial;

  @override
  State<_DurationSheet> createState() => _DurationSheetState();
}

class _DurationSheetState extends State<_DurationSheet> {
  late int _minutes;
  late int _seconds;

  @override
  void initState() {
    super.initState();
    _minutes = widget.initial.inMinutes.clamp(0, 20).toInt();
    _seconds = widget.initial.inSeconds.remainder(60);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 0, 22, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Song time', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 7),
            const Text('Scroll from the first lyric to the last over the full song length.'),
            const SizedBox(height: 18),
            Row(
              children: <Widget>[
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: _minutes,
                    decoration: const InputDecoration(labelText: 'Minutes'),
                    items: List<DropdownMenuItem<int>>.generate(
                      21,
                      (value) => DropdownMenuItem<int>(value: value, child: Text('$value')),
                    ),
                    onChanged: (value) => setState(() => _minutes = value ?? _minutes),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: _seconds,
                    decoration: const InputDecoration(labelText: 'Seconds'),
                    items: List<DropdownMenuItem<int>>.generate(
                      60,
                      (value) => DropdownMenuItem<int>(
                        value: value,
                        child: Text(value.toString().padLeft(2, '0')),
                      ),
                    ),
                    onChanged: (value) => setState(() => _seconds = value ?? _seconds),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  final value = Duration(minutes: _minutes, seconds: _seconds);
                  Navigator.pop(
                    context,
                    value < const Duration(seconds: 10) ? const Duration(seconds: 10) : value,
                  );
                },
                child: const Text('Use song time'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _clock(Duration value) {
  final minutes = value.inMinutes;
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
