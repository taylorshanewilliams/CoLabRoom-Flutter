import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../services/multitrack.dart';
import '../../services/onset_align.dart';
import '../../services/overdub_session.dart';
import '../../domain/song_analysis_models.dart';
import '../../services/song_analysis_service.dart';
import '../../services/error_reporter.dart';
import '../../services/song_layer_service.dart';
import '../../services/take_export.dart';
import '../../services/take_naming.dart';
import '../../widgets/microphone_disclosure.dart';
import 'layer_console.dart';
import 'layer_group.dart';
import 'take_lane.dart';
import 'take_prompt.dart';
import 'timeline_ruler.dart';

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
    this.layerService,
    this.analysisService,
    super.key,
  });

  /// Substituted in tests, real everywhere else.
  ///
  /// The screen used to build both of these itself, which meant it could not
  /// be pumped at all without a live Supabase — and so the one crash that
  /// mattered most here, a modal opened during initState, was found by a
  /// person on a phone rather than by a test that takes a second to run.
  final SongLayerService? layerService;
  final SongAnalysisService? analysisService;

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
  late final SongLayerService _service = widget.layerService ?? SongLayerService();
  late final SongAnalysisService _analysis =
      widget.analysisService ?? SongAnalysisService();

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

  /// Faces, by the account that recorded the take.
  ///
  /// Keyed on the person rather than the layer: a bandmate with six takes on
  /// a song is one download, not six.
  final Map<String, Uint8List> _photos = <String, Uint8List>{};

  /// The shape of each take, by take id.
  ///
  /// Read after the list is on screen and never awaited by _load: a waveform
  /// is the least urgent thing here and takes must never wait for one.
  final Map<String, List<double>> _waves = <String, List<double>>{};

  /// Where the playhead is, and how long the song runs.
  Duration _position = Duration.zero;
  Duration _span = Duration.zero;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;

  /// True while a finger is on the timeline, so the player's own position
  /// updates do not fight the drag.
  bool _scrubbing = false;
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
    // Before anything plays. A backing track started under the default
    // audio session takes the microphone away from the recorder on both
    // platforms — see OverdubSession, which is where the explanation lives.
    unawaited(OverdubSession.begin());
    // And on this player specifically. It was built as a field initialiser,
    // before this line runs, so the global default may never reach it.
    unawaited(OverdubSession.applyTo(_player));
    _completeSub = _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playing = false;
          _position = Duration.zero;
        });
      }
    });
    _positionSub = _player.onPositionChanged.listen((position) {
      // Ignored mid-drag: the finger is the truth until it lifts, and the
      // player is still reporting where it was.
      if (mounted && !_scrubbing) setState(() => _position = position);
    });
    _durationSub = _player.onDurationChanged.listen((duration) {
      if (mounted) setState(() => _span = duration);
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_completeSub?.cancel());
    unawaited(_positionSub?.cancel());
    unawaited(_durationSub?.cancel());
    unawaited(_recorder.dispose());
    unawaited(_player.dispose());
    // Every other screen in the app is a player, not a recorder.
    unawaited(OverdubSession.end());
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
      unawaited(_loadFaces(layers));
      unawaited(_loadWaves());
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        // An empty list rather than null, which is the difference between
        // "nothing came back" and "we are still waiting".
        //
        // The body only renders once _layers is non-null, so leaving it null
        // here left a spinner turning forever with the error sitting in a
        // field nothing was drawing. A widget test found this by timing out
        // waiting for the animation to stop — which is precisely what a
        // person would have experienced, minus the explanation.
        _layers ??= const <SharedLayer>[];
        _busy = false;
        _status = null;
      });
    }
  }

  String? get _me => Supabase.instance.client.auth.currentUser?.id;

  /// A member's own colour, the same one tinting their lines in the song
  /// sheet. Null for somebody who is not a member of this room — a guest
  /// handed the phone, or a member who has since left.
  Color? _colorForMember(String userId) {
    final room =
        BetaScope.maybeOf(context, listen: false)?.roomById(widget.roomId);
    for (final member in room?.members ?? const <RoomMember>[]) {
      if (member.userId == userId) return Color(member.colorValue);
    }
    return null;
  }

  /// Reads the shape of every take, then repaints once.
  ///
  /// One pass over samples the mixer has already decoded and cached, so this
  /// costs a disk read rather than a decode. Repainting once at the end
  /// rather than per take keeps a six-take song from rebuilding six times.
  Future<void> _loadWaves() async {
    var found = false;
    for (final take in _takes) {
      if (_waves.containsKey(take.id)) continue;
      try {
        final wave = await Multitrack.envelopeFor(take);
        if (wave.isNotEmpty) {
          _waves[take.id] = wave;
          found = true;
        }
      } catch (_) {
        // A take whose shape cannot be read still plays. The lane draws a
        // rule instead of a waveform and nothing else changes.
      }
    }
    if (found && mounted) setState(() {});
  }

  /// Fetches the faces for whoever is on this song, then repaints once.
  ///
  /// Deliberately after the list is already on screen and deliberately not
  /// awaited by [_load]: a picture is the least important thing here, and
  /// takes must never wait on one. Repainting once at the end rather than per
  /// face keeps a six-person song from rebuilding the list six times.
  Future<void> _loadFaces(List<SharedLayer> layers) async {
    final wanted = <String, String>{};
    for (final layer in layers) {
      final path = layer.recordedByAvatarPath;
      if (path != null && !_photos.containsKey(layer.recordedBy)) {
        wanted[layer.recordedBy] = path;
      }
    }
    if (wanted.isEmpty) return;
    var found = false;
    for (final entry in wanted.entries) {
      final bytes = await _service.avatarBytes(entry.value);
      if (bytes != null) {
        _photos[entry.key] = bytes;
        found = true;
      }
    }
    if (found && mounted) setState(() {});
  }

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

  /// What the recorder is asked for, and therefore what a take of a given
  /// length should roughly weigh. Named because the guard in _stop has to
  /// agree with it — two numbers that must match are one number.
  static const int _recordingBitRate = 96000;

  /// How long the recorder runs before the backing track starts.
  ///
  /// Deterministic, so it is subtracted back out rather than measured: the
  /// take is this much older than the music, and every take that plays along
  /// starts life exactly this far ahead.
  static const int _recorderHeadStartMs = 300;

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
  ///
  /// Now counted from the clock rather than from one, and static rather than
  /// per screen.
  ///
  /// The first version of this counted 1, 2, 3 from a field on the state —
  /// which resets every time the screen is opened. So the second visit wrote
  /// `_mix_1.wav` again, over a path the player had already cached, and the
  /// stale-mix bug this was written to fix came straight back on any session
  /// that left the screen and returned. A path is only unique if nothing can
  /// ever reset the thing generating it.
  static int _mixSequence = 0;
  String? _lastMixPath;

  bool _sweptOldMixes = false;

  Future<String> _nextMixPath() async {
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory('${root.path}/layers/${widget.projectId}');
    if (!await dir.exists()) await dir.create(recursive: true);
    if (!_sweptOldMixes) {
      _sweptOldMixes = true;
      await _sweepOldMixes(dir);
    }
    _mixSequence += 1;
    final stamp = DateTime.now().microsecondsSinceEpoch;
    return '${dir.path}/_mix_${stamp}_$_mixSequence.wav';
  }

  /// Mixes left behind by earlier visits, which nothing will ever play again.
  ///
  /// Unique filenames stop the cache going stale and start the directory
  /// filling up instead; one of those is a bug and the other is housekeeping.
  ///
  /// Done from here rather than from _load on purpose. Loading the list of
  /// takes must not depend on a plugin: the widget tests build this screen
  /// with no platform channels behind it precisely so that a screen which
  /// cannot finish loading is caught in a second rather than on a phone, and
  /// a path_provider call on that path leaves the progress ring turning
  /// forever — which is the exact bug those tests exist to catch, reached by
  /// a new route. Nothing needs a directory until there is a mix to write.
  Future<void> _sweepOldMixes(Directory dir) async {
    try {
      await for (final entry in dir.list()) {
        if (entry is! File) continue;
        final name = entry.uri.pathSegments.last;
        if (!name.startsWith('_mix_') || !name.endsWith('.wav')) continue;
        if (entry.path == _lastMixPath) continue;
        await entry.delete();
      }
    } catch (_) {
      // Clutter, not a failure worth showing anybody.
    }
  }

  /// Whether what is about to play is a click on its own, and so should loop.
  bool _loopingClick = false;

  Future<bool> _rebuildMix() async {
    final takes = _takes;
    final anythingToPlay = takes.any((take) => take.enabled);
    // A click with nothing under it is still something to play against — it
    // is how the first take of a song with no recording gets a tempo.
    if (!anythingToPlay && !_clickOn) return false;
    final path = await _nextMixPath();

    // Two ways to end up with something to play, and only one of them
    // produces a MixResult — a click on its own has no takes to report as
    // silent and no peak worth measuring. `wrote` is the question the rest of
    // this method actually asks.
    MixResult? result;
    bool wrote;
    if (anythingToPlay) {
      result = await Multitrack.writeMixdown(
        takes: takes,
        outputPath: path,
        clickBpm: _clickOn ? _tempo : null,
        clickBeatsPerBar: _beatsPerBar,
        // The song's own beats, unless somebody has chosen a tempo. A click
        // counted from zero starts wherever the intro leaves it and is wrong
        // against the record for the whole song; these came out of the
        // analysis and land where the band actually played.
        clickBeatsMs: _clickOn && _clickBpm == null
            ? (_reference?.beatsMs ?? const <int>[])
            : const <int>[],
      );
      wrote = result != null;
      _loopingClick = false;
    } else {
      await Multitrack.writeClickOnly(
        bpm: _tempo,
        outputPath: path,
        beatsPerBar: _beatsPerBar,
      );
      wrote = true;
      // Eight bars of click, looped. Safe to loop in a way a backing track
      // never is: there is nothing else playing for it to drift against.
      _loopingClick = true;
    }

    // The one it replaces, once the new one exists. Old mixes are worthless
    // the moment a take changes, and a directory of them is the sort of thing
    // that quietly fills a phone.
    final previous = _lastMixPath;
    _lastMixPath = wrote ? path : previous;
    // A new mix is a different recording. Whatever was paused is gone.
    if (wrote) _pausedAt = null;
    if (wrote && previous != null && previous != path) {
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
    return wrote;
  }

  /// Plays the current mix, looping it when it is only a click.
  Future<void> _playMix({Duration from = Duration.zero}) async {
    final path = _lastMixPath;
    if (path == null) return;
    await _player.setReleaseMode(
      _loopingClick ? ReleaseMode.loop : ReleaseMode.release,
    );
    await _player.play(DeviceFileSource(path));
    // Seeked after play rather than before. There is no source to seek into
    // until one is set, so a seek beforehand lands on the previous mix or on
    // nothing at all.
    if (from > Duration.zero) await _player.seek(from);
  }

  /// Where the song was when recording started.
  ///
  /// The take is placed here in the mix rather than at the top, which is the
  /// whole of punching in.
  Duration _punchInAt = Duration.zero;

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
      _alignedNote = null;
    });
    try {
      final root = await getApplicationDocumentsDirectory();
      final directory = Directory('${root.path}/layers/${widget.projectId}');
      if (!await directory.exists()) await directory.create(recursive: true);
      final path =
          '${directory.path}/new_${DateTime.now().millisecondsSinceEpoch}.m4a';

      // Where the playhead is, captured before anything moves it.
      //
      // This is the whole of punching in: a take no longer has to begin at
      // the top of the song. Adding a harmony to the last chorus of a
      // three-minute song meant sitting through the three minutes, because
      // record always rewound and the mixer had no way to say a take belongs
      // anywhere but zero.
      _punchInAt = _position;
      final hasBacking = await _rebuildMix();
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: _recordingBitRate,
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
      _backingWasPlaying = hasBacking && _lastMixPath != null;
      if (_backingWasPlaying) {
        // The recorder gets a head start before anything plays.
        //
        // latency_probe_screen has done this since it was written, with the
        // comment "the recorder needs to be genuinely running before anything
        // is played" — and that screen records while playing, with these same
        // settings, and works. This one called play() the instant start()
        // returned.
        //
        // Which fits what the failures actually look like. Two silent takes
        // reached the database at *byte-identical* sizes, 2,486 bytes, for
        // two different durations — 4,000 ms and 3,600 ms. A file whose size
        // does not move with its length contains no audio frames at all: it
        // is an empty container, not a recording of silence. The encoder was
        // being asked to start at the same moment playback took the audio
        // device, and it never started at all.
        await Future<void>.delayed(
          const Duration(milliseconds: _recorderHeadStartMs),
        );
        await _playMix(from: _punchInAt);
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

      // Every way this can end without a take now says so.
      //
      // These were bare `return`s inside the try, so a recorder that gave
      // back nothing produced no take, no error and no message — the screen
      // simply went back to how it looked before, which is indistinguishable
      // from never having pressed the button. Whatever is wrong, a person is
      // owed the difference between "that failed" and "nothing happened".
      if (path == null) {
        throw StateError(
          'The recorder returned no file. The take was not saved.',
        );
      }
      final recorded = File(path);
      if (!await recorded.exists()) {
        throw StateError('The recording did not reach the disk at $path.');
      }
      final size = await recorded.length();
      if (size < 1024) {
        throw StateError(
          'The recording is empty ($size bytes) — the microphone may not have '
          'started. The take was not saved.',
        );
      }

      // What the file contains, not how big it is. A take recorded while the
      // audio session was wrong is a well-formed m4a of nothing: it passes
      // every check above, uploads cleanly, and arrives in front of the band
      // as a part that cannot be heard. Checked here — before the upload,
      // while the person who played it is still holding the phone — because
      // this is the only moment when "play it again" is a cheap answer.
      // How much audio is in the file, against how long the recorder ran.
      //
      // The decoded-peak check below is not enough on its own and a take
      // proved it: 2,486 bytes for 3,600 ms of AAC — six per cent of what a
      // real recording weighs at 96 kbps — decoded to a noise floor just
      // above the threshold and was saved as a part nobody could hear. That
      // is the second time the same 2,486 bytes has reached the database.
      //
      // Weight is the blunter instrument and the harder one to fool. Silence
      // costs an encoder almost nothing to store, so a take this light did
      // not capture a room, whatever its samples decode to.
      final expectedBytesPerSecond = _recordingBitRate / 8;
      final seconds = _elapsed.inMilliseconds / 1000;
      if (seconds > 0.5 && size < expectedBytesPerSecond * seconds * 0.25) {
        unawaited(ErrorReporter().reportError(
          service: 'layers',
          stage: 'capture',
          message: 'Silent capture: $size bytes for ${_elapsed.inMilliseconds} ms '
              '(expected around ${(expectedBytesPerSecond * seconds).round()}), '
              'backing track ${_backingWasPlaying ? "playing" : "not playing"}',
          projectId: widget.projectId,
        ));
        throw StateError(
          'That take recorded almost nothing — $size bytes in '
          '${seconds.toStringAsFixed(1)} seconds, where a real take is about '
          '${(expectedBytesPerSecond * seconds / 1024).round()} KB. The '
          'microphone was open but the phone was not giving it any sound. It '
          'was not saved. Wearing headphones is the most reliable fix.',
        );
      }

      final samples = await Multitrack.readRecording(path);
      if (samples == null) {
        throw StateError(
          'That take could not be read back after recording, so it was not '
          'saved. The file is still on this phone.',
        );
      }
      final peak = Multitrack.peakOf(samples);
      if (peak < Multitrack.silenceFloor) {
        throw StateError(
          'That take came back silent — the microphone was open but captured '
          'nothing. It was not saved. If another app is using the microphone, '
          'close it and record again.',
        );
      }
      // Two `if (!mounted) return;` guards used to sit here, one before the
      // naming sheet and one after it. Both threw the recording away.
      //
      // That is the wrong trade in the wrong direction. A person who leaves
      // this screen in the second between stopping and naming has still
      // played something, and the app had already decided it was worth
      // keeping — it passed the silence check two lines ago. Losing it
      // because a widget went away is the most expensive failure this
      // feature has, and it is silent: the screen is gone, so there is
      // nowhere left to say so.
      //
      // Asked only while there is somebody to ask. An unnamed take is a
      // generic name and a rename later; a discarded one is somebody's
      // playing.
      final described = mounted
          ? await askWhatThatWas(context, performer: _performer)
          : null;
      if (described?.performer != null) _performer = described!.performer;

      final part = described?.part ?? TakePart.other;
      final take = Take(
        id: path,
        path: path,
        label: TakeNaming.nextLabel(_takes, part, described?.performer),
        recordedAt: DateTime.now(),
        durationMs: _elapsed.inMilliseconds,
        offsetMs: _alignedOffsetFor(samples),
        startMs: _punchInAt.inMilliseconds,
        part: part,
        performer: described?.performer,
      );

      // Guarded, and the upload does not depend on it.
      //
      // This was a bare setState, and the app reported the consequence:
      // "Saving a take failed: setState() called after dispose()". The
      // exception fires *before* the upload line, gets caught by the handler
      // below, and the recording is gone — because somebody left the screen
      // in the second between naming their take and it being sent.
      //
      // A take that has been played is the most expensive thing this feature
      // can lose. Whether a widget is still on screen has nothing to do with
      // whether the audio should be kept.
      if (mounted) setState(() => _status = 'Sharing it with the room');
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
        // The decoded copy the silence check just made, which is keyed to a
        // path that is about to stop existing.
        final decoded = File('$path.pcm.wav');
        if (await decoded.exists()) await decoded.delete();
      } catch (_) {
        // An orphan in the app's own directory, not worth failing an upload.
      }
      await _load();
    } catch (error) {
      // Reported as well as shown. A take that fails to save is the single
      // most costly failure in this feature — somebody played something and
      // it is gone — and until now the only record of it was a sentence on
      // one person's screen that vanished on the next rebuild.
      unawaited(ErrorReporter().reportError(
        service: 'layers',
        stage: 'upload',
        message: 'Saving a take failed: $error',
        projectId: widget.projectId,
      ));
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

  /// How late this take came back, measured rather than guessed.
  ///
  /// Latency is the thing most likely to make somebody give up on overdubs:
  /// a part that is right but forty milliseconds behind sounds like bad
  /// playing, and the only remedy the app offered was a slider defaulting to
  /// zero that nobody can set correctly by ear on the first go.
  ///
  /// OnsetAlign has existed and been tested this whole time — it asks how far
  /// this take must be shifted for its attacks to land on the beat grid the
  /// analysis already computed, which needs no calibration and no memory of
  /// the device. It was only ever reachable from a developer screen.
  ///
  /// Falls back to the manual value when it cannot answer: a song with no
  /// analysis has no grid, and a sustained part gives the arithmetic nothing
  /// to bite on. `trustworthy` is the guard for the second case — a held
  /// chord still produces a number, and it is noise wearing the shape of an
  /// answer.
  int _alignedOffsetFor(Float64List samples) {
    // The head start is known, not measured. A take that played along began
    // recording before the music did, so that much of its front is the room
    // before the song — and it is subtracted before anything is measured.
    //
    // This matters more than it sounds. alignToGrid searches at most half a
    // beat, because a beat grid repeats and searching further lets a take
    // snap a whole beat late and call itself aligned. At 120bpm half a beat
    // is 250ms — less than the head start alone. Handing it the untrimmed
    // take would put the true answer outside the only window it is allowed
    // to look in.
    final headStart = _backingWasPlaying ? _recorderHeadStartMs : 0;
    final manual = headStart +
        ((_layers ?? const <SharedLayer>[]).isEmpty ? 0 : _offsetMs);
    // The analysis's grid when there is one; the metronome's when there is
    // not. Recording against a click means the tempo is not inferred but
    // chosen, which is the one case automatic alignment could not answer
    // before — a song with no analysis had no grid, and the person was left
    // with a slider defaulting to zero.
    var beats = _reference?.beatsMs ?? const <int>[];
    if (beats.length < 2 && _clickOn) {
      beats = Multitrack.beatsForTempo(
        bpm: _tempo,
        throughMs: (samples.length * 1000 / Multitrack.rate).round(),
        beatsPerBar: _beatsPerBar,
      );
    }

    // Beats measured from where this take starts, not from the top of the
    // song. A take punched in at 2:40 hears its first downbeat a few hundred
    // milliseconds in, not two minutes and forty seconds in — handing the
    // aligner the song's absolute grid would put every candidate shift far
    // outside the half-beat window it is allowed to search, and it would
    // decline to answer on a take it could have timed perfectly.
    final punchedInAt = _punchInAt.inMilliseconds;
    if (punchedInAt > 0 && beats.length > 1) {
      beats = <int>[
        for (final at in beats)
          if (at >= punchedInAt) at - punchedInAt,
      ];
    }
    if (beats.length < 2) return manual;

    final skip = (headStart * Multitrack.rate / 1000).round();
    if (skip >= samples.length) return manual;
    final afterHeadStart =
        skip == 0 ? samples : Float64List.sublistView(samples, skip);

    final result = OnsetAlign.alignToGrid(
      afterHeadStart,
      beats,
      rate: Multitrack.rate,
    );
    if (result == null || !result.trustworthy) return manual;

    final total = headStart + result.shiftMs;
    _alignedNote = total > 0
        ? 'Timed to the beat automatically — $total ms trimmed.'
        : 'Timed to the beat automatically — nothing needed trimming.';
    return total;
  }

  /// What the alignment did, said once after the take lands.
  String? _alignedNote;

  /// Whether a backing track was playing while the last take was recorded.
  ///
  /// Reported alongside a silent capture, because it is the one fact that
  /// separates the two explanations still on the table: a phone that cannot
  /// record while it plays, or a phone that cannot record at all. Two rounds
  /// of this have been guessed at from byte counts after the fact; a flag
  /// costs nothing and answers it.
  bool _backingWasPlaying = false;

  /// The metronome, and the tempo it clicks at.
  ///
  /// Off by default: a click nobody asked for is the fastest way to make
  /// somebody put the phone down. The tempo starts at the song's own, when
  /// the analysis found one, because a band's first instinct is to play along
  /// with the record rather than to a number they chose.
  bool _clickOn = false;
  double? _clickBpm;

  double get _tempo =>
      _clickBpm ?? _reference?.bpm?.roundToDouble() ?? 100;

  int get _beatsPerBar => _reference?.beatsPerBar ?? 4;

  /// The mix that was playing when somebody pressed pause.
  ///
  /// Held so that pressing play again resumes rather than restarts. Cleared
  /// whenever a new mix is written, because a mute or a volume change makes a
  /// different file and resuming into it would be resuming into audio that no
  /// longer exists.
  String? _pausedAt;

  Future<void> _togglePlay() async {
    if (_recording) return;
    if (_playing) {
      // Paused, not stopped. stop() winds the position back to zero, which is
      // why pressing play again always started the song over — a small thing
      // on a thirty-second sketch and unusable on a three-minute song when
      // the part you want to hear is at 2:40.
      await _player.pause();
      _pausedAt = _lastMixPath;
      if (mounted) setState(() => _playing = false);
      return;
    }

    // Only built when there is nothing to play yet. Every change that alters
    // the mix — a mute, a fader, the metronome — rebuilds it as it happens,
    // so by the time somebody presses play it is already current. Rebuilding
    // here as well wrote a second identical file under a new name, and a new
    // name is a new source, which starts at zero.
    if (_lastMixPath == null) {
      if (!await _rebuildMix() || _lastMixPath == null) return;
    }

    if (_pausedAt == _lastMixPath) {
      await _player.resume();
    } else {
      await _playMix();
    }
    _pausedAt = null;
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

    // What there is to hear, which is not the same as what has been recorded
    // here.
    //
    // These were one flag. hasLayers counts only the shared takes, and it
    // gated the empty state, the whole list *and* the play button — so a song
    // that had been analyzed but never overdubbed fetched its recording,
    // downloaded it, put it in _takes, and then drew "No takes yet" over the
    // top of it with nothing to press. Every analyzed song in the account
    // behaved that way; the one project with takes on it looked fine, which
    // is what made it read like a data problem rather than a layout one.
    //
    // The song's own recording is the thing you add a take *to*. It has to be
    // on screen before there is anything to add.
    final playable = _takes;
    final hasSomethingToHear = playable.isNotEmpty;
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
                    if (!hasSomethingToHear) _EmptyState(),
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
                    // Said out loud, because silently moving somebody's
                    // playing is worse than not moving it. If the timing is
                    // wrong they need to know something adjusted it before
                    // they go hunting for a fault in their own take.
                    if (_alignedNote != null) ...<Widget>[
                      Container(
                        margin: const EdgeInsets.only(bottom: 14),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.cyan.withValues(alpha: 0.09),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: <Widget>[
                            const Icon(Icons.auto_fix_high_rounded,
                                size: 15, color: AppColors.cyan),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(_alignedNote!,
                                  style: const TextStyle(
                                      color: AppColors.cyan,
                                      fontSize: 12,
                                      height: 1.45)),
                            ),
                          ],
                        ),
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
                    if (hasSomethingToHear) ...<Widget>[
                      Text(
                        hasLayers
                            ? '${layers.length} take${layers.length == 1 ? '' : 's'}'
                            // The recording is present and nobody has played
                            // over it yet — said as an invitation rather than
                            // as "0 takes", which reads like a failure.
                            : 'The song, ready to play over',
                        style: const TextStyle(
                          color: AppColors.text,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Wear headphones when you add one, or the backing '
                        'track goes down the microphone with you. '
                        'Turn the phone sideways for the faders.',
                        style: TextStyle(
                            color: AppColors.muted, fontSize: 12, height: 1.45),
                      ),
                      const SizedBox(height: 14),
                      _timeline(),
                      const SizedBox(height: 16),
                      _MetronomeNote(
                        on: _clickOn,
                        bpm: _tempo,
                        fromAnalysis: _reference?.bpm != null && _clickBpm == null,
                        onToggle: (value) {
                          setState(() => _clickOn = value);
                          unawaited(_rebuildMix());
                        },
                        onTempo: (value) {
                          setState(() => _clickBpm = value);
                          unawaited(_rebuildMix());
                        },
                      ),
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
              if (hasSomethingToHear) ...<Widget>[
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
                        : _position > Duration.zero
                            // Says where it will land. Punching in is only
                            // useful if somebody can see that it is about to
                            // happen — an unlabelled record button at 2:40
                            // looks exactly like one at 0:00.
                            ? 'Punch in at ${_clock(_position)}'
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
    return TakeLane(
      take: take,
      wave: _waves[take.id] ?? const <double>[],
      playedFraction: _playedFraction,
      startsFraction: _startFractionFor(take),
      spansFraction: _spanFractionFor(take),
      playerColor: layer == null ? null : _colorForMember(layer.recordedBy),
      playerPhoto: layer == null ? null : _photos[layer.recordedBy],
      subtitle: take.id == _referenceId ? 'the song' : null,
      silent: _silent.contains(take.id),
      onToggle: () => _toggle(take.id),
      // No delete on the reference: it is what every chord and lyric on the
      // song sheet came from, and a mixer should not be able to break those.
      onDelete: layer == null ? null : () => unawaited(_delete(layer)),
      onAdjust: mine && layer != null
          ? () => unawaited(_showLevels(layer, take))
          : null,
    );
  }

  /// One take's volume and timing, on demand.
  ///
  /// The redesign took the fader off the row to make room for the waveform.
  /// That must not mean losing it: rotating the phone to change one volume is
  /// a worse trade than a tap.
  Future<void> _showLevels(SharedLayer layer, Take take) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.deepNavy,
      builder: (sheetContext) {
        var gain = layer.gain;
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      TakeNaming.describe(take),
                      style: const TextStyle(
                          color: AppColors.text,
                          fontSize: 17,
                          fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 2),
                    Text(_subtitleFor(layer),
                        style: const TextStyle(
                            color: AppColors.muted, fontSize: 12)),
                    const SizedBox(height: 18),
                    Row(
                      children: <Widget>[
                        const Text('Volume',
                            style: TextStyle(
                                color: AppColors.text,
                                fontSize: 13,
                                fontWeight: FontWeight.w700)),
                        const Spacer(),
                        Text('${(gain * 100).round()}%',
                            style: const TextStyle(
                                color: AppColors.cyan,
                                fontSize: 13,
                                fontWeight: FontWeight.w800)),
                      ],
                    ),
                    Slider(
                      value: gain.clamp(0.0, 1.5),
                      max: 1.5,
                      divisions: 30,
                      activeColor: AppColors.cyan,
                      inactiveColor: AppColors.line,
                      onChanged: (value) => setSheetState(() => gain = value),
                      onChangeEnd: (value) => unawaited(_setGain(layer, value)),
                      semanticFormatterCallback: (value) =>
                          'Volume ${(value * 100).round()} percent',
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: <Widget>[
                        const Text('Timing',
                            style: TextStyle(
                                color: AppColors.text,
                                fontSize: 13,
                                fontWeight: FontWeight.w700)),
                        const Spacer(),
                        IconButton(
                          onPressed: () {
                            unawaited(_nudge(layer, -10));
                            Navigator.pop(sheetContext);
                          },
                          tooltip: '10 ms earlier',
                          icon: const Icon(Icons.remove_rounded,
                              color: AppColors.muted),
                        ),
                        Text('${layer.offsetMs} ms',
                            style: const TextStyle(
                                color: AppColors.text,
                                fontSize: 13,
                                fontWeight: FontWeight.w800)),
                        IconButton(
                          onPressed: () {
                            unawaited(_nudge(layer, 10));
                            Navigator.pop(sheetContext);
                          },
                          tooltip: '10 ms later',
                          icon: const Icon(Icons.add_rounded,
                              color: AppColors.muted),
                        ),
                      ],
                    ),
                    const Text(
                      'An analyzed song times each take automatically. This is '
                      'for the last few milliseconds.',
                      style: TextStyle(
                          color: AppColors.muted, fontSize: 11.5, height: 1.4),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// How long the whole song runs, for the ruler and the playhead.
  ///
  /// The player's own duration when it has one, and the longest take before
  /// anything has played — so the timeline is drawn correctly on arrival
  /// rather than snapping into place at the first press of play.
  Duration get _songSpan {
    if (_span > Duration.zero) return _span;
    var longest = 0;
    for (final take in _takes) {
      final end = take.durationMs;
      if (end > longest) longest = end;
    }
    return Duration(milliseconds: longest);
  }

  double get _playedFraction {
    final span = _songSpan.inMilliseconds;
    if (span <= 0) return 0;
    return (_position.inMilliseconds / span).clamp(0.0, 1.0);
  }

  /// How much of the song's width one take occupies.
  ///
  /// A forty-second harmony on a three-minute song draws a short lane. That
  /// is the fact a list of equal-width rows could never show, and the reason
  /// somebody can see at a glance that a part stops before the last chorus.
  static String _clock(Duration at) {
    final seconds = at.inSeconds;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  /// How far into the song a take begins.
  double _startFractionFor(Take take) {
    final span = _songSpan.inMilliseconds;
    if (span <= 0 || take.startMs <= 0) return 0;
    return (take.startMs / span).clamp(0.0, 0.98);
  }

  double _spanFractionFor(Take take) {
    final span = _songSpan.inMilliseconds;
    if (span <= 0 || take.durationMs <= 0) return 1;
    return (take.durationMs / span).clamp(0.05, 1.0);
  }

  /// Moves the playhead, and the audio with it.
  Future<void> _scrubTo(double fraction) async {
    final span = _songSpan;
    if (span <= Duration.zero) return;
    final at = Duration(
      milliseconds: (span.inMilliseconds * fraction.clamp(0.0, 1.0)).round(),
    );
    setState(() => _position = at);
    try {
      await _player.seek(at);
    } catch (_) {
      // Nothing loaded yet. The playhead still moved, and the next press of
      // play starts from where they left it.
    }
  }

  /// The lanes, under one clock.
  ///
  /// The ruler, the playhead and the drag target are one widget rather than
  /// three because they are one idea: these lanes share a timeline. Split
  /// across the screen they would read as a progress bar that happens to sit
  /// above some rows.
  Widget _timeline() {
    const headers = 112.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final laneWidth = math.max(1.0, constraints.maxWidth - headers);
        void scrub(Offset local) {
          _scrubbing = true;
          unawaited(_scrubTo((local.dx - headers) / laneWidth));
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) {
            scrub(details.localPosition);
            _scrubbing = false;
          },
          onHorizontalDragStart: (details) => scrub(details.localPosition),
          onHorizontalDragUpdate: (details) => scrub(details.localPosition),
          onHorizontalDragEnd: (_) => _scrubbing = false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              TimelineRuler(
                totalMs: _songSpan.inMilliseconds,
                leftInset: headers,
              ),
              const SizedBox(height: 6),
              Stack(
                children: <Widget>[
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (final widget in _partsBody()) widget,
                    ],
                  ),
                  if (_songSpan > Duration.zero)
                    Playhead(at: _playedFraction, leftInset: headers),
                ],
              ),
            ],
          ),
        );
      },
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
/// The metronome, and the tempo it clicks at.
///
/// Summed into the backing track rather than played beside it — see
/// Multitrack.click. A click from a second player drifts against the first,
/// and a metronome that drifts teaches somebody their timing is wrong when it
/// is the app's.
class _MetronomeNote extends StatelessWidget {
  const _MetronomeNote({
    required this.on,
    required this.bpm,
    required this.fromAnalysis,
    required this.onToggle,
    required this.onTempo,
  });

  final bool on;
  final double bpm;

  /// Whether this tempo came from the song rather than from a person, which
  /// is worth saying: it is the difference between a number the app measured
  /// and one somebody has to trust.
  final bool fromAnalysis;
  final ValueChanged<bool> onToggle;
  final ValueChanged<double> onTempo;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 12),
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
              Icon(
                Icons.av_timer_rounded,
                size: 18,
                color: on ? AppColors.cyan : AppColors.muted,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Metronome',
                  style: TextStyle(
                      color: AppColors.text,
                      fontSize: 13,
                      fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                '${bpm.round()} bpm',
                style: TextStyle(
                  color: on ? AppColors.cyan : AppColors.muted,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Switch(
                value: on,
                activeThumbColor: AppColors.cyan,
                onChanged: onToggle,
              ),
            ],
          ),
          if (on) ...<Widget>[
            Row(
              children: <Widget>[
                IconButton(
                  onPressed: bpm <= 40 ? null : () => onTempo(bpm - 1),
                  tooltip: 'One beat per minute slower',
                  icon: const Icon(Icons.remove_rounded,
                      size: 18, color: AppColors.muted),
                ),
                Expanded(
                  child: Slider(
                    value: bpm.clamp(40, 220),
                    min: 40,
                    max: 220,
                    divisions: 180,
                    label: '${bpm.round()} bpm',
                    activeColor: AppColors.cyan,
                    inactiveColor: AppColors.line,
                    onChanged: (value) => onTempo(value.roundToDouble()),
                    semanticFormatterCallback: (value) =>
                        '${value.round()} beats per minute',
                  ),
                ),
                IconButton(
                  onPressed: bpm >= 220 ? null : () => onTempo(bpm + 1),
                  tooltip: 'One beat per minute faster',
                  icon: const Icon(Icons.add_rounded,
                      size: 18, color: AppColors.muted),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 4, right: 8),
              child: Text(
                fromAnalysis
                    ? "This song's own tempo, from its analysis. Change it and "
                        'the click follows you instead.'
                    : 'Takes recorded to a click can be timed to the beat '
                        'automatically, even on a song that has never been '
                        'analyzed.',
                style: const TextStyle(
                    color: AppColors.muted, fontSize: 11.5, height: 1.4),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

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
            'Every phone records a moment behind what it plays. An analyzed '
            'song times each take to its beat automatically — this is the '
            'fallback for songs with no analysis yet, and for parts with no '
            'clear attack to measure.',
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
