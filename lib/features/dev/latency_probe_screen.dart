import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../app/colabroom_theme.dart';
import '../../services/latency_probe.dart';
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

  final List<ProbeReading> _readings = <ProbeReading>[];
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
