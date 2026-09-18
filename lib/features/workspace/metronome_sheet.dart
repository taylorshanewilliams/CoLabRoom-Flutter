import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../services/click_player.dart';
import '../../services/user_facing_error.dart';
import 'practice_rules.dart';

/// A metronome, on the sheet you record from.
///
/// The takes console has had a click for months, for recording a part
/// against. This is the same click with nothing to record: a tempo to feel
/// before the red button, or to practise to with the phone on the music
/// stand. It stops when the sheet closes, so it can never end up on a take
/// by accident.
class MetronomeSheet extends StatefulWidget {
  const MetronomeSheet({this.initialBpm, this.player, super.key});

  /// The song's tempo when it is known, so the click starts where the song
  /// is rather than at a default.
  final double? initialBpm;

  /// Production leaves this null; a test hands in a silent one.
  final ClickPlayer? player;

  static Future<void> show(BuildContext context, {double? initialBpm}) =>
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: AppColors.deepNavy,
        isScrollControlled: true,
        builder: (_) => MetronomeSheet(initialBpm: initialBpm),
      );

  @override
  State<MetronomeSheet> createState() => _MetronomeSheetState();
}

class _MetronomeSheetState extends State<MetronomeSheet> {
  late final ClickPlayer _player = widget.player ?? WavClickPlayer();
  late double _bpm = clampBpm(widget.initialBpm ?? 100);
  int _beatsPerBar = 4;
  bool _playing = false;
  String? _error;
  final List<DateTime> _taps = <DateTime>[];
  Timer? _restart;

  @override
  void dispose() {
    _restart?.cancel();
    unawaited(_player.stop().then((_) => _player.dispose()));
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      setState(() => _playing = false);
      await _player.stop();
      return;
    }
    setState(() {
      _playing = true;
      _error = null;
    });
    await _start();
  }

  Future<void> _start() async {
    try {
      await _player.play(bpm: _bpm, beatsPerBar: _beatsPerBar);
    } catch (error) {
      if (mounted) {
        setState(() {
          _playing = false;
          _error = reportAndDescribe(error, service: 'app', stage: 'metronome', route: 'Metronome');
        });
      }
    }
  }

  /// A new tempo while playing: rewrite and restart, but not for every
  /// pixel of a slider drag. A quarter second after the last change.
  void _setBpm(double bpm) {
    setState(() => _bpm = clampBpm(bpm));
    if (!_playing) return;
    _restart?.cancel();
    _restart = Timer(const Duration(milliseconds: 250), () {
      if (mounted && _playing) unawaited(_start());
    });
  }

  void _setBeatsPerBar(int beats) {
    setState(() => _beatsPerBar = beats);
    if (_playing) unawaited(_start());
  }

  void _tap() {
    _taps.add(DateTime.now());
    if (_taps.length > 8) _taps.removeAt(0);
    final tempo = tapTempo(_taps);
    if (tempo == null) {
      // A long gap: this tap is the first of a new count.
      _taps
        ..clear()
        ..add(DateTime.now());
      setState(() {});
      return;
    }
    _setBpm(tempo);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
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
            const SizedBox(height: 18),
            Text(
              'Metronome',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: AppColors.text,
                    fontWeight: FontWeight.w900,
                  ),
            ),
            const SizedBox(height: 6),
            Text(
              _error ?? 'Tap the tempo, or slide to it. It stops when you close this.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _error != null ? const Color(0xFFFF9CAA) : AppColors.muted,
                fontSize: 12,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                IconButton(
                  key: const Key('metronome_slower'),
                  tooltip: 'Slower',
                  onPressed: () => _setBpm(_bpm - 1),
                  icon: const Icon(Icons.remove_rounded),
                ),
                Text(
                  '${_bpm.round()}',
                  key: const Key('metronome_bpm'),
                  style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 64,
                    fontWeight: FontWeight.w300,
                    height: 1,
                    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.only(bottom: 10, left: 6),
                  child: Text('bpm', style: TextStyle(color: AppColors.muted, fontSize: 14)),
                ),
                IconButton(
                  key: const Key('metronome_faster'),
                  tooltip: 'Faster',
                  onPressed: () => _setBpm(_bpm + 1),
                  icon: const Icon(Icons.add_rounded),
                ),
              ],
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                activeTrackColor: AppColors.gold,
                inactiveTrackColor: AppColors.line,
                thumbColor: AppColors.gold,
                overlayColor: AppColors.gold.withValues(alpha: 0.2),
              ),
              child: Slider(
                key: const Key('metronome_slider'),
                min: minBpm,
                max: maxBpm,
                value: _bpm,
                onChanged: _setBpm,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              alignment: WrapAlignment.center,
              children: <Widget>[
                for (final beats in const <int>[2, 3, 4, 6])
                  ChoiceChip(
                    key: Key('metronome_beats_$beats'),
                    label: Text('$beats'),
                    selected: _beatsPerBar == beats,
                    onSelected: (_) => _setBeatsPerBar(beats),
                    selectedColor: AppColors.gold,
                    labelStyle: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: _beatsPerBar == beats ? AppColors.ink : AppColors.muted,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                const Padding(
                  padding: EdgeInsets.only(left: 6, top: 8),
                  child: Text('beats in a bar', style: TextStyle(color: AppColors.muted, fontSize: 11)),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('metronome_tap'),
                    onPressed: _tap,
                    icon: const Icon(Icons.touch_app_rounded, size: 18),
                    label: const Text('Tap'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    key: const Key('metronome_play'),
                    onPressed: _toggle,
                    style: FilledButton.styleFrom(
                      backgroundColor: _playing ? AppColors.raised : AppColors.gold,
                      foregroundColor: _playing ? AppColors.text : AppColors.ink,
                    ),
                    icon: Icon(_playing ? Icons.stop_rounded : Icons.play_arrow_rounded),
                    label: Text(_playing ? 'Stop' : 'Start'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
