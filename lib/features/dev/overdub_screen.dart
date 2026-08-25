import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/colabroom_theme.dart';
import '../../services/multitrack.dart';
import '../../services/take_export.dart';
import '../../services/take_naming.dart';
import '../../widgets/microphone_disclosure.dart';

/// Record a riff, play it back, sing over it, add a lead.
///
/// Nothing is analyzed, nothing is uploaded, and no take means anything to
/// the rest of the app. A riff captured in the thirty seconds before it is
/// forgotten should not wait for a GPU, a project, or a network.
///
/// Playback is a single file that gets rebuilt whenever the layers change —
/// see Multitrack, which explains why summing beats syncing separate players.
class OverdubScreen extends StatefulWidget {
  const OverdubScreen({
    this.sessionName = 'scratch',
    this.seedAudioPath,
    this.seedLabel = 'Existing track',
    super.key,
  });

  /// Which set of layers this is. One directory per name, so a project's
  /// layers and a scratch idea do not land in the same pile.
  final String sessionName;

  /// An existing recording to start from, adopted as the first layer.
  ///
  /// This is how a bandmate adds a part to a song that has already been
  /// analyzed: the reference track becomes layer one and everything else
  /// works unchanged, because the mixer has never cared where a layer's audio
  /// came from. Nothing about the analysis is touched or re-run — the
  /// analysis describes the original recording, and the new parts sit on top
  /// of it rather than replacing it.
  final String? seedAudioPath;

  final String seedLabel;

  @override
  State<OverdubScreen> createState() => _OverdubScreenState();
}

class _OverdubScreenState extends State<OverdubScreen> {
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();

  TakeSession? _session;
  bool _recording = false;
  bool _playing = false;
  bool _busy = false;
  String? _error;
  String? _note;
  int _offsetMs = 0;
  String? _performer;
  Duration _elapsed = Duration.zero;
  Timer? _timer;
  StreamSubscription<void>? _completeSub;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _completeSub = _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playing = false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_completeSub?.cancel());
    unawaited(_recorder.dispose());
    unawaited(_player.dispose());
    super.dispose();
  }

  Future<void> _load() async {
    final root = await getApplicationDocumentsDirectory();
    final directory = Directory('${root.path}/overdub/${widget.sessionName}');
    if (!await directory.exists()) await directory.create(recursive: true);
    var session = await TakeSession.load(directory.path);

    // Adopt the track this was opened against, once. Guarded on the session
    // being empty rather than on a flag: reopening a project's layers must
    // not keep stacking another copy of the original underneath them.
    final seed = widget.seedAudioPath;
    if (session.takes.isEmpty && seed != null && await File(seed).exists()) {
      session = TakeSession(
        directory: directory.path,
        takes: <Take>[
          Take(
            id: 'seed',
            path: seed,
            label: widget.seedLabel,
            recordedAt: DateTime.now(),
          ),
        ],
      );
      await session.save();
    }
    if (mounted) setState(() => _session = session);
  }

  String get _mixPath => '${_session!.directory}/_mix.wav';

  /// Rebuilds the single file that playback and the next overdub both use.
  Future<bool> _rebuildMix() async {
    final session = _session;
    if (session == null) return false;
    final result = await Multitrack.writeMixdown(
      takes: session.takes,
      outputPath: _mixPath,
    );
    if (!mounted) return result != null;
    setState(() {
      _note = result != null && result.scaled
          ? 'The layers summed past full scale, so the mix was turned down to '
              'fit. Nothing was clipped.'
          : null;
    });
    return result != null;
  }

  Future<void> _record() async {
    if (_busy || _recording) return;
    final allowed = await MicrophoneAccess.ensureGranted(
      context,
      purpose: 'to record a take over what you have already put down',
      request: _recorder.hasPermission,
    );
    if (!allowed || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = _session!;
      final id = DateTime.now().millisecondsSinceEpoch.toString();
      final path = '${session.directory}/take_$id.wav';

      // Everything already recorded, as one file, playing while this take is
      // captured. Absent for the first take, which has nothing to play over.
      final hasBacking = await _rebuildMix();

      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: Multitrack.rate,
          numChannels: 1,
          // Off for the same reasons as the latency probe. Echo cancellation
          // would fight the backing track coming through the microphone, and
          // auto gain and noise suppression are tuned for phone calls — they
          // pump on sustained notes and gate quiet passages.
          echoCancel: false,
          noiseSuppress: false,
          autoGain: false,
        ),
        path: path,
      );
      if (hasBacking) {
        await _player.play(DeviceFileSource(_mixPath));
      }

      _elapsed = Duration.zero;
      _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!mounted) return;
        setState(() => _elapsed += const Duration(milliseconds: 200));
      });
      if (mounted) {
        setState(() {
          _recording = true;
          _playing = hasBacking;
          _busy = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _busy = false;
        });
      }
    }
  }

  Future<void> _stopRecording() async {
    if (!_recording) return;
    _timer?.cancel();
    setState(() => _busy = true);
    try {
      final path = await _recorder.stop();
      await _player.stop();
      final session = _session!;
      if (path != null && await File(path).exists()) {
        // Asked now, not later. This is the one second anybody will spend
        // naming a layer, and a label that appears on its own beats a field
        // somebody meant to fill in — the moment for typing is exactly the
        // moment nobody wants to.
        final described = await _askWhatThatWas();
        if (!mounted) return;
        final part = described?.part ?? TakePart.other;
        final performer = described?.performer;
        final take = Take(
          id: path.split('/').last,
          path: path,
          label: described == null
              ? 'Take ${session.takes.length + 1}'
              : TakeNaming.nextLabel(session.takes, part, performer),
          part: part,
          performer: performer,
          recordedAt: DateTime.now(),
          durationMs: _elapsed.inMilliseconds,
          // The correction is stamped onto the take at the moment it is made,
          // not applied globally later: the phone may be on speaker for one
          // take and Bluetooth for the next, and a take recorded before the
          // offset was known should not silently move when it becomes known.
          offsetMs: session.takes.isEmpty ? 0 : _offsetMs,
        );
        final next = TakeSession(
          directory: session.directory,
          takes: <Take>[...session.takes, take],
        );
        await next.save();
        if (mounted) setState(() => _session = next);
        await _rebuildMix();
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() {
          _recording = false;
          _playing = false;
          _busy = false;
        });
      }
    }
  }

  /// What was that layer, and who played it.
  ///
  /// Dismissable. Somebody who does not care gets "Take 3" and can rename it
  /// whenever — a sheet that cannot be escaped in the middle of a session is
  /// worse than an unnamed take.
  Future<({TakePart part, String? performer})?> _askWhatThatWas() async {
    var performer = _performer ?? '';
    return showModalBottomSheet<({TakePart part, String? performer})>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: AppColors.deepNavy,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.fromLTRB(
          18, 0, 18, MediaQuery.of(sheetContext).viewInsets.bottom + 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'What was that?',
              style: TextStyle(
                color: AppColors.text,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'So everyone can tell the layers apart later.',
              style: TextStyle(color: AppColors.muted, fontSize: 12.5),
            ),
            const SizedBox(height: 14),
            TextFormField(
              initialValue: performer,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Who played it',
                hintText: 'Dylan',
              ),
              onChanged: (value) => performer = value,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final part in TakePart.values)
                  ActionChip(
                    label: Text(part.label),
                    backgroundColor: AppColors.raised,
                    labelStyle: const TextStyle(color: AppColors.text, fontSize: 13),
                    side: BorderSide(color: AppColors.cyan.withValues(alpha: 0.25)),
                    onPressed: () => Navigator.pop(
                      sheetContext,
                      (
                        part: part,
                        performer: performer.trim().isEmpty ? null : performer.trim(),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => Navigator.pop(sheetContext),
              child: const Text('Skip'),
            ),
          ],
        ),
      ),
    ).then((value) {
      if (value?.performer != null) _performer = value!.performer;
      return value;
    });
  }

  /// Hand the work to the operating system, which is where it stops being
  /// ours to lose.
  ///
  /// This is what makes an expiry policy fair rather than merely convenient
  /// for us. Layers nobody opens for months are worth reclaiming; doing that
  /// to a band is only defensible while a copy is one tap away, in a format
  /// they can use without this app existing.
  Future<void> _export() async {
    final session = _session;
    if (session == null || session.takes.isEmpty || _busy) return;

    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.deepNavy,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.graphic_eq_rounded, color: AppColors.gold),
              title: const Text('The mix'),
              subtitle: const Text(
                'One file of what you hear now. For sending to someone.',
              ),
              onTap: () => Navigator.pop(sheetContext, 'mix'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_zip_outlined, color: AppColors.cyan),
              title: const Text('Every layer'),
              subtitle: const Text(
                'A zip of each part on its own, with the volumes and timing '
                'written down. For keeping, or for opening in a DAW.',
              ),
              onTap: () => Navigator.pop(sheetContext, 'layers'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final File? file = choice == 'mix'
          ? await TakeExport.mixdown(
              takes: session.takes,
              outputPath: '${session.directory}/export_$stamp.wav',
            )
          : await TakeExport.layerArchive(
              takes: session.takes,
              outputPath: '${session.directory}/export_$stamp.zip',
            );
      if (file == null) {
        if (mounted) {
          setState(() => _error = 'There was nothing to export.');
        }
        return;
      }
      await SharePlus.instance.share(
        ShareParams(
          files: <XFile>[XFile(file.path)],
          subject: choice == 'mix' ? 'Mix' : 'Layers',
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _togglePlay() async {
    if (_recording) return;
    if (_playing) {
      await _player.stop();
      if (mounted) setState(() => _playing = false);
      return;
    }
    if (!await _rebuildMix()) return;
    await _player.play(DeviceFileSource(_mixPath));
    if (mounted) setState(() => _playing = true);
  }

  Future<void> _update(Take take, Take replacement) async {
    final session = _session!;
    final next = TakeSession(
      directory: session.directory,
      takes: session.takes
          .map((entry) => entry.id == take.id ? replacement : entry)
          .toList(growable: false),
    );
    await next.save();
    if (mounted) setState(() => _session = next);
    await _rebuildMix();
  }

  Future<void> _delete(Take take) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete ${TakeNaming.describe(take)}?'),
        content: const Text(
          'The audio goes with it. Muting keeps a take out of the mix without '
          'losing it, if you only want to hear what it sounds like without.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final session = _session!;
    final next = TakeSession(
      directory: session.directory,
      takes: session.takes.where((entry) => entry.id != take.id).toList(growable: false),
    );
    await next.save();
    try {
      final file = File(take.path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // The manifest is what the app reads. A file that will not delete is
      // an orphan on disk, not a take that came back.
    }
    if (mounted) setState(() => _session = next);
    await _rebuildMix();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return Scaffold(
      backgroundColor: AppColors.deepNavy,
      appBar: AppBar(
        title: const Text('Layers'),
        backgroundColor: AppColors.deepNavy,
        actions: <Widget>[
          IconButton(
            onPressed: (session?.takes.isEmpty ?? true) || _busy
                ? null
                : () => unawaited(_export()),
            tooltip: 'Save a copy of this work',
            icon: const Icon(Icons.ios_share_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: session == null
            ? const Center(child: CircularProgressIndicator(color: AppColors.gold))
            : ListView(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 120),
                children: <Widget>[
                  Text(
                    session.takes.isEmpty
                        ? 'Record something.'
                        : '${session.takes.length} layer${session.takes.length == 1 ? '' : 's'}',
                    style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    session.takes.isEmpty
                        ? 'The first take plays nothing back. Every take after '
                            'it plays everything before it while you record.'
                        : 'Wear headphones. Without them the backing track '
                            'goes down the microphone and smears into every '
                            'layer after it.',
                    style: const TextStyle(
                      color: AppColors.muted,
                      fontSize: 13,
                      height: 1.5,
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
                  if (_note != null) ...<Widget>[
                    const SizedBox(height: 14),
                    Text(
                      _note!,
                      style: const TextStyle(
                        color: AppColors.orange,
                        fontSize: 12.5,
                        height: 1.5,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  if (session.takes.isNotEmpty) _LatencyControl(
                    offsetMs: _offsetMs,
                    onChanged: (value) => setState(() => _offsetMs = value),
                  ),
                  const SizedBox(height: 18),
                  for (final take in session.takes)
                    _TakeRow(
                      take: take,
                      onToggle: () => unawaited(
                        _update(take, take.copyWith(enabled: !take.enabled)),
                      ),
                      onNudge: (delta) => unawaited(
                        _update(take, take.copyWith(
                          offsetMs: (take.offsetMs + delta).clamp(0, 1000),
                        )),
                      ),
                      onGain: (value) => unawaited(
                        _update(take, take.copyWith(gain: value)),
                      ),
                      onDelete: () => unawaited(_delete(take)),
                    ),
                ],
              ),
      ),
      bottomNavigationBar: session == null
          ? null
          : SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
                child: Row(
                  children: <Widget>[
                    if (session.takes.isNotEmpty) ...<Widget>[
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _recording ? null : () => unawaited(_togglePlay()),
                          icon: Icon(_playing
                              ? Icons.stop_rounded
                              : Icons.play_arrow_rounded),
                          label: Text(_playing ? 'Stop' : 'Play'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.cyan,
                            minimumSize: const Size.fromHeight(52),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        key: const Key('overdub_record'),
                        style: FilledButton.styleFrom(
                          backgroundColor:
                              _recording ? const Color(0xFFFF718B) : AppColors.gold,
                          foregroundColor: AppColors.ink,
                          minimumSize: const Size.fromHeight(52),
                        ),
                        onPressed: _busy
                            ? null
                            : () => unawaited(
                                _recording ? _stopRecording() : _record()),
                        icon: Icon(_recording
                            ? Icons.stop_rounded
                            : Icons.fiber_manual_record_rounded),
                        label: Text(
                          _recording
                              ? 'Stop  ${_elapsed.inMinutes}:${(_elapsed.inSeconds % 60).toString().padLeft(2, '0')}'
                              : session.takes.isEmpty
                                  ? 'Record'
                                  : 'Record over this',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

/// How much to trim off the front of the *next* take.
class _LatencyControl extends StatelessWidget {
  const _LatencyControl({required this.offsetMs, required this.onChanged});

  final int offsetMs;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Expanded(
                child: Text(
                  'Latency correction for the next take',
                  style: TextStyle(
                    color: AppColors.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '$offsetMs ms',
                style: const TextStyle(
                  color: AppColors.gold,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const Text(
            'A take always lands late by the time it took to play and record. '
            'If your layers sound behind the beat, raise this. Each take keeps '
            'the value it was recorded with, and can be nudged afterwards.',
            style: TextStyle(color: AppColors.muted, fontSize: 11.5, height: 1.45),
          ),
          Slider(
            value: offsetMs.toDouble(),
            max: 400,
            divisions: 40,
            activeColor: AppColors.gold,
            label: '$offsetMs ms',
            onChanged: (value) => onChanged(value.round()),
          ),
        ],
      ),
    );
  }
}

class _TakeRow extends StatefulWidget {
  const _TakeRow({
    required this.take,
    required this.onToggle,
    required this.onNudge,
    required this.onGain,
    required this.onDelete,
  });

  final Take take;
  final VoidCallback onToggle;
  final ValueChanged<int> onNudge;
  final ValueChanged<double> onGain;
  final VoidCallback onDelete;

  @override
  State<_TakeRow> createState() => _TakeRowState();
}

class _TakeRowState extends State<_TakeRow> {
  /// Where the thumb is mid-drag.
  ///
  /// Committing on every change would rewrite the manifest and rebuild the
  /// whole mix thirty times across one drag — a file write and a pass over
  /// every sample of every layer, per increment. The value is held here while
  /// the finger is down and written once when it lifts.
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final take = widget.take;
    final gain = _dragging ?? take.gain;
    final seconds = (take.durationMs / 1000).round();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: take.enabled ? AppColors.raised : AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: take.enabled ? AppColors.cyan.withValues(alpha: 0.25) : AppColors.line,
        ),
      ),
      child: Column(
        children: <Widget>[
      Row(
        children: <Widget>[
          IconButton(
            onPressed: widget.onToggle,
            tooltip: take.enabled
                ? 'Mute ${TakeNaming.describe(take)}'
                : 'Unmute ${TakeNaming.describe(take)}',
            icon: Icon(
              take.enabled ? Icons.volume_up_rounded : Icons.volume_off_rounded,
              color: take.enabled ? AppColors.cyan : AppColors.muted,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  TakeNaming.describe(take),
                  style: TextStyle(
                    color: take.enabled ? AppColors.text : AppColors.muted,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  '${seconds}s   ·   ${take.offsetMs} ms trimmed',
                  style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => widget.onNudge(-10),
            tooltip: 'Nudge ${TakeNaming.describe(take)} 10 ms earlier',
            icon: const Icon(Icons.remove_rounded, size: 18, color: AppColors.muted),
          ),
          IconButton(
            onPressed: () => widget.onNudge(10),
            tooltip: 'Nudge ${TakeNaming.describe(take)} 10 ms later',
            icon: const Icon(Icons.add_rounded, size: 18, color: AppColors.muted),
          ),
          IconButton(
            onPressed: widget.onDelete,
            tooltip: 'Delete ${TakeNaming.describe(take)}',
            icon: const Icon(Icons.delete_outline_rounded,
                size: 20, color: Color(0xFFFF718B)),
          ),
        ],
      ),
      // Volume per layer, separate from mute rather than replacing it.
      // Muting is the fast question — how does this sound without the
      // harmony — and dragging a slider to zero and back loses whatever
      // balance had been found. They answer different questions, so both
      // stay.
      Row(
        children: <Widget>[
          const SizedBox(width: 10),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2.5,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
              ),
              child: Slider(
                value: gain.clamp(0.0, 1.5),
                max: 1.5,
                divisions: 30,
                activeColor: take.enabled ? AppColors.cyan : AppColors.muted,
                inactiveColor: AppColors.line,
                label: '${(gain * 100).round()}%',
                // Above 100% on purpose. A quiet vocal sung two feet further
                // from the phone than the guitar was needs lifting, not
                // everything else pulled down — and the mixer scales the
                // whole mix if the sum overshoots, so pushing one layer up
                // cannot clip anything.
                onChanged: take.enabled
                    ? (value) => setState(() => _dragging = value)
                    : null,
                onChangeEnd: (value) {
                  setState(() => _dragging = null);
                  widget.onGain(value);
                },
                semanticFormatterCallback: (value) =>
                    '${TakeNaming.describe(take)} volume ${(value * 100).round()} percent',
              ),
            ),
          ),
          SizedBox(
            width: 44,
            child: Text(
              '${(gain * 100).round()}%',
              textAlign: TextAlign.right,
              style: TextStyle(
                color: take.enabled ? AppColors.muted : AppColors.line,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
        ],
      ),
    );
  }
}
