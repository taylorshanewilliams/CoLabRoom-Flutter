import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/colabroom_theme.dart';
import '../../services/multitrack.dart';
import '../../domain/song_analysis_models.dart';
import '../../services/song_analysis_service.dart';
import '../../services/song_layer_service.dart';
import '../../services/take_export.dart';
import '../../services/take_naming.dart';
import '../../widgets/microphone_disclosure.dart';
import 'layer_console.dart';
import 'layer_group.dart';
import 'layer_row.dart';

/// The takes a song is built from, and adding another one.
///
/// "Take" rather than "part" or "layer", because it is the word a band
/// already says out loud — another take, whose take is that, which take do
/// you like. A name people arrive already knowing beats one they have to be
/// taught, and it happens to be what the model has been called all along.
///
/// A first-class thing, not an appendix to the analyzer. Analysis costs GPU
/// and will eventually be worth charging for; this costs a fraction of a cent
/// per song per band and is the reason to keep coming back, so it sits beside
/// the lyrics as an ordinary part of writing a song rather than behind
/// anything.
///
/// It is also, deliberately, not a DAW. A band ready to properly record a
/// song will not be doing it here. What this has to be good at is the hour
/// where somebody has a riff, somebody else hears where the vocal goes, and
/// the two of them are not in the same room.
class SongLayersScreen extends StatefulWidget {
  const SongLayersScreen({
    required this.roomId,
    required this.projectId,
    required this.songTitle,
    super.key,
  });

  /// Needed for the storage path, which is {room}/{project}/layers/{id} —
  /// the same shape every other object in this app uses, and the shape the
  /// storage policies are written against.
  final String roomId;

  final String projectId;
  final String songTitle;

  @override
  State<SongLayersScreen> createState() => _SongLayersScreenState();
}

class _SongLayersScreenState extends State<SongLayersScreen> {
  final SongLayerService _service = SongLayerService();
  final SongAnalysisService _analysis = SongAnalysisService();

  /// The song's own recording, shown as the first take.
  ///
  /// A song that already has a reference track is not an empty session — the
  /// whole point of adding a take is adding it to something. Kept out of
  /// song_layers rather than copied into it: it belongs to the analysis, it
  /// is what every chord and lyric on the song sheet was derived from, and
  /// duplicating it would mean two rows that have to be deleted together and
  /// eventually will not be.
  ReferenceTrack? _reference;
  String? _referencePath;
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();

  List<SharedLayer>? _layers;
  final Map<String, String> _localPaths = <String, String>{};

  /// Which layers are in the mix right now.
  ///
  /// Local, and never sent anywhere. Muting is a view of a shared set — that
  /// is what lets anyone silence anything without taking it away from the
  /// person who played it.
  final Set<String> _enabled = <String>{};

  bool _recording = false;
  bool _playing = false;
  bool _busy = false;
  String? _error;
  String? _status;
  final Set<String> _silent = <String>{};
  String? _referenceNote;
  final Set<TakeGroup> _collapsed = <TakeGroup>{};
  int _offsetMs = 0;
  String? _performer;
  Duration _elapsed = Duration.zero;
  Timer? _timer;
  StreamSubscription<void>? _completeSub;

  @override
  void initState() {
    super.initState();
    _completeSub = _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playing = false);
    });
    unawaited(_load());
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
    setState(() {
      _busy = true;
      _error = null;
      _referenceNote = null;
      _status = 'Fetching the takes';
    });
    try {
      // Best-effort and first: a song with a recording should never look
      // empty, but a failure to fetch it must not stop the takes loading.
      try {
        final bundle = await _analysis.load(widget.projectId);
        final reference = bundle.reference;
        if (reference != null && reference.state == SongAnalysisState.ready) {
          _reference = reference;
          _referencePath = await _analysis.ensureLocalReference(reference);
          _enabled.add(_referenceId);
        }
      } catch (error) {
        // Said out loud rather than swallowed. This was a bare catch, which
        // meant a song with a recording on it showed an empty screen and gave
        // no reason — the one failure here that is guaranteed to look like a
        // missing feature rather than a problem.
        _referenceNote =
            'The song has a recording but it could not be loaded here. '
            'Everything else still works. ($error)';
      }

      final layers = await _service.listLayers(widget.projectId);
      for (final layer in layers) {
        // Everything on by default. Somebody opening a song wants to hear the
        // song, not a silent list of what it is made of.
        _enabled.add(layer.id);
        _localPaths[layer.id] = await _service.ensureLocal(layer);
      }
      // Best-effort: failing to record that somebody listened must never stop
      // them listening. It only feeds retention, which is generous enough to
      // survive a missed update.
      unawaited(_service.markOpened(layers.map((layer) => layer.id)));
      if (!mounted) return;
      setState(() {
        _layers = layers;
        _busy = false;
        _status = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _busy = false;
        _status = null;
      });
    }
  }

  String? get _me => Supabase.instance.client.auth.currentUser?.id;

  /// Whether a take is one this person may re-balance. The reference is
  /// nobody's to move — it is what the analysis was made from.
  bool _mine(Take take) {
    if (take.id == _referenceId) return false;
    final layers = _layers ?? const <SharedLayer>[];
    for (final layer in layers) {
      if (layer.id == take.id) return layer.recordedBy == _me;
    }
    return false;
  }

  SharedLayer? _layerFor(Take take) {
    for (final layer in _layers ?? const <SharedLayer>[]) {
      if (layer.id == take.id) return layer;
    }
    return null;
  }

  void _toggle(String id) {
    setState(() {
      if (!_enabled.remove(id)) _enabled.add(id);
    });
    unawaited(_rebuildMix());
  }

  /// Silences a whole group, or brings all of it back.
  ///
  /// "How does this sound without the guitars" is asked constantly, and a
  /// flat list answers it badly: mute three things one at a time, then
  /// remember which three to unmute.
  void _toggleGroup(List<Take> takes) {
    final anyOn = takes.any((take) => take.enabled);
    setState(() {
      for (final take in takes) {
        if (anyOn) {
          _enabled.remove(take.id);
        } else {
          _enabled.add(take.id);
        }
      }
    });
    unawaited(_rebuildMix());
  }

  /// Not a uuid, so it can never collide with a real layer's id.
  static const String _referenceId = 'reference';

  Take? get _referenceTake {
    final reference = _reference;
    final path = _referencePath;
    if (reference == null || path == null) return null;
    return Take(
      id: _referenceId,
      path: path,
      label: reference.displayName,
      recordedAt: DateTime.now(),
      durationMs: reference.durationMs ?? 0,
      enabled: _enabled.contains(_referenceId),
      part: TakePart.other,
      namedByHand: true,
    );
  }

  List<Take> get _takes {
    final layers = _layers ?? const <SharedLayer>[];
    final reference = _referenceTake;
    return <Take>[
      if (reference != null) reference,
      for (final layer in layers)
        if (_localPaths[layer.id] != null)
          layer.toTake(_localPaths[layer.id]!, enabled: _enabled.contains(layer.id)),
    ];
  }

  /// Every rebuild writes a new filename.
  ///
  /// It used to be one path, `_mix.wav`, overwritten each time — and
  /// audioplayers keys its cache on the path. So the file changed underneath
  /// it and the player kept handing back the first mix it had ever loaded:
  /// record a second take, press play, hear only the first. The bytes were
  /// right the whole time and the player never looked at them again.
  int _mixVersion = 0;
  String? _lastMixPath;

  Future<String> _nextMixPath() async {
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory('${root.path}/layers/${widget.projectId}');
    if (!await dir.exists()) await dir.create(recursive: true);
    _mixVersion += 1;
    return '${dir.path}/_mix_$_mixVersion.wav';
  }

  Future<bool> _rebuildMix() async {
    final takes = _takes;
    if (takes.every((take) => !take.enabled)) return false;
    final path = await _nextMixPath();
    final result = await Multitrack.writeMixdown(
      takes: takes,
      outputPath: path,
    );
    // The one it replaces, once the new one exists. Old mixes are worthless
    // the moment a take changes, and a directory of them is the sort of thing
    // that quietly fills a phone.
    final previous = _lastMixPath;
    _lastMixPath = result == null ? previous : path;
    if (result != null && previous != null && previous != path) {
      try {
        final stale = File(previous);
        if (await stale.exists()) await stale.delete();
      } catch (_) {
        // A file that will not delete is clutter, not a failure worth
        // interrupting playback for.
      }
    }
    if (mounted && result != null) {
      final silent = result.silentTakeIds.toSet();
      if (!setEquals(silent, _silent)) {
        setState(() {
          _silent
            ..clear()
            ..addAll(silent);
        });
      }
    }
    return result != null;
  }

  Future<void> _record() async {
    if (_busy || _recording) return;
    final allowed = await MicrophoneAccess.ensureGranted(
      context,
      purpose: 'to add a take to this song',
      request: _recorder.hasPermission,
    );
    if (!allowed || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final root = await getApplicationDocumentsDirectory();
      final directory = Directory('${root.path}/layers/${widget.projectId}');
      if (!await directory.exists()) await directory.create(recursive: true);
      final path =
          '${directory.path}/new_${DateTime.now().millisecondsSinceEpoch}.m4a';

      final hasBacking = await _rebuildMix();
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 96000,
          sampleRate: Multitrack.rate,
          numChannels: 1,
          // Echo cancellation would fight the backing track arriving through
          // the microphone, which is the one signal that must survive. Gain
          // and noise suppression are tuned for phone calls and wreck music.
          echoCancel: false,
          noiseSuppress: false,
          autoGain: false,
        ),
        path: path,
      );
      if (hasBacking && _lastMixPath != null) {
        await _player.play(DeviceFileSource(_lastMixPath!));
      }

      _elapsed = Duration.zero;
      _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (mounted) setState(() => _elapsed += const Duration(milliseconds: 200));
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

  Future<void> _stop() async {
    if (!_recording) return;
    _timer?.cancel();
    setState(() {
      _busy = true;
      _recording = false;
      _playing = false;
      _status = 'Saving your take';
    });
    try {
      final path = await _recorder.stop();
      await _player.stop();
      if (path == null || !await File(path).exists()) return;
      if (!mounted) return;

      final described = await askWhatThatWas(context, performer: _performer);
      if (!mounted) return;
      if (described?.performer != null) _performer = described!.performer;

      final part = described?.part ?? TakePart.other;
      final take = Take(
        id: path,
        path: path,
        label: TakeNaming.nextLabel(_takes, part, described?.performer),
        recordedAt: DateTime.now(),
        durationMs: _elapsed.inMilliseconds,
        offsetMs: (_layers ?? const <SharedLayer>[]).isEmpty ? 0 : _offsetMs,
        part: part,
        performer: described?.performer,
      );

      setState(() => _status = 'Sharing it with the room');
      await _service.upload(
        roomId: widget.roomId,
        projectId: widget.projectId,
        take: take,
      );
      // The local recording is not kept: ensureLocal will fetch the canonical
      // copy under its layer id on the next load. Two files for one layer is
      // how a cache starts disagreeing with the thing it caches.
      try {
        await File(path).delete();
      } catch (_) {
        // An orphan in the app's own directory, not worth failing an upload.
      }
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = null;
        });
      }
    }
  }

  Future<void> _togglePlay() async {
    if (_recording) return;
    if (_playing) {
      await _player.stop();
      if (mounted) setState(() => _playing = false);
      return;
    }
    if (!await _rebuildMix() || _lastMixPath == null) return;
    await _player.play(DeviceFileSource(_lastMixPath!));
    if (mounted) setState(() => _playing = true);
  }

  Future<void> _setGain(SharedLayer layer, double gain) async {
    await _update(layer, <String, dynamic>{'gain': gain});
  }

  Future<void> _nudge(SharedLayer layer, int delta) async {
    final next = (layer.offsetMs + delta).clamp(0, 1000);
    await _update(layer, <String, dynamic>{'offset_ms': next});
  }

  /// Writes one field and refreshes, so what everyone hears stays what the
  /// person who played it chose.
  Future<void> _update(SharedLayer layer, Map<String, dynamic> patch) async {
    try {
      await _service.updateLayer(layer, patch);
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _delete(SharedLayer layer) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete ${TakeNaming.describe(layer.toTake('', enabled: true))}?'),
        content: const Text(
          'This removes it for the whole band, and the audio goes with it. '
          'Muting keeps a take out of your mix without touching anyone '
          'else\'s.',
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
    setState(() => _busy = true);
    try {
      await _service.deleteLayer(layer);
      await _load();
    } catch (error) {
      // The database refuses this for anyone but the person who recorded it
      // and the room's owner, so this is a real answer rather than a bug —
      // and saying so plainly beats a button that quietly was not there.
      if (mounted) {
        setState(() => _error =
            'That take belongs to whoever recorded it. You can mute it, '
            'or ask them to remove it. ($error)');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() async {
    final takes = _takes;
    if (takes.isEmpty || _busy) return;
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
              subtitle: const Text('One file of what you hear now.'),
              onTap: () => Navigator.pop(sheetContext, 'mix'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_zip_outlined, color: AppColors.cyan),
              title: const Text('Every take'),
              subtitle: const Text(
                'Each one on its own, with the volumes and timing written '
                'down. Yours to keep.',
              ),
              onTap: () => Navigator.pop(sheetContext, 'layers'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final root = await getApplicationDocumentsDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final file = choice == 'mix'
          ? await TakeExport.mixdown(
              takes: takes,
              outputPath: '${root.path}/export_$stamp.wav',
            )
          : await TakeExport.layerArchive(
              takes: takes,
              outputPath: '${root.path}/export_$stamp.zip',
              songTitle: widget.songTitle,
            );
      if (file == null) return;
      await SharePlus.instance.share(
        ShareParams(files: <XFile>[XFile(file.path)], subject: widget.songTitle),
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final layers = _layers;
    final hasLayers = layers != null && layers.isNotEmpty;
    // Sideways is a desk. A list is the right shape for reading and the wrong
    // shape for balancing: deciding whether the harmony sits well against the
    // lead means comparing them, and on a phone that means remembering one
    // while scrolling to the other. Side by side, the comparison is just the
    // picture. It also gives the landscape orientation something to be.
    final console = MediaQuery.of(context).orientation == Orientation.landscape;
    return Scaffold(
      backgroundColor: AppColors.deepNavy,
      appBar: AppBar(
        backgroundColor: AppColors.deepNavy,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('Takes', style: TextStyle(fontSize: 17)),
            Text(
              widget.songTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.muted, fontSize: 11),
            ),
          ],
        ),
        actions: <Widget>[
          IconButton(
            onPressed: !hasLayers || _busy ? null : () => unawaited(_export()),
            tooltip: 'Save a copy',
            icon: const Icon(Icons.ios_share_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: layers == null
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const CircularProgressIndicator(color: AppColors.gold),
                    if (_status != null) ...<Widget>[
                      const SizedBox(height: 14),
                      Text(_status!,
                          style: const TextStyle(color: AppColors.muted, fontSize: 12.5)),
                    ],
                  ],
                ),
              )
            : console && _takes.isNotEmpty
            ? LayerConsole(
                takes: _takes,
                silentIds: _silent,
                onToggle: (take) => _toggle(take.id),
                onGain: (take) {
                  final layer = _layerFor(take);
                  if (!_mine(take) || layer == null) return null;
                  return (Take _, double value) =>
                      unawaited(_setGain(layer, value));
                },
              )
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 110),
                  children: <Widget>[
                    if (!hasLayers) _EmptyState(),
                    if (_referenceNote != null) ...<Widget>[
                      Container(
                        margin: const EdgeInsets.only(bottom: 14),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.orange.withValues(alpha: 0.09),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(_referenceNote!,
                            style: const TextStyle(
                                color: AppColors.orange, fontSize: 12, height: 1.45)),
                      ),
                    ],
                    if (_error != null) ...<Widget>[
                      Container(
                        margin: const EdgeInsets.only(bottom: 14),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF718B).withValues(alpha: 0.09),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(_error!,
                            style: const TextStyle(
                                color: Color(0xFFFFA0B0), fontSize: 12, height: 1.45)),
                      ),
                    ],
                    if (hasLayers) ...<Widget>[
                      Text(
                        '${layers.length} take${layers.length == 1 ? '' : 's'}',
                        style: const TextStyle(
                          color: AppColors.text,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Wear headphones when you add one, or the backing '
                        'track goes down the microphone with you.',
                        style: TextStyle(
                            color: AppColors.muted, fontSize: 12, height: 1.45),
                      ),
                      const SizedBox(height: 14),
                      ..._partsBody(),
                      const SizedBox(height: 16),
                      _LatencyNote(
                        offsetMs: _offsetMs,
                        onChanged: (value) => setState(() => _offsetMs = value),
                      ),
                    ],
                  ],
                ),
              ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: <Widget>[
              if (hasLayers) ...<Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _recording || _busy
                        ? null
                        : () => unawaited(_togglePlay()),
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
                  key: const Key('layers_record_button'),
                  style: FilledButton.styleFrom(
                    backgroundColor:
                        _recording ? const Color(0xFFFF718B) : AppColors.gold,
                    foregroundColor: AppColors.ink,
                    minimumSize: const Size.fromHeight(52),
                  ),
                  onPressed:
                      _busy ? null : () => unawaited(_recording ? _stop() : _record()),
                  icon: Icon(_recording
                      ? Icons.stop_rounded
                      : Icons.fiber_manual_record_rounded),
                  label: Text(
                    _recording
                        ? 'Stop  ${_elapsed.inMinutes}:${(_elapsed.inSeconds % 60).toString().padLeft(2, '0')}'
                        : hasLayers
                            ? 'Add a take'
                            : 'Record the first take',
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

  /// The takes, flat or grouped depending on how many there are.
  ///
  /// Grouping four things under three headings is ceremony; grouping nine is
  /// the difference between a page and a scroll. The threshold is where a
  /// flat list stops fitting on a phone.
  List<Widget> _partsBody() {
    final takes = _takes;
    if (takes.length <= groupingThreshold) {
      return <Widget>[for (final take in takes) _row(take)];
    }
    return <Widget>[
      for (final (group, members) in groupTakes(takes)) ...<Widget>[
        LayerGroupHeader(
          group: group,
          takes: members,
          collapsed: _collapsed.contains(group),
          onToggleGroup: () => _toggleGroup(members),
          onToggleCollapsed: () => setState(() {
            if (!_collapsed.remove(group)) _collapsed.add(group);
          }),
        ),
        if (!_collapsed.contains(group))
          for (final take in members) _row(take),
      ],
    ];
  }

  Widget _row(Take take) {
    final layer = _layerFor(take);
    final mine = _mine(take);
    return LayerRow(
      take: take,
      subtitle: take.id == _referenceId
          ? 'The recording this song was analyzed from'
          : layer == null
              ? null
              : _subtitleFor(layer),
      silent: _silent.contains(take.id),
      onToggle: () => _toggle(take.id),
      onGain: mine && layer != null
          ? (value) => unawaited(_setGain(layer, value))
          : null,
      onNudge: mine && layer != null
          ? (delta) => unawaited(_nudge(layer, delta))
          : null,
      // No delete on the reference: it is what every chord and lyric on the
      // song sheet came from, and a mixer should not be able to break those.
      onDelete: layer == null ? null : () => unawaited(_delete(layer)),
    );
  }

  String _subtitleFor(SharedLayer layer) {
    final seconds = (layer.durationMs / 1000).round();
    final parts = <String>[
      if (seconds > 0) '${seconds}s',
      if (layer.offsetMs > 0) '${layer.offsetMs} ms trimmed',
      '${(layer.gain * 100).round()}%',
    ];
    return parts.join('   ·   ');
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: <Widget>[
          const Icon(Icons.layers_outlined, size: 42, color: AppColors.line),
          const SizedBox(height: 14),
          const Text(
            'No takes yet',
            style: TextStyle(
              color: AppColors.text,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              'Play the riff. Whoever picks the song up next hears it and can '
              'sing over the top — from wherever they are.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted, fontSize: 13, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// The correction applied to the *next* take recorded on this phone.
class _LatencyNote extends StatelessWidget {
  const _LatencyNote({required this.offsetMs, required this.onChanged});

  final int offsetMs;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
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
                  'Timing on this phone',
                  style: TextStyle(
                    color: AppColors.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text('$offsetMs ms',
                  style: const TextStyle(
                      color: AppColors.gold,
                      fontSize: 13,
                      fontWeight: FontWeight.w800)),
            ],
          ),
          const Text(
            'Every phone records a moment behind what it plays. If your take '
            'lands late against the others, raise this and try again.',
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
