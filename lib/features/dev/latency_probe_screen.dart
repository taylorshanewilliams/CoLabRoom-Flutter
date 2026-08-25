import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../app/colabroom_theme.dart';
import '../../services/latency_probe.dart';
import '../../services/onset_align.dart';
import '../../widgets/microphone_disclosure.dart';

/// A throwaway screen that answers one question: can this phone record in
/// time with what it is playing?
///
/// Nothing in the app uses it. It exists because overdubbing — record a
/// vocal over the guitar you already put down, hand it to the bass player,
/// get it back with bass on it — hinges entirely on whether recorded audio
/// lands at a predictable distance behind the playback. If it does, the
/// distance is subtracted and the feature works. If it wanders, no amount of
/// product design rescues it and the answer is a native audio engine.
///
/// Cheaper to find that out here than to discover it after building a mixer.
class LatencyProbeScreen extends StatefulWidget {
  const LatencyProbeScreen({super.key});

  @override
  State<LatencyProbeScreen> createState() => _LatencyProbeScreenState();
}

class _LatencyProbeScreenState extends State<LatencyProbeScreen> {
  static const int _trials = 5;

  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();

  static const int _playAlongBpm = 100;

  final List<ProbeReading> _readings = <ProbeReading>[];
  AlignmentResult? _alignment;
  int? _alignmentCalibratedMs;
  String? _alignmentNote;
  final List<String> _failures = <String>[];
  bool _running = false;
  String? _error;
  String _stage = '';

  @override
  void dispose() {
    unawaited(_recorder.dispose());
    unawaited(_player.dispose());
    super.dispose();
  }

  Future<void> _run() async {
    if (_running) return;
    final allowed = await MicrophoneAccess.ensureGranted(
      context,
      purpose: 'to measure how far this phone records behind what it plays',
      request: _recorder.hasPermission,
    );
    if (!allowed || !mounted) return;

    setState(() {
      _running = true;
      _error = null;
      _readings.clear();
      _failures.clear();
    });

    try {
      final directory = await getTemporaryDirectory();
      final signalPath = '${directory.path}/latency_signal.wav';
      await File(signalPath).writeAsBytes(
        LatencyProbe.toWav(LatencyProbe.calibrationSignal()),
        flush: true,
      );

      for (var trial = 1; trial <= _trials; trial += 1) {
        if (!mounted) return;
        setState(() => _stage = 'Trial $trial of $_trials');
        final reading = await _measure(signalPath, trial);
        if (!mounted) return;
        setState(() {
          if (reading != null) {
            _readings.add(reading);
          } else {
            _failures.add('Trial $trial: no marker found');
          }
        });
        // Let the audio session settle rather than slamming straight into the
        // next start/stop pair, which is not what a real overdub would do.
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() {
        _running = false;
        _stage = '';
      });
    }
  }

  Future<ProbeReading?> _measure(String signalPath, int trial) async {
    final directory = await getTemporaryDirectory();
    final capturePath = '${directory.path}/latency_capture_$trial.wav';

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: LatencyProbe.sampleRate,
        numChannels: 1,
        // All three off, deliberately, and echo cancellation above all.
        //
        // Acoustic echo cancellation exists to remove from the microphone
        // whatever the speaker is playing — which is precisely the signal
        // this is trying to hear. Left on, the probe would report that no
        // marker was found, on a device where the measurement was fine.
        //
        // The same applies to the real feature: automatic gain and noise
        // suppression are tuned for speech on calls and audibly wreck music,
        // pumping on sustained notes and gating quiet passages.
        echoCancel: false,
        noiseSuppress: false,
        autoGain: false,
      ),
      path: capturePath,
    );

    // The recorder needs to be genuinely running before anything is played,
    // or the lead silence absorbs the difference and the first marker is
    // clipped off the front of the capture.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _player.play(DeviceFileSource(signalPath));

    // Long enough for both markers plus the tail.
    await Future<void>.delayed(const Duration(milliseconds: 2200));
    await _recorder.stop();
    await _player.stop();

    final file = File(capturePath);
    if (!await file.exists()) return null;
    final samples = LatencyProbe.fromWav(await file.readAsBytes());
    if (samples.isEmpty) return null;
    return LatencyProbe.read(samples);
  }

  /// Records a strum against a click and asks the beat grid where it landed.
  ///
  /// The point is not the number on its own but that it can be compared. The
  /// same recording carries a sweep marker, which says exactly where playback
  /// began; the clicks after it are a beat grid with real positions. So one
  /// take yields both a measured latency and an independent answer to "once
  /// that latency is taken out, does the playing actually sit on the beat".
  ///
  /// If those two agree, both methods work and either can carry the feature.
  /// If the grid says the playing is still badly off after compensation, the
  /// calibration is not holding — which is precisely the failure the spread
  /// is looking for, seen from the other side.
  Future<void> _runPlayAlong() async {
    if (_running) return;
    final allowed = await MicrophoneAccess.ensureGranted(
      context,
      purpose: 'to record you playing along with a click',
      request: _recorder.hasPermission,
    );
    if (!allowed || !mounted) return;

    setState(() {
      _running = true;
      _error = null;
      _alignment = null;
      _alignmentCalibratedMs = null;
      _alignmentNote = null;
      _stage = 'Play along with the click';
    });

    try {
      final directory = await getTemporaryDirectory();
      final signalPath = '${directory.path}/latency_click.wav';
      await File(signalPath).writeAsBytes(
        LatencyProbe.toWav(LatencyProbe.clickTrack(bpm: _playAlongBpm)),
        flush: true,
      );
      final capturePath = '${directory.path}/latency_playalong.wav';

      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: LatencyProbe.sampleRate,
          numChannels: 1,
          echoCancel: false,
          noiseSuppress: false,
          autoGain: false,
        ),
        path: capturePath,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await _player.play(DeviceFileSource(signalPath));
      // Twenty beats at 100bpm, plus the lead and a beat of margin.
      await Future<void>.delayed(const Duration(milliseconds: 13500));
      await _recorder.stop();
      await _player.stop();

      final samples = LatencyProbe.fromWav(await File(capturePath).readAsBytes());
      if (samples.isEmpty) throw StateError('Nothing was recorded.');
      _analysePlayAlong(samples);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() {
        _running = false;
        _stage = '';
      });
    }
  }

  void _analysePlayAlong(Float64List samples) {
    final rate = LatencyProbe.sampleRate;
    final markerAt = LatencyProbe.locate(samples, LatencyProbe.marker());
    if (markerAt == null) {
      if (mounted) {
        setState(() => _alignmentNote =
            'The marker was not found, so there is no reference to measure '
            'the playing against. Turn the volume up, or move the phone '
            'closer.');
      }
      return;
    }

    // Where the first click landed in the recording, from the marker alone.
    final firstClick = markerAt.offsetSamples +
        LatencyProbe.clickLeadSamples(rate: rate, bpm: _playAlongBpm);
    // Start the window early so playing *ahead* of the beat — which players
    // do constantly — is representable. alignToGrid only searches forward, so
    // the grid is offset by the same amount and subtracted back out.
    const leadMs = 150;
    final windowStart = math.max(0, firstClick - (rate * leadMs / 1000).round());
    if (windowStart >= samples.length) return;

    final beatMs = (60000 / _playAlongBpm).round();
    final grid = <int>[for (var i = 0; i < 20; i += 1) leadMs + i * beatMs];
    final result = OnsetAlign.alignToGrid(
      Float64List.sublistView(samples, windowStart),
      grid,
      rate: rate,
    );

    if (!mounted) return;
    setState(() {
      _alignment = result;
      _alignmentCalibratedMs =
          (markerAt.offsetSamples * 1000 / rate).round() - 250;
      if (result == null) {
        _alignmentNote = 'No usable attacks were found. Play something with a '
            'clear pick or strike to it — a held note gives this nothing to '
            'work with.';
      } else if (!result.trustworthy) {
        _alignmentNote = 'The attacks were too vague to trust this answer. '
            'That is the honest outcome for a sustained part, and the reason '
            'a manual nudge has to exist regardless.';
      }
    });
  }

  /// The number the whole exercise is for.
  ///
  /// Not the average latency — the spread. A device that is 180ms late every
  /// single time is trivially correctable; one that is 120ms late and then
  /// 175ms cannot be calibrated at all, whatever its average.
  double? get _spreadMs {
    if (_readings.length < 2) return null;
    final values = _readings.map((r) => r.offsetMs).toList()..sort();
    return values.last - values.first;
  }

  double? get _medianMs {
    if (_readings.isEmpty) return null;
    final values = _readings.map((r) => r.offsetMs).toList()..sort();
    final middle = values.length ~/ 2;
    return values.length.isOdd
        ? values[middle]
        : (values[middle - 1] + values[middle]) / 2;
  }

  double? get _worstClockErrorMs {
    final errors = _readings
        .map((r) => r.clockErrorMs)
        .whereType<double>()
        .map((value) => value.abs())
        .toList();
    if (errors.isEmpty) return null;
    return errors.reduce(math.max);
  }

  @override
  Widget build(BuildContext context) {
    final spread = _spreadMs;
    return Scaffold(
      backgroundColor: AppColors.deepNavy,
      appBar: AppBar(
        title: const Text('Recording latency'),
        backgroundColor: AppColors.deepNavy,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 40),
          children: <Widget>[
            const Text(
              'Can this phone record in time with what it plays?',
              style: TextStyle(
                color: AppColors.text,
                fontSize: 20,
                fontWeight: FontWeight.w800,
                height: 1.25,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Plays a short sweep five times and listens for it coming back. '
              'What matters is not how late it is — any fixed delay can be '
              'subtracted — but whether it is the same amount late every time.',
              style: TextStyle(color: AppColors.muted, fontSize: 13.5, height: 1.5),
            ),
            const SizedBox(height: 16),
            const _Instructions(),
            const SizedBox(height: 18),
            FilledButton(
              key: const Key('latency_probe_run'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.gold,
                foregroundColor: AppColors.ink,
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: _running ? null : () => unawaited(_run()),
              child: Text(
                _running ? (_stage.isEmpty ? 'Measuring…' : _stage) : 'Measure',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              key: const Key('latency_probe_play_along'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.cyan,
                minimumSize: const Size.fromHeight(48),
                side: BorderSide(color: AppColors.cyan.withValues(alpha: 0.5)),
              ),
              onPressed: _running ? null : () => unawaited(_runPlayAlong()),
              child: const Text(
                'Play along with a click (13s)',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Strum, tap or clap on every click. This measures the same take '
              'two ways — where the marker says playback began, and where the '
              'beat grid says your playing landed. Two methods agreeing is '
              'worth more than either number alone.',
              style: TextStyle(color: AppColors.muted, fontSize: 12.5, height: 1.5),
            ),
            if (_alignment != null || _alignmentNote != null) ...<Widget>[
              const SizedBox(height: 16),
              if (_alignmentCalibratedMs != null)
                _Row('Marker says', '${_alignmentCalibratedMs} ms late'),
              if (_alignment != null) ...<Widget>[
                _Row('Grid says playing was', '${_alignment!.shiftMs} ms off the beat'),
                _Row(
                  'Alignment confidence',
                  '${_alignment!.confidence.toStringAsFixed(2)}'
                  '  ·  on-beat share ${(_alignment!.concentration * 100).round()}%'
                  '  ·  ${_alignment!.trustworthy ? 'usable' : 'too vague'}',
                ),
                _Row('Searched to', '${_alignment!.searchedToMs} ms'),
              ],
              if (_alignmentNote != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  _alignmentNote!,
                  style: const TextStyle(
                    color: AppColors.orange,
                    fontSize: 12.5,
                    height: 1.5,
                  ),
                ),
              ],
            ],
            if (_error != null) ...<Widget>[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF718B).withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Color(0xFFFFA0B0), fontSize: 12),
                ),
              ),
            ],
            if (_readings.isNotEmpty || _failures.isNotEmpty) ...<Widget>[
              const SizedBox(height: 22),
              if (spread != null) _Verdict(spreadMs: spread),
              const SizedBox(height: 16),
              _Row('Median lag', _medianMs == null ? '—' : '${_medianMs!.toStringAsFixed(1)} ms'),
              _Row('Spread', spread == null ? '—' : '${spread.toStringAsFixed(1)} ms'),
              _Row(
                'Worst clock error',
                _worstClockErrorMs == null
                    ? '—'
                    : '${_worstClockErrorMs!.toStringAsFixed(1)} ms per second',
              ),
              const SizedBox(height: 14),
              const Text(
                'Every trial',
                style: TextStyle(
                  color: AppColors.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < _readings.length; i += 1)
                _Row(
                  'Trial ${i + 1}',
                  '${_readings[i].offsetMs.toStringAsFixed(1)} ms'
                  '   ·   confidence ${_readings[i].confidence.toStringAsFixed(1)}',
                ),
              for (final failure in _failures)
                _Row(failure, 'failed', warn: true),
            ],
          ],
        ),
      ),
    );
  }
}

class _Instructions extends StatelessWidget {
  const _Instructions();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.cyan.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cyan.withValues(alpha: 0.2)),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Run it three ways',
            style: TextStyle(
              color: AppColors.cyan,
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          SizedBox(height: 8),
          Text(
            '1.  Speaker, quiet room, phone on a table.\n'
            '2.  Wired headphones, held against the microphone.\n'
            '3.  Bluetooth headphones, the same way.\n\n'
            'All three, because output latency changes with the output. '
            'Bluetooth is usually far worse than the other two, and if it is '
            'also unstable then recording over Bluetooth has to be refused '
            'rather than quietly produce takes nobody can use.',
            style: TextStyle(color: AppColors.muted, fontSize: 12.5, height: 1.55),
          ),
        ],
      ),
    );
  }
}

/// Reads the spread the way the decision actually depends on it.
class _Verdict extends StatelessWidget {
  const _Verdict({required this.spreadMs});

  final double spreadMs;

  @override
  Widget build(BuildContext context) {
    final (String headline, String detail, Color color) = switch (spreadMs) {
      < 10 => (
          'Stable enough to calibrate',
          'The lag barely moves between takes, so measuring it once and '
              'subtracting it would hold. Overdubbing is workable on this path.',
          AppColors.green,
        ),
      < 25 => (
          'Borderline',
          'Correctable, but a take could land a few milliseconds out either '
              'way. Tolerable for a rough layer; a drummer would hear it. '
              'Worth a manual nudge control either way.',
          AppColors.orange,
        ),
      _ => (
          'Too loose to calibrate',
          'The lag changes by more than a player can ignore, so no single '
              'offset fixes it. This path will not carry overdubbing — it '
              'would need a native audio engine, or alignment after the fact '
              'against the beat grid.',
          const Color(0xFFFF718B),
        ),
    };

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            headline,
            style: TextStyle(color: color, fontSize: 15, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            detail,
            style: const TextStyle(color: AppColors.muted, fontSize: 12.5, height: 1.5),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.warn = false});

  final String label;
  final String value;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: AppColors.muted, fontSize: 13),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: warn ? const Color(0xFFFFA0B0) : AppColors.text,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
