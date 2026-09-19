import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/audio_source_for.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../app/routes.dart';
import '../../data/music_repository.dart';
import '../../domain/loop_round.dart';
import '../../domain/moment_note.dart';
import '../../domain/music_models.dart';
import '../../services/click_player.dart';
import '../../services/copy_text.dart';
import '../../services/moment_link.dart';
import '../../services/multitrack.dart';
import '../../services/overdub_session.dart';
import '../../domain/song_analysis_models.dart';
import '../../services/song_analysis_service.dart';
import '../../services/error_reporter.dart';
import '../../services/song_layer_service.dart';
import '../../services/spoken_note_recorder.dart';
import '../../services/take_export.dart';
import '../../services/take_naming.dart';
import '../../services/user_facing_error.dart';
import '../../widgets/microphone_disclosure.dart';
import 'layer_console.dart';
import 'moment_notes.dart';
import 'my_part.dart';
import 'song_level_store.dart';
import 'layer_group.dart';
import 'sealing_a_take.dart';
import 'sending_a_take.dart';
import 'take_count_in.dart';
import 'take_lane.dart';
import 'take_prompt.dart';
import 'take_turns.dart';
import 'take_turns_card.dart';
import 'then_and_now.dart';
import 'timeline_ruler.dart';
import '../../widgets/problem_report.dart';

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
    this.spokenNoteRecorder,
    this.embedded = false,
    this.onClose,
    this.openNote,
    this.openAt,
    super.key,
  });

  /// The moment to open on, for arriving from a link somebody sent.
  ///
  /// Every Musician, Same Song, 17 September 2026 (schools, item 1). Unlike
  /// [openNote] this is the whole address — a take and a millisecond — so
  /// there is nothing to match up on arrival. And unlike [openNote] it
  /// plays: somebody who taps "listen to bar 33" asked to hear bar 33, the
  /// way tapping a note asks to hear the bar it is about, where somebody
  /// opening a card from their inbox asked only to read it.
  final MomentAddress? openAt;

  /// The note to open on, for arriving from a notification (0141).
  ///
  /// `public.notifications` has no column for the thing a notification is
  /// about, so the row cannot carry the note's id and this is the address we
  /// have instead: who left it, and the words themselves. See [NoteToOpen].
  final NoteToOpen? openNote;

  /// True when this is a panel inside the song rather than a route on top of
  /// it.
  ///
  /// On a desk the song does not go anywhere to show its takes: the library
  /// stays on the left, the song's own header stays above, and this fills the
  /// middle. What changes is the way out - [onClose] returns to the words
  /// rather than popping a route that was never pushed.
  final bool embedded;

  /// Back to the lyrics, when there is no route to pop.
  final VoidCallback? onClose;

  /// Substituted in tests, real everywhere else.
  ///
  /// The screen used to build both of these itself, which meant it could not
  /// be pumped at all without a live Supabase — and so the one crash that
  /// mattered most here, a modal opened during initState, was found by a
  /// person on a phone rather than by a test that takes a second to run.
  final SongLayerService? layerService;
  final SongAnalysisService? analysisService;

  /// The microphone a spoken note is said into (0152). Substituted in
  /// tests for the same reason as the two above.
  final SpokenNoteRecorder? spokenNoteRecorder;

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

  /// The microphone for a note said rather than typed (0152), and what is
  /// known about the hold while it lasts.
  ///
  /// [_holding] is the finger; [_saying] is the microphone. They differ
  /// while permission is being asked for, and the difference is what stops
  /// a microphone opening under a finger that has already gone.
  late final SpokenNoteRecorder _mic =
      widget.spokenNoteRecorder ?? SpokenNoteRecorder();
  bool _holding = false;
  bool _saying = false;
  Duration _said = Duration.zero;
  Timer? _sayTimer;

  /// Where the playhead was when the finger went down, which is the
  /// moment the note is about -- decided before anybody speaks, the same
  /// rule as the typed note.
  int _sayingAt = 0;

  /// True from letting go until the note is pinned or thrown away.
  bool _savingSaid = false;

  /// Plays a spoken note back, on its own, clear of the mix.
  AudioPlayer? _voice;
  StreamSubscription<void>? _voiceDone;

  /// The spoken note playing now, so its row offers Stop.
  String? _hearing;

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

  /// The notes pinned to this song's recordings, earliest moment first.
  ///
  /// Read from the repository rather than the layer service: they are rows
  /// about a song, like its asks and its nods, and the layer service is the
  /// thing that moves audio.
  List<MomentNote> _notes = const <MomentNote>[];

  /// The note being played, which is also the one drawn open on the lane.
  ///
  /// While it is set, playback turns round at the end of the moment. Cleared
  /// the moment somebody scrubs or pauses, because both of those mean "let go
  /// of this bit".
  MomentNote? _noteLoop;

  /// Then and now, while it plays: the pair, the bars, and the file the two
  /// halves were written to. Null the rest of the time.
  ///
  /// Every Musician, Same Song, 17 September 2026. While it is set the
  /// player is on that file rather than on the mix, and the position it
  /// reports is read back through the track as a place on the song.
  ThenAndNowTrack? _thenAndNow;

  /// Which half is sounding, for the line under the chip.
  ThenOrNow _half = ThenOrNow.then;

  /// The rounds on this song, newest first: a passage going round the room
  /// in turns (0159). Every Musician, Same Song, 17 September 2026.
  ///
  /// Read from the repository, like the notes: they are rows about a song.
  /// Each turn in one is an ordinary take in [_layers], which is why nothing
  /// else on this screen had to learn what a turn is.
  List<LoopRound> _rounds = const <LoopRound>[];

  /// The round a turn is being recorded for, from Record my turn until the
  /// take is saved. While it is set the recording starts on the passage,
  /// stops at its end, and is made against the loop without anybody else's
  /// turn in it.
  LoopRound? _turnFor;

  /// Rung when this screen is about to play or record, so a round's
  /// conversation -- which plays on the card's own player, clear of the mix
  /// -- stops first. One thing sounding at a time, and never a bandmate's
  /// turn going down the microphone under yours.
  final ValueNotifier<int> _hushTurns = ValueNotifier<int>(0);

  /// Whether the note a notification sent us to has already been opened.
  ///
  /// Arriving is a one-off. Every later reload -- and there is one after each
  /// pin and each delete -- leaves the playhead where the person put it.
  bool _openedTheNote = false;

  /// And whether the moment a link sent us to has been opened. The same
  /// one-off rule, for the same reason: the takes are reloaded by a pull, a
  /// share and a delete, and none of those should drag somebody back to the
  /// bar the link named half an hour ago.
  bool _openedTheLink = false;

  /// Where the playhead is, and how long the song runs.
  Duration _position = Duration.zero;
  Duration _span = Duration.zero;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;

  /// True while a finger is on the timeline, so the player's own position
  /// updates do not fight the drag.
  bool _scrubbing = false;
  String? _referenceNote;

  /// The teacher this song's takes go to, when this is a lesson room and you
  /// are the student. Null in every band room, and null for the teacher.
  ///
  /// Every Musician, Same Song, 17 September 2026: a lesson room holds two
  /// people (0129) and a take is private until it is shared (0057), so
  /// sharing here is already a hand-in to one person. All that was missing
  /// was saying so.
  String? _sendTo;

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
          final heardTwice = _thenAndNow;
          _playing = false;
          // A passage heard twice leaves the playhead at its start, so Play
          // hears those bars on their own and the chip hears them again.
          // The top of the song would lose the place.
          _position = heardTwice == null
              ? Duration.zero
              : Duration(milliseconds: heardTwice.passage.startMs);
          _thenAndNow = null;
        });
      }
    });
    _positionSub = _player.onPositionChanged.listen((position) {
      if (!mounted) return;
      // Then and now is one file with the passage in it twice. Read back as
      // a place on the song, so the playhead crosses the same bars once for
      // each half and the line under the chip says which.
      final heardTwice = _thenAndNow;
      if (heardTwice != null) {
        if (!_scrubbing) {
          setState(() {
            _position = Duration(
              milliseconds: heardTwice.songMsAt(position.inMilliseconds),
            );
            _half = heardTwice.halfAt(position.inMilliseconds);
          });
        }
        return;
      }
      // The loop through a note's moment, turned round here rather than with
      // the player's own release mode: that loops the whole file, and this is
      // eleven seconds in the middle of it.
      final loop = _noteLoop;
      if (loop != null && position.inMilliseconds >= loop.loopEndMs) {
        unawaited(_player.seek(Duration(milliseconds: loop.playFromMs)));
        return;
      }
      // Ignored mid-drag: the finger is the truth until it lifts, and the
      // player is still reporting where it was.
      if (!_scrubbing) setState(() => _position = position);
    });
    _durationSub = _player.onDurationChanged.listen((duration) {
      // Not while then and now plays: that file is a few bars long, and the
      // timeline is the song's.
      if (mounted && _thenAndNow == null) setState(() => _span = duration);
    });
    unawaited(_loadSongLevel());
    unawaited(_loadMyPart());
    unawaited(_loadWhoHearsIt());
    unawaited(_load());
  }

  /// Works out whether sharing here means telling a room or handing work to
  /// one teacher.
  ///
  /// Its own load rather than part of [_load], and never awaited by it: the
  /// takes must not wait on this, and a lesson room that cannot be checked
  /// simply says "Share", which is the band wording and is never wrong —
  /// only less specific.
  Future<void> _loadWhoHearsIt() async {
    final controller = BetaScope.maybeOf(context, listen: false);
    final repository = controller?.repository;
    if (controller == null || repository == null) return;
    try {
      final lessonRoom = await repository.isLessonRoom(widget.roomId);
      if (!mounted) return;
      final teacher = teacherToSendTo(
        lessonRoom: lessonRoom,
        room: controller.roomById(widget.roomId),
        me: _me,
      );
      if (teacher != _sendTo) setState(() => _sendTo = teacher);
    } catch (_) {
      // Silent on purpose. Nothing here is worth a sentence on the takes
      // screen: the button keeps the wording it already had.
    }
  }

  Future<void> _loadSongLevel() async {
    final level = await SongLevelStore.load(widget.projectId);
    if (!mounted || level == _songLevel) return;
    setState(() => _songLevel = level);
    unawaited(_applyMixChange());
  }

  /// Which part this person is listening for, kept on this phone. Read
  /// before the takes arrive and applied when the mix is first built, the
  /// same way the song's level is.
  Future<void> _loadMyPart() async {
    final kept = await MyPartStore.load(widget.projectId);
    if (!mounted || kept == _myPart) return;
    setState(() => _myPart = kept);
    unawaited(_applyMixChange());
  }

  /// Your part forward, or everyone but you -- or, tapped again, the room's
  /// own mix. See MyPartMix. Nothing here touches a fader: the choice is
  /// applied when the mix is written and kept on this phone only.
  Future<void> _setMyPart(MyPart choice) async {
    final next = _myPart == choice ? null : choice;
    setState(() {
      _myPart = next;
      // A part brought forward is heard (MyPartMix.apply), so its lane
      // comes off mute to agree with the sound.
      if (next?.way == MyPartWay.forward) _enabled.add(next!.takeId);
    });
    unawaited(MyPartStore.save(widget.projectId, next));
    try {
      await _applyMixChange();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = reportAndDescribe(
            error,
            service: 'layers',
            stage: 'takes.my_part',
            route: 'Takes',
            projectId: widget.projectId,
          ));
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sayTimer?.cancel();
    unawaited(_completeSub?.cancel());
    unawaited(_positionSub?.cancel());
    unawaited(_durationSub?.cancel());
    unawaited(_voiceDone?.cancel());
    unawaited(_recorder.dispose());
    unawaited(_mic.dispose());
    unawaited(_player.dispose());
    unawaited(_countClick?.dispose());
    unawaited(_voice?.dispose());
    _hushTurns.dispose();
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
        //
        // Said out loud to the right audience, though. This used to end
        // `($error)`, so what a musician actually read on the Takes screen was
        //
        //   Everything else still works. ('package:supabase_flutter/src/
        //   supabase.dart': Failed assertion: line 45 pos 7:
        //   '_instance._isInitialized': You must initialize the supabase
        //   instance before calling Supabase.instance)
        //
        // which is the exact defect user_facing_error.dart was written to end,
        // surviving in the one place nothing had looked. The detail is worth
        // keeping — it just belongs in the table rather than on the phone.
        _referenceNote = 'The song has a recording but it could not be loaded '
            'here. Everything else still works.';
        reportAndDescribe(
          error,
          service: 'app',
          stage: 'takes.reference',
          projectId: widget.projectId,
        );
      }

      // Asked for beside the takes, because it decides which of them start
      // switched on, and never holding them up: _readRounds does not throw,
      // and a song whose rounds will not load still plays.
      final reading = _readRounds();
      final layers = await _service.listLayers(widget.projectId);
      for (final layer in layers) {
        // Everything on by default. Somebody opening a song wants to hear the
        // song, not a silent list of what it is made of.
        _enabled.add(layer.id);
        _localPaths[layer.id] = await _service.ensureLocal(layer);
      }
      // Except the turns of a round. Every one of them sits on the same few
      // bars, so switched on together they are four solos at once, which
      // nobody played. They are heard in order from the round's card, and a
      // lane can still be switched on by hand. Taken out after the loop
      // rather than skipped in it, so a draft that was on before it was
      // handed in goes quiet with the rest.
      final rounds = await reading;
      final turns = TakeTurns.turnIds(rounds);
      _enabled.removeAll(turns);
      // And every go at a turn but the last one. They sit on the same bars
      // as each other, so all of them switched on is one person playing
      // over themselves, and the take somebody is deciding about is the one
      // they just recorded. Only theirs go quiet -- nobody else can hear a
      // draft anyway -- and any of them can be switched on by hand.
      for (final round in rounds) {
        final drafts = TakeTurns.draftsFor(round, layers,
            me: _me, alreadyTurns: turns);
        for (var i = 0; i + 1 < drafts.length; i += 1) {
          _enabled.remove(drafts[i].id);
        }
      }
      _rounds = rounds;
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
      unawaited(_loadNotes());
      // After the takes are on screen and never holding them up: a link that
      // will not play still lands somebody on the right song.
      unawaited(_openLinkedMoment());
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = reportAndDescribe(error, service: 'layers', route: 'Takes');
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

  /// The repository, when this screen is inside the app rather than pumped on
  /// its own. Notes are the only thing here that needs it.
  MusicRepository? get _repository =>
      BetaScope.maybeOf(context, listen: false)?.repository;

  /// Who is signed in.
  ///
  /// Through the repository where there is one, which is every real screen
  /// and now the tests as well. The direct reach for Supabase stays as the
  /// fallback and is wrapped, because `Supabase.instance` asserts rather than
  /// returning null when nothing has been initialised — so a screen pumped
  /// with a take on it used to throw out of a getter that only wanted to know
  /// whose take it was.
  /// Both branches are wrapped, because both throw. `Supabase.instance`
  /// asserts rather than returning null when nothing has been initialised,
  /// and `currentUserId` throws an AuthException when nobody is signed in —
  /// and this is read from `build()`, by `_mine(take)` on every lane. A token
  /// expiring while the screen is open used to turn the takes into a red
  /// error box; not knowing who you are means every take is somebody else's,
  /// which is what this returned before there was a repository in it.
  String? get _me {
    try {
      final repository = _repository;
      if (repository != null) return repository.currentUserId;
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  /// The notes on this song, and the one to open if we arrived from a
  /// notification.
  ///
  /// Best-effort and never awaited by [_load]: a song whose notes will not
  /// load still plays, which is the same rule the waveforms and the faces
  /// follow.
  Future<void> _loadNotes() async {
    final repository = _repository;
    if (repository == null) return;
    try {
      final all = await repository.loadMomentNotes(widget.projectId);
      if (!mounted) return;
      // A note goes where its take goes. The only notes on a take that is
      // not in this list are somebody's own, on a draft they have since
      // sealed (0158): put away with it, and back with it on its day, rather
      // than left here pointing at "a take" nobody can find.
      final here = <String>{
        for (final layer in _layers ?? const <SharedLayer>[]) layer.id,
      };
      final notes = <MomentNote>[
        for (final note in all)
          if (note.layerId == null || here.contains(note.layerId)) note,
      ];
      setState(() => _notes = notes);
      // Once, on arrival, and never again.
      //
      // This runs after every pin and every delete as well, and without the
      // latch each of those would drag the playhead back to the note the
      // notification was about — you reply at 0:30, press Pin it, and the
      // screen throws you back to 1:48.
      final opening = widget.openNote;
      if (opening != null && !_openedTheNote) {
        final found = opening.findIn(notes, exceptAuthor: _me);
        if (found != null) {
          _openedTheNote = true;
          // Moved to, not played. Audio starting on its own because somebody
          // opened a notification is a surprise; the moment is where the
          // playhead is left, and Play does the rest.
          await _openNote(found, play: false);
        }
      }
    } catch (error) {
      reportAndDescribe(
        error,
        service: 'layers',
        stage: 'takes.notes',
        projectId: widget.projectId,
      );
    }
  }

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
      _letGoOfMutedPart();
    });
    unawaited(_applyMixChange());
  }

  /// Muting the lane of a part that is forward lets the choice go.
  ///
  /// The mute came second, so it wins. Otherwise the chip says forward over
  /// a lane that says off, and MyPartMix.apply, which keeps a forward part
  /// audible, plays it anyway with everyone else turned down under it.
  void _letGoOfMutedPart() {
    final part = _myPart;
    if (part == null || part.way != MyPartWay.forward) return;
    if (_enabled.contains(part.takeId)) return;
    _myPart = null;
    unawaited(MyPartStore.save(widget.projectId, null));
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
      _letGoOfMutedPart();
    });
    unawaited(_applyMixChange());
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
      gain: _songLevel,
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

  /// [kind] names what the file is. Then and now writes
  /// `_mix_then_and_now_…`, which keeps the `_mix_` prefix _sweepOldMixes
  /// looks for, so a passage left behind by an earlier visit goes with the
  /// mixes.
  Future<String> _nextMixPath({String kind = 'mix'}) async {
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory('${root.path}/layers/${widget.projectId}');
    if (!await dir.exists()) await dir.create(recursive: true);
    if (!_sweptOldMixes) {
      _sweptOldMixes = true;
      await _sweepOldMixes(dir);
    }
    _mixSequence += 1;
    final stamp = DateTime.now().microsecondsSinceEpoch;
    return '${dir.path}/_${kind}_${stamp}_$_mixSequence.wav';
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

  /// The one thing a browser can play: a single file, by URL.
  ///
  /// The console below mixes every enabled take into one WAV on disk and
  /// plays that, which is how levels, the click and punching in all work at
  /// once. None of it exists in a browser -- there is no file to write and no
  /// decoder to write it with -- so on the web the transport plays the
  /// reference recording, or failing that the first take that is switched on,
  /// and the screen says plainly that the rest needs the app.
  ///
  /// Chosen over silently doing nothing, which is what a web build did until
  /// now: the mix path threw MissingPluginException out of path_provider and
  /// the button simply never worked.
  String? get _webSinglePath {
    final reference = _referencePath;
    if (reference != null) return reference;
    for (final layer in _layers ?? const <SharedLayer>[]) {
      if (_enabled.contains(layer.id) && _localPaths[layer.id] != null) {
        return _localPaths[layer.id];
      }
    }
    return null;
  }

  Future<bool> _rebuildMix() async {
    // Nothing to build, and nothing broken: the caller falls back to
    // [_webSinglePath].
    if (kIsWeb) return false;
    // The room's takes at the room's levels, heard the way this person
    // chose to: their part forward, or everyone but them. Applied here and
    // only here, so recording against the mix gets it too (the choir's
    // "everyone but me" is the backing track for an alto's take) and the
    // lanes, the desk and Save keep showing the shared mix as it is.
    var takes = MyPartMix.apply(_takes, _myPart);
    // A turn is recorded against the loop, not against the turns before it:
    // they are heard first, the way the person before you is heard in a
    // circle, and then it is yours. A lane somebody switched on by hand
    // would otherwise play under them and go down the microphone -- and so
    // would the go they have just had at this same turn, which is an
    // ordinary private take on exactly these bars (see quietUnder).
    final turn = _turnFor;
    if (turn != null) takes = TakeTurns.withoutTurns(takes, _quietUnder(turn));
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

  /// Rebuilds the mix and, if something is playing, carries on from where it
  /// was.
  ///
  /// Every change that alters the mix writes a *new file* — that is what
  /// stops audioplayers handing back a stale one. But the player is still on
  /// the old file, so muting a take mid-playback did nothing at all until you
  /// stopped and pressed play again. The change had happened; nobody could
  /// hear it.
  ///
  /// The position is carried across rather than restarting, because somebody
  /// muting a guitar forty seconds into a chorus is asking what the chorus
  /// sounds like without the guitar, not to hear the song from the top.
  Future<void> _applyMixChange() async {
    final wasPlaying = _playing;
    final at = _position;
    final rebuilt = await _rebuildMix();
    // A mute while then and now plays rebuilds the mix for later and leaves
    // the two halves playing. They are the mix with one take swapped, and
    // cutting them off for a fader would be answering a question nobody
    // asked.
    if (!rebuilt || !wasPlaying || _recording || _thenAndNow != null) return;
    await _playMix(from: at);
    if (mounted) setState(() => _playing = true);
  }

  /// The file then and now was last written to, deleted when the next one
  /// is written, the way _rebuildMix deletes the mix it replaces.
  String? _lastThenAndNowPath;

  /// Which downbeat the band counts as bar 1 (0161), read off the song the
  /// rooms are holding rather than kept here: it is a shared fact, and this
  /// screen is one of the readers of it, never the writer.
  int get _barOne =>
      BetaScope.maybeOf(context, listen: false)
          ?.projectById(widget.projectId)
          ?.barOne ??
      1;

  /// Plays the bars under the playhead from [pair]'s first take and then
  /// from its latest -- or, tapped while that plays, stops it.
  ///
  /// Every Musician, Same Song, 17 September 2026. The passage is decided
  /// here, from where the playhead is at the tap, and written as one file
  /// with the two halves in it (see ThenAndNow.write). Nothing about the
  /// mix changes: the ordinary mix stays current for Play and for recording
  /// against, and this file sits beside it.
  Future<void> _playThenAndNow(ThenAndNowPair pair) async {
    if (_recording || _busy) return;
    if (_thenAndNow?.pair == pair) {
      await _stopThenAndNow();
      return;
    }
    final passage = ThenAndNow.passage(
      pair,
      atMs: _position.inMilliseconds,
      downbeatsMs: _reference?.downbeatsMs ?? const <int>[],
      songEndMs: _reference?.durationMs,
      // The bars the band counts, so "Bars 9–12" here names the same passage
      // as "Bars 9–12" in Perform (0161).
      barOne: _barOne,
    );
    if (passage == null) return;
    // Busy while the file is written -- a second on a long song -- so a
    // second tap, Play or Record waits rather than racing it.
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final track = await ThenAndNow.write(
        takes: MyPartMix.apply(_takes, _myPart),
        pair: pair,
        passage: passage,
        outputPath: await _nextMixPath(kind: 'mix_then_and_now'),
      );
      final previous = _lastThenAndNowPath;
      _lastThenAndNowPath = track.path;
      if (previous != null && previous != track.path) {
        try {
          final stale = File(previous);
          if (await stale.exists()) await stale.delete();
        } catch (_) {
          // Clutter, not a failure worth interrupting playback for.
        }
      }
      if (!mounted) return;
      // Set before the file loads, so the length the player reports for it
      // is not taken for the song's, and the first position is read back
      // through the track.
      setState(() {
        _thenAndNow = track;
        _half = ThenOrNow.then;
        _position = Duration(milliseconds: passage.startMs);
        _noteLoop = null;
        _playing = true;
        _busy = false;
      });
      await _player.setReleaseMode(ReleaseMode.release);
      await _player.play(audioSourceFor(track.path));
      // The mix is not what is loaded now. Play afterwards starts it afresh
      // from the passage rather than resuming into the wrong file.
      _pausedAt = null;
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _thenAndNow = null;
        _playing = false;
        _busy = false;
        _error = reportAndDescribe(
          error,
          service: 'layers',
          stage: 'takes.then_and_now',
          route: 'Takes',
          projectId: widget.projectId,
        );
      });
    }
  }

  /// Stops then and now where it is. The playhead stays on the bars it was
  /// crossing, so Play hears them on their own from there.
  Future<void> _stopThenAndNow() async {
    if (_thenAndNow == null) return;
    // The player first, then the state: a position reported between the two
    // would otherwise be read as a place on the song when it is a place in
    // the file.
    try {
      await _player.stop();
    } catch (_) {
      // Already stopped, or never started. Either way it is over.
    }
    if (!mounted) return;
    setState(() {
      _thenAndNow = null;
      _playing = false;
    });
  }

  // -------------------------------------------------------------------
  // Take turns on the loop. Every Musician, Same Song, 17 September 2026.
  // -------------------------------------------------------------------

  /// The rounds on this song, or what was already known when they will not
  /// load. Best-effort, like the notes: a song whose rounds cannot be read
  /// still plays and still records.
  Future<List<LoopRound>> _readRounds() async {
    // The repository is found through the context, which is gone once the
    // screen is: a take that finishes saving after somebody has left still
    // reloads (see _stop), and must not throw on the way.
    if (!mounted) return _rounds;
    final repository = _repository;
    if (repository == null) return const <LoopRound>[];
    try {
      return await repository.loadLoopRounds(widget.projectId);
    } catch (error) {
      reportAndDescribe(
        error,
        service: 'layers',
        stage: 'takes.turns',
        projectId: widget.projectId,
      );
      return _rounds;
    }
  }

  /// What must not sound under a turn of [round]: the turns handed in, and
  /// this person's own earlier goes at their own.
  Set<String> _quietUnder(LoopRound round) => TakeTurns.quietUnder(
        round,
        _layers ?? const <SharedLayer>[],
        me: _me,
        alreadyTurns: TakeTurns.turnIds(_rounds),
      );

  /// The round the card shows: the one going, or else the last one that
  /// was, which can still be heard.
  LoopRound? get _round {
    for (final round in _rounds) {
      if (!round.ended) return round;
    }
    return _rounds.isEmpty ? null : _rounds.first;
  }

  /// Does [move] and reads the rounds again, whatever came of it: a refusal
  /// usually means the round moved on while this screen was open, and the
  /// card should say where it is now. The sentence is the server's.
  /// Answers whether it went through.
  Future<bool> _moveRound(
    Future<void> Function(MusicRepository repository) move, {
    required String stage,
  }) async {
    final repository = _repository;
    if (repository == null) return false;
    setState(() => _error = null);
    var moved = true;
    try {
      await move(repository);
    } catch (error) {
      moved = false;
      if (mounted) {
        setState(() => _error = reportAndDescribe(
              error,
              service: 'layers',
              stage: stage,
              route: 'Takes',
              projectId: widget.projectId,
            ));
      }
    }
    final rounds = await _readRounds();
    if (!mounted) return false;
    setState(() => _rounds = rounds);
    return moved;
  }

  /// Asks for the passage and the order, and starts the round.
  ///
  /// The passage is offered from where the playhead is, so parking on the
  /// eight bars everybody wants a go at and pressing Take turns offers those
  /// eight bars. The order is whoever in the room can record.
  Future<void> _startTurns() async {
    if (_busy || _recording) return;
    final room =
        BetaScope.maybeOf(context, listen: false)?.roomById(widget.roomId);
    if (room == null) return;
    final reference = _reference;
    final sections =
        reference?.structureSections ?? const <StructureSection>[];
    final downbeats = reference?.downbeatsMs ?? const <int>[];
    final chosen = await askForTurns(
      context,
      offered: TakeTurns.offeredPassage(
        atMs: _position.inMilliseconds,
        sections: sections,
        downbeatsMs: downbeats,
        songEndMs: reference?.durationMs,
      ),
      people: <RoomMember>[
        for (final member in room.members)
          if (room.canEditSongs(member.userId)) member,
      ],
      me: _me,
      sections: sections,
      downbeatsMs: downbeats,
      songEndMs: reference?.durationMs,
    );
    if (chosen == null || !mounted) return;
    await _moveRound(
      (repository) => repository.startLoopRound(
        projectId: widget.projectId,
        startMs: chosen.passage.startMs,
        endMs: chosen.passage.endMs,
        order: chosen.order,
      ),
      stage: 'takes.turns.start',
    );
  }

  /// Records a turn: from the first millisecond of the passage, against the
  /// loop alone, stopping on its own where the passage ends.
  ///
  /// What comes out is an ordinary take and a draft like any other (0057):
  /// only its player can hear it, and they can go again as often as they
  /// like before handing one in.
  Future<void> _recordMyTurn(LoopRound round) async {
    if (_busy || _recording) return;
    if (_playing) await _togglePlay();
    if (_thenAndNow != null) await _stopThenAndNow();
    if (!mounted) return;
    final from = Duration(milliseconds: round.startMs);
    setState(() {
      _turnFor = round;
      _noteLoop = null;
      _position = from;
    });
    await _record(at: from);
    // It never started: the microphone was refused, or would not open.
    if (!_recording) _turnFor = null;
  }

  /// Hands a draft in as this person's turn, which shares it with the room.
  ///
  /// Asked the way sharing any take is asked (see confirmSharing), because
  /// it is the same act with the same consequence: the room is told, and it
  /// plays for them from now on.
  Future<void> _handInMyTurn(LoopRound round, SharedLayer draft) async {
    if (_busy || _recording) return;
    final confirmed = await confirmSharing(context, teacher: _sendTo);
    if (!confirmed || !mounted) return;
    final handedIn = await _moveRound(
      (repository) =>
          repository.handInMyTurn(roundId: round.id, layerId: draft.id),
      stage: 'takes.turns.hand_in',
    );
    // Refused: the sentence is on screen, and reloading would wipe it.
    if (!handedIn || !mounted) return;
    // The take is the room's now, and a turn, so it leaves the ordinary mix
    // for the conversation (see _load).
    await _load();
    try {
      await _applyMixChange();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = reportAndDescribe(
            error,
            service: 'layers',
            stage: 'takes.turns.mix',
            route: 'Takes',
            projectId: widget.projectId,
          ));
    }
  }

  /// Writes the conversation for the round's card to play.
  Future<TurnsTrack> _writeConversation(LoopRound round) async {
    final reference = _reference;
    final playable = <String>{
      for (final layer in _layers ?? const <SharedLayer>[])
        if (_localPaths[layer.id] != null) layer.id,
    };
    return TakeTurns.write(
      takes: MyPartMix.apply(_takes, _myPart),
      round: round,
      passage: TakeTurns.passageOf(
        round,
        sections: reference?.structureSections ?? const <StructureSection>[],
        downbeatsMs: reference?.downbeatsMs ?? const <int>[],
      ),
      turns: TakeTurns.conversation(round, playable: playable),
      // This person's own unhanded-in goes at their turn sit on the same
      // bars as everybody else's turns, so without this they would sound
      // under the whole conversation -- on their phone alone, which is the
      // hardest kind of wrong to work out.
      drafts: <String>{
        for (final draft in TakeTurns.draftsFor(
          round,
          _layers ?? const <SharedLayer>[],
          me: _me,
          alreadyTurns: TakeTurns.turnIds(_rounds),
        ))
          draft.id,
      },
      outputPath: await _nextMixPath(kind: 'mix_turns'),
    );
  }

  /// Taking turns: the control that starts a round, or the round itself.
  ///
  /// One round at a time on a song, so this is one thing or the other. With
  /// a round going the card is here for everybody in the room; without one,
  /// the chip is offered to anybody who can record. Under the part chips,
  /// because it is the same kind of thing: a way of hearing and adding to
  /// the song that is chosen from here, with nothing said about it until
  /// somebody taps it.
  Widget _takeTurnsRow({required bool canRecord}) {
    final round = _round;
    final me = _me;
    final layers = _layers ?? const <SharedLayer>[];
    final canStart = canRecord &&
        _repository != null &&
        BetaScope.maybeOf(context)?.roomById(widget.roomId) != null;
    final start = Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ActionChip(
          key: const Key('take_turns_start'),
          avatar: const Icon(Icons.loop_rounded, size: 16, color: AppColors.cyan),
          label: const Text(TakeTurns.startLabel),
          backgroundColor: AppColors.raised,
          labelStyle: const TextStyle(color: AppColors.text, fontSize: 12.5),
          side: BorderSide(color: AppColors.cyan.withValues(alpha: 0.25)),
          visualDensity: VisualDensity.compact,
          onPressed:
              _busy || _recording ? null : () => unawaited(_startTurns()),
        ),
      ),
    );
    if (round == null) return canStart ? start : const SizedBox.shrink();

    final reference = _reference;
    final room = BetaScope.maybeOf(context)?.roomById(widget.roomId);
    final owner = me != null &&
        (room?.members.any((member) =>
                member.userId == me && member.role == RoomRole.owner) ??
            false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        TakeTurnsCard(
          // A new round is a new card, so a conversation that was playing
          // from the last one does not carry on under this one.
          key: ValueKey<String>('round_${round.id}'),
          round: round,
          passage: TakeTurns.passageOf(
            round,
            sections:
                reference?.structureSections ?? const <StructureSection>[],
            downbeatsMs: reference?.downbeatsMs ?? const <int>[],
          ),
          me: me,
          conversation: TakeTurns.conversation(
            round,
            playable: <String>{
              for (final layer in layers)
                if (_localPaths[layer.id] != null) layer.id,
            },
          ),
          draft: TakeTurns.draftFor(
            round,
            layers,
            me: me,
            alreadyTurns: TakeTurns.turnIds(_rounds),
          ),
          canSit: canRecord,
          canRecordHere: !kIsWeb,
          canHear: !kIsWeb,
          canEnd: me != null && (round.startedBy == me || owner),
          busy: _busy || _recording,
          onRecord: () => unawaited(_recordMyTurn(round)),
          onHandIn: (draft) => unawaited(_handInMyTurn(round, draft)),
          onSkip: () => unawaited(_moveRound(
            (repository) => repository.skipMyTurn(round.id),
            stage: 'takes.turns.skip',
          )),
          onJoin: () => unawaited(_moveRound(
            (repository) => repository.joinLoopRound(round.id),
            stage: 'takes.turns.join',
          )),
          onEnd: () => unawaited(_moveRound(
            (repository) => repository.endLoopRound(round.id),
            stage: 'takes.turns.end',
          )),
          writeConversation: () => _writeConversation(round),
          hush: _hushTurns,
          onWillHear: () async {
            // One thing sounding at a time: the song stops for the round.
            if (_thenAndNow != null) await _stopThenAndNow();
            if (_playing && !_recording) await _togglePlay();
          },
        ),
        // The last round is over: the next one starts from here.
        if (round.ended && canStart) start,
      ],
    );
  }

  /// Plays the current mix, looping it when it is only a click.
  Future<void> _playMix({Duration from = Duration.zero}) async {
    final path = _lastMixPath;
    if (path == null) return;
    await _player.setReleaseMode(
      _loopingClick ? ReleaseMode.loop : ReleaseMode.release,
    );
    await _player.play(audioSourceFor(path));
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

  /// How loud the song is under whatever is being played over it.
  ///
  /// Local to this person — see SongLevelStore. Until this existed there was
  /// no fader on the song at all, so a phone take under a mastered mix was
  /// buried with nothing on screen able to help.
  double _songLevel = 1.0;

  /// Your part forward, or everyone but you, on this phone only. Applied
  /// when the mix is written, never to the lanes: the faders stay the room's
  /// (Every Musician, Same Song, 17 September 2026).
  MyPart? _myPart;

  /// [at] is where the take lands, for a recording that has to start on
  /// an exact place -- a turn, on the first millisecond of its passage --
  /// rather than wherever the playhead was last reported to be.
  Future<void> _record({Duration? at}) async {
    if (_busy || _recording) return;
    _hushTurns.value += 1;
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
      //
      // A take lands on the song, not on a passage heard twice: stopped
      // here so the mix, not that file, is what plays under the recording.
      // The playhead stays where it was, which is somewhere on those bars.
      if (_thenAndNow != null) await _stopThenAndNow();
      _punchInAt = at ?? _position;
      final hasBacking = await _rebuildMix();
      // A punch-in into a song with a beat of its own is counted in: one bar
      // of the song's time, and the song back in on the downbeat (Every
      // Musician, Same Song, 17 September 2026). Decided here, after the mix
      // exists, because only a take with the song under it has anything to
      // be counted into -- and a click on its own is not the song: it counts
      // from zero at a tempo somebody chose, not from the analysis's bars.
      // Every other take starts exactly as it did.
      _counted = Duration.zero;
      final countIn = hasBacking && _lastMixPath != null && !_loopingClick
          ? takeCountInFor(
              _reference,
              punchInMs: _punchInAt.inMilliseconds,
              // The song's own metre, counted from its bar 1, so the bar
              // counted in here is the bar Perform counts (0161).
              barOne: _barOne,
            )
          : null;
      if (countIn != null) {
        // The take lands on the top of the bar the playhead was in, which is
        // where the count hands over: see TakeCountIn.downbeatMs.
        //
        // Except a turn, which lands on the first millisecond of its passage
        // and nowhere else. That is the one everybody in the round is
        // playing from, so it is where the count hands over; and a turn that
        // began a beat earlier is not on the bars the round is on -- 0159
        // refuses to take it, and the card would never find it to hand in.
        if (_turnFor == null) {
          _punchInAt = Duration(milliseconds: countIn.downbeatMs);
        }
        // Before the recorder starts, so none of the getting ready is on the
        // front of the take and the recorder's head start stays as quiet as
        // it has always been.
        await _readyTheCount(countIn);
      }
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
        if (countIn == null) {
          await _playMix(from: _punchInAt);
        } else if (!await _countInAndComeIn(countIn)) {
          // The screen went away during the bar, and took the recorder with
          // it. Nobody is left to bring a song in for.
          return;
        }
      }

      _elapsed = Duration.zero;
      _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (mounted) setState(() => _elapsed += const Duration(milliseconds: 200));
        // A turn ends where its passage does, on its own. The next player
        // comes in on the one, and nobody has to reach for the phone in
        // the last bar of their solo.
        final turn = _turnFor;
        if (turn != null && _elapsed.inMilliseconds >= turn.lengthMs) {
          unawaited(_stop());
        }
      });
      if (mounted) {
        setState(() {
          _recording = true;
          _playing = hasBacking;
          _busy = false;
          _countingIn = null;
        });
      }
    } catch (error) {
      // Silenced on the way out, and never allowed to throw on its own.
      // Backing out during the bar disposes this player and the recorder
      // together, so the throw that brings us here is often a call on a
      // recorder that is already gone -- and stopping a disposed player
      // would then raise a second error with nobody left to catch it.
      unawaited(_countClick?.stop().catchError((Object _) {}));
      if (mounted) {
        setState(() {
          _error = reportAndDescribe(error, service: 'layers', route: 'Takes');
          _busy = false;
          _countingIn = null;
        });
      }
    }
  }

  /// The bar being counted before a take, and the beat it is on. Null the
  /// rest of the time, which is what takes the scrim down.
  TakeCountIn? _countingIn;
  int _countInBeat = 0;

  /// How long the count before the last take really took. All of it is on
  /// the front of that take's recording, so [_alignedOffsetFor] takes it off
  /// again. Zero for a take that was not counted in.
  Duration _counted = Duration.zero;

  /// The count's own player, made the first time somebody is counted in.
  ///
  /// Never the player the song is on. That one is sitting on the downbeat
  /// with the mix loaded while the bar is counted, and a click played through
  /// it would be the song's source replaced by four ticks.
  ClickPlayer? _countClick;

  /// Gets the song and the click ready for [countIn], and puts the bar on
  /// screen.
  ///
  /// The song is loaded and left silent on the downbeat now, so that coming
  /// in is a resume and nothing else. play() is source, seek, resume in that
  /// order; this is the same three calls with the last one held back for a
  /// bar, which is how Perform has come in since #363. Asking for all three
  /// on the downbeat instead would bring the song in late by however long a
  /// four-minute wav takes to open, after a count that had just promised
  /// where it would be.
  Future<void> _readyTheCount(TakeCountIn countIn) async {
    try {
      // Record can be pressed while the song is playing. A source set on a
      // player that is playing starts as soon as it has loaded.
      await _player.stop();
    } catch (_) {
      // Nothing was loaded. That is what was wanted.
    }
    final path = _lastMixPath;
    if (path != null) {
      await _player.setReleaseMode(ReleaseMode.release);
      await _player.setSource(audioSourceFor(path));
      if (_punchInAt > Duration.zero) await _player.seek(_punchInAt);
    }
    if (_countClick == null) {
      // The same session the song's player is given in initState, for the
      // same reason: this one sounds while the recorder is running.
      final player = AudioPlayer();
      await OverdubSession.applyTo(player);
      _countClick = WavClickPlayer(player: player);
    }
    if (!mounted) return;
    setState(() {
      // The playhead and the button's label move to where the take will
      // land, so the bar on screen is the bar being counted into.
      _position = _punchInAt;
      _playing = false;
      _countingIn = countIn;
      _countInBeat = 0;
    });
  }

  /// Counts the bar and brings the song in on the downbeat. False when the
  /// screen went away first.
  Future<bool> _countInAndComeIn(TakeCountIn countIn) async {
    final counted = await countInATake(
      bar: countIn.bar,
      // Made by _readyTheCount, which has always run by now: a count that
      // could not be made ready threw before the recorder started.
      click: _countClick!,
      stillWanted: () => mounted,
      onBeat: (beat) {
        setState(() => _countInBeat = beat);
        // Felt as well as seen and heard, the way Perform's is: the eyes are
        // on the instrument in the bar before a take. Never allowed to fail
        // a count, and nothing on a phone with no motor.
        unawaited(HapticFeedback.selectionClick().catchError((Object _) {}));
      },
    );
    if (counted == null) return false;
    // Straight in, before anything is redrawn. What was measured ends here,
    // and a rebuild between the measurement and the song would be time on
    // the front of the take that nothing accounts for.
    await _player.resume();
    _counted = counted;
    return true;
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
      // A turn is recorded against the loop alone (see _rebuildMix). Let go
      // of it before anything is mixed again, so what plays next is the song
      // as this person hears it.
      _turnFor = null;
      await _load();
      // The mix on disk is the one this take was recorded against, so it
      // does not have the take in it, and Play only builds a mix when there
      // is none. Without this the first thing somebody hears after recording
      // is the song without what they just played -- and for a turn, "Go
      // again" or "Hand it in" is a choice made by listening.
      //
      // Busy again while it is written, because _load has just said
      // otherwise and Play is only held back by that: a press in the second
      // this takes would start the old file as it is being replaced.
      //
      // Caught on its own. The take is on the server by now, and everything
      // below this line used to be unable to throw, so anything from here
      // reaching the handler underneath would say "Saving a take failed" and
      // report an upload that worked -- which is how somebody records the
      // same thing twice and how triage grows a row that is not true.
      if (mounted) setState(() => _busy = true);
      try {
        await _rebuildMix();
      } catch (error) {
        if (mounted) {
          setState(() => _error = reportAndDescribe(
                error,
                service: 'layers',
                stage: 'takes.mix_after_take',
                route: 'Takes',
                projectId: widget.projectId,
              ));
        }
      }

      // Rewind to just before the punch, the way a desk does.
      //
      // Without this, punching in at 1:40 and pressing play starts the song
      // at 0:00 — and the take does not come in for another minute and
      // forty seconds, so the honest conclusion is that nothing recorded.
      // The take was there the whole time; playback simply had not reached
      // it yet.
      //
      // A couple of seconds of run-up rather than landing exactly on it: the
      // point of hearing a punch is hearing it arrive against what came
      // before, and a take that begins on the first sample of playback tells
      // you nothing about whether it sits right.
      if (_punchInAt > Duration.zero) {
        final preRoll = _punchInAt - const Duration(seconds: 2);
        await _scrubTo(
          _songSpan.inMilliseconds <= 0
              ? 0
              : (preRoll.isNegative ? 0 : preRoll.inMilliseconds) /
                  _songSpan.inMilliseconds,
        );
      }
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
      if (mounted) setState(() => _error = reportAndDescribe(error, service: 'layers', route: 'Takes'));
    } finally {
      // Whatever happened, the turn is no longer being recorded.
      _turnFor = null;
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
    // The head start is known, not measured by listening. A take that played
    // along began recording before the music did -- by the recorder's head
    // start, and by the bar that was counted if one was -- so that much of
    // its front is the room before the song, and it comes off before anything
    // is measured. trimForTake says why that matters, and is where the
    // arithmetic went so that a test can reach it.
    final headStart = takeHeadStartMs(
      backingWasPlaying: _backingWasPlaying,
      recorderMs: _recorderHeadStartMs,
      counted: _counted,
    );
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

    final trim = trimForTake(
      samples,
      headStartMs: headStart,
      manualMs: (_layers ?? const <SharedLayer>[]).isEmpty ? 0 : _offsetMs,
      beatsMs: beats,
      punchedInAtMs: _punchInAt.inMilliseconds,
    );
    if (!trim.measured) return trim.ms;

    final total = trim.ms;
    // A counted take says so, because the bar is most of the number.
    //
    // The trim of a take that played along used to be a few hundred
    // milliseconds -- a phone's latency, which is what "trimmed" plainly
    // means. A counted one is that plus the whole bar, so the same sentence
    // would tell a musician their phone was two and a half seconds late.
    // The number still matches the one the timing buttons work on, which is
    // the point of naming the count rather than quietly subtracting it.
    final countedIn = _backingWasPlaying && _counted > Duration.zero;
    _alignedNote = total > 0
        ? countedIn
            ? 'Counted you in and timed to the beat — $total ms trimmed, '
                'the count included.'
            : 'Timed to the beat automatically — $total ms trimmed.'
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
    if (!_playing) _hushTurns.value += 1;
    // Then and now stops rather than pauses. It is a passage, and the way
    // back in is the chip, or Play, which lands on the same bars.
    if (_thenAndNow != null) {
      await _stopThenAndNow();
      return;
    }
    if (_playing) {
      // Paused, not stopped. stop() winds the position back to zero, which is
      // why pressing play again always started the song over — a small thing
      // on a thirty-second sketch and unusable on a three-minute song when
      // the part you want to hear is at 2:40.
      await _player.pause();
      _pausedAt = kIsWeb ? _webSinglePath : _lastMixPath;
      // A note's loop lasts as long as somebody is listening to it. Pressing
      // stop and starting again plays the song on from there.
      if (mounted) setState(() {
        _playing = false;
        _noteLoop = null;
      });
      return;
    }

    // Only built when there is nothing to play yet. Every change that alters
    // the mix — a mute, a fader, the metronome — rebuilds it as it happens,
    // so by the time somebody presses play it is already current. Rebuilding
    // here as well wrote a second identical file under a new name, and a new
    // name is a new source, which starts at zero.
    if (kIsWeb) {
      final single = _webSinglePath;
      if (single == null) return;
      if (_pausedAt == single) {
        await _player.resume();
      } else {
        await _player.play(audioSourceFor(single));
      }
      _pausedAt = null;
      if (mounted) setState(() => _playing = true);
      return;
    }

    if (_lastMixPath == null) {
      if (!await _rebuildMix() || _lastMixPath == null) return;
    }

    if (_pausedAt == _lastMixPath) {
      await _player.resume();
    } else {
      // From the playhead, not the top. After then and now the playhead is
      // on the bars just heard, and a scrub before the first play is a
      // place somebody chose; the mix that starts here starts there.
      await _playMix(from: _position);
    }
    _pausedAt = null;
    if (mounted) setState(() => _playing = true);
  }

  Future<void> _setGain(SharedLayer layer, double gain) async {
    await _update(layer, <String, dynamic>{'gain': gain});
  }

  Future<void> _nudge(SharedLayer layer, int delta) async {
    // No ceiling of a second any more: see nudgedTrimMs. A take that was
    // counted in has the bar in its trim.
    final next = nudgedTrimMs(layer.offsetMs, delta);
    await _update(layer, <String, dynamic>{'offset_ms': next});
  }

  /// Writes one field and refreshes, so what everyone hears stays what the
  /// person who played it chose.
  Future<void> _update(SharedLayer layer, Map<String, dynamic> patch) async {
    try {
      await _service.updateLayer(layer, patch);
      await _load();
      // _load re-reads the layers; it does not re-sum them. Without this a
      // fader moved mid-playback changed the number on screen and nothing in
      // the audio, which is the same complaint as muting.
      await _applyMixChange();
    } catch (error) {
      if (mounted) setState(() => _error = reportAndDescribe(error, service: 'layers', route: 'Takes'));
    }
  }

  Future<void> _delete(SharedLayer layer) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete ${TakeNaming.describe(layer.toTake('', enabled: true))}?'),
        content: const Text(
          'This removes it for everyone, and the audio goes with it. '
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

  /// Bring a take back in from somewhere else.
  ///
  /// The other half of "Save a copy", and the half that makes the export
  /// worth anything. Two people who find each other here will not do all the
  /// work here — the good version of this is somebody taking the mix into a
  /// DAW, cutting a proper vocal against it with a real microphone and a real
  /// room, and bringing it back. Without this, that bounce has nowhere to go
  /// and the collaboration stops at the point it got serious.
  ///
  /// It is deliberately the same shape as a recorded take once it lands: same
  /// naming sheet, same silence check, same upload. The only difference is
  /// where the audio came from, and nothing downstream needs to care.
  Future<void> _importTake() async {
    if (_busy || _recording) return;
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const <String>[
        'wav', 'mp3', 'm4a', 'aac', 'flac', 'aiff', 'aif', 'ogg', 'opus',
      ],
    );
    final path = picked?.path;
    if (path == null || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
      _status = 'Reading the file';
    });
    try {
      // The same two questions asked of a recording, for the same reasons: a
      // container that will not decode is not a take, and a file of digital
      // silence is the failure this feature spent three rounds of testing
      // learning to catch. An import can be silent just as easily — a bounce
      // of a muted track looks exactly like a good one until somebody plays
      // it back.
      final samples = await Multitrack.readRecording(path);
      if (samples == null || samples.isEmpty) {
        throw StateError(
          'That file could not be read as audio. A wav or mp3 bounced from '
          'your DAW is the safest thing to bring in.',
        );
      }
      if (Multitrack.peakOf(samples) < Multitrack.silenceFloor) {
        throw StateError(
          'That file is silent all the way through, so it was not added. '
          'Check the right track was soloed when it was bounced.',
        );
      }

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
        durationMs:
            (samples.length / Multitrack.rate * 1000).round(),
        // Both zero, and that is a decision rather than a default. A recorded
        // take is corrected for the phone's own latency and may be punched in
        // partway through the song; a file bounced somewhere else is already
        // exactly where its author put it, and the export's own note tells
        // them to line everything up at zero. Applying a trim to it here
        // would move audio somebody has already placed.
        offsetMs: 0,
        startMs: 0,
        part: part,
        performer: described?.performer,
      );

      if (mounted) setState(() => _status = 'Sharing it with the room');
      await _service.upload(
        roomId: widget.roomId,
        projectId: widget.projectId,
        take: take,
      );
      // Not deleted afterwards, unlike a recording. That file is the
      // musician's own, sitting in their own storage, and it is not this
      // app's to remove.
      await _load();
    } catch (error) {
      unawaited(ErrorReporter().reportError(
        service: 'layers',
        stage: 'import',
        message: 'Importing a take failed: $error',
        projectId: widget.projectId,
      ));
      if (mounted) setState(() => _error = describeForUser(error));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = null;
        });
      }
    }
  }

  Future<void> _export() async {
    final takes = _takes;
    if (takes.isEmpty || _busy) return;
    // A platform limit, not a fault, and so not routed through _error.
    //
    // Both shapes of export decode audio and write a file, and a browser has
    // neither: getApplicationDocumentsDirectory is a MissingPluginException
    // there, which arrived as "something went wrong" and was reported as a
    // fault. Putting a sentence in _error instead would draw it in the red
    // box under "Tell us what you were doing", which attaches whatever last
    // genuinely broke this session — problem_report.dart already names that
    // as a defect. So this sits with the other things a browser cannot do:
    // the Save button is off here and the note at the top of the screen says
    // why. This is the floor under that.
    if (kIsWeb) return;
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
                'The song and every take you can hear, together as one audio '
                'file.',
              ),
              onTap: () => Navigator.pop(sheetContext, 'mix'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_zip_outlined, color: AppColors.cyan),
              title: const Text('Every take, separately'),
              subtitle: const Text(
                'One file each, lined up and at tempo, for opening in a DAW. '
                'Yours to keep.',
              ),
              onTap: () => Navigator.pop(sheetContext, 'layers'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;

    setState(() => _busy = true);
    // The key the band says the song is in, in front of the one the analysis
    // heard, the same as the song sheet reads it (0144). Read before anything
    // is awaited, while the rooms and this context are certainly still here.
    final musicalKey = BetaScope.maybeOf(context, listen: false)
            ?.projectById(widget.projectId)
            ?.songKey(_reference?.musicalKey) ??
        _reference?.musicalKey;
    // Read here for the same reason, and before the first await.
    final barOne = _barOne;
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
              // The analysis's own tempo, not the click's. _tempo is whatever
              // somebody dialled in to play against; what a DAW needs is what
              // the recording actually runs at.
              bpm: _reference?.bpm,
              musicalKey: musicalKey,
              sections: _reference?.structureSections ??
                  const <StructureSection>[],
              downbeatsMs: _reference?.downbeatsMs ?? const <int>[],
              beatsPerBar: _reference?.beatsPerBar,
              // So the count-in on the front of the recording arrives in the
              // DAW as a pickup bar and the band's bar 1 is bar 1 (0161).
              barOne: barOne,
            );
      if (file == null) return;
      await SharePlus.instance.share(
        ShareParams(files: <XFile>[XFile(file.path)], subject: widget.songTitle),
      );
    } catch (error) {
      if (mounted) setState(() => _error = reportAndDescribe(error, service: 'layers', route: 'Takes'));
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
    // Whether this person may put a take here at all. Every Musician, Same
    // Song, 17 September 2026: a viewer listens and talks and does nothing
    // else -- in SQL since 0148, where song_layers refuses the role -- so
    // the button that would be refused is not offered, and a sentence says
    // why. Unknown means offered: a shelf that has not loaded this room yet
    // is no reason to hide anything, and the server decides either way.
    final me = _me;
    final room = BetaScope.maybeOf(context)?.roomById(widget.roomId);
    final canRecord = room == null || me == null || me.isEmpty || room.canEditSongs(me);
    // Sideways is a desk. A list is the right shape for reading and the wrong
    // shape for balancing: deciding whether the harmony sits well against the
    // lead means comparing them, and on a phone that means remembering one
    // while scrolling to the other. Side by side, the comparison is just the
    // picture. It also gives the landscape orientation something to be.
    final console = MediaQuery.of(context).orientation == Orientation.landscape;
    return PinAtPlayheadKey(
      onPin: () => unawaited(_pinNote()),
      child: Scaffold(
      backgroundColor: AppColors.deepNavy,
      appBar: AppBar(
        backgroundColor: AppColors.deepNavy,
        automaticallyImplyLeading: !widget.embedded,
        leading: widget.embedded
            ? IconButton(
                onPressed: widget.onClose,
                tooltip: 'Back to the words',
                icon: const Icon(Icons.arrow_back_rounded),
              )
            : null,
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
          // Labelled, and not gated on there being shared takes.
          //
          // This was a bare share glyph whose only explanation was a tooltip,
          // and a tooltip on a phone requires knowing to long-press something
          // you have not noticed. The band recorded a take, listened to it
          // together, and concluded the app had no way to get the audio out —
          // while this button sat in the corner of the screen they were
          // looking at. A feature nobody can find is not a feature.
          //
          // `hasLayers` counted only *shared* takes, so a song with none at
          // all could not be saved either. The song's own recording is in
          // `_takes`, and wanting a copy of your own song is not a stranger
          // request than wanting a copy of the mix. `_export` already refuses
          // when there is genuinely nothing.
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: TextButton.icon(
              // Off in a browser, where the files are put together on the
              // device and there is nowhere to put them. The note below says
              // so, in the same place it says what else needs the app.
              onPressed: !hasSomethingToHear || _busy || kIsWeb
                  ? null
                  : () => unawaited(_export()),
              icon: const Icon(Icons.ios_share_rounded, size: 18),
              label: const Text(
                'Save',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.cyan,
                disabledForegroundColor: AppColors.line,
              ),
            ),
          ),
        ],
      ),
      // A stack only so the bar being counted can sit over the takes. Loose,
      // which is what a Scaffold hands its body anyway, so everything under
      // the count is laid out exactly as it was without one.
      body: Stack(
        children: <Widget>[
          SafeArea(
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
                // Sideways is the faders, and the notes underneath them.
                //
                // A teacher turns the phone to reach the faders while they listen
                // to a student, and the notes have to come with them: pinning
                // works sideways (the button is in the bottom bar, which does not
                // rotate away) and until now nothing else did — no list, no way
                // to hear a moment again, no way to take words back. There are no
                // marks here because a fader strip has no time on it; the marks
                // are on the lanes, which are the portrait view.
                ? LayoutBuilder(
                    builder: (context, room) => Column(
                      children: <Widget>[
                        Expanded(
                          child: LayerConsole(
                            takes: _takes,
                            silentIds: _silent,
                            onToggle: (take) => _toggle(take.id),
                            onGain: (take) {
                              final layer = _layerFor(take);
                              if (!_mine(take) || layer == null) return null;
                              return (Take _, double value) =>
                                  unawaited(_setGain(layer, value));
                            },
                          ),
                        ),
                        // What went wrong has to be visible in the orientation
                        // the buttons are offered in. The pin and say buttons
                        // are in the bottom bar, which does not rotate away,
                        // and until now this branch drew nothing when a note
                        // failed to save: sideways, a teacher who held the
                        // button and let go believed the note was left. That
                        // is the silent failure 0152 exists to end.
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: _problemStrip(),
                          ),
                        if (_notes.isNotEmpty)
                          ConstrainedBox(
                            // A third of a landscape phone at most, so the desk
                            // keeps the height it was rebuilt to fit in.
                            constraints: BoxConstraints(
                              maxHeight: math.min(132, room.maxHeight * 0.34),
                            ),
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                              child: MomentNoteList(
                                notes: _notes,
                                focusedId: _noteLoop?.id,
                                currentUserId: _me ?? '',
                                labelFor: _takes.length > 1 ? _noteOnLabel : null,
                                listeningTo: _hearing,
                                onOpen: (note) => unawaited(_openNote(note)),
                                onListen: (note) => unawaited(_listen(note)),
                                onDelete: (note) => unawaited(_deleteNote(note)),
                                onCopyLink: (note) => unawaited(_copyLinkTo(
                                      takeId: note.layerId,
                                      atMs: note.atMs,
                                    )),
                              ),
                            ),
                          ),
                      ],
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 110),
                      children: <Widget>[
                        if (!hasSomethingToHear) _EmptyState(),
                        // A round started on a song with nothing on it yet. The
                        // card has to be here or the first person up could never
                        // take their turn; the chip that starts one waits for
                        // there to be something to go round.
                        if (!hasSomethingToHear && _round != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: _takeTurnsRow(canRecord: canRecord),
                          ),
                        // What a browser cannot do, said before somebody presses
                        // a fader and wonders why nothing moved.
                        //
                        // Mixing every take into one track, the click, punching in
                        // and saving a copy all work by writing a WAV to disk and
                        // playing or packing that. There is no disk here. Playing
                        // one thing at a time does work, and that is worth having
                        // -- it is how you hear what somebody sent you without
                        // reaching for a phone.
                        if (kIsWeb) ...<Widget>[
                          Container(
                            key: const Key('takes_web_note'),
                            margin: const EdgeInsets.only(bottom: 14),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppColors.cyan.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Text(
                              'In a browser you can play the song and hear each '
                              'take on its own. Mixing them together, the click, '
                              'recording a new take and saving a copy need the '
                              'app.',
                              style: TextStyle(
                                  color: AppColors.cyan, fontSize: 12, height: 1.45),
                            ),
                          ),
                        ],
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
                        if (_error != null) _problemStrip(),
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
                          // Your part forward, or everyone but you. Only on a
                          // song with two takes or more, and not in a browser,
                          // where there is no mix to apply it to.
                          if (!kIsWeb) _myPartRow(),
                          // Then and now, on a song where somebody has recorded
                          // a part more than once. Not in a browser, for the
                          // same reason: there is no mix to build it from.
                          if (!kIsWeb) _thenAndNowRow(),
                          // Taking turns on a passage. In a browser too: the
                          // order, Skip me and I'm in are rows, and only hearing
                          // it back and recording need the app.
                          _takeTurnsRow(canRecord: canRecord),
                          const SizedBox(height: 14),
                          _timeline(),
                          if (_notes.isNotEmpty) ...<Widget>[
                            const SizedBox(height: 16),
                            MomentNoteList(
                              notes: _notes,
                              focusedId: _noteLoop?.id,
                              currentUserId: _me ?? '',
                              labelFor: _takes.length > 1 ? _noteOnLabel : null,
                              listeningTo: _hearing,
                              onOpen: (note) => unawaited(_openNote(note)),
                              onListen: (note) => unawaited(_listen(note)),
                              onDelete: (note) => unawaited(_deleteNote(note)),
                              onCopyLink: (note) => unawaited(_copyLinkTo(
                                    takeId: note.layerId,
                                    atMs: note.atMs,
                                  )),
                            ),
                          ],
                          const SizedBox(height: 16),
                          _MetronomeNote(
                            on: _clickOn,
                            bpm: _tempo,
                            fromAnalysis: _reference?.bpm != null && _clickBpm == null,
                            onToggle: (value) {
                              setState(() => _clickOn = value);
                              unawaited(_applyMixChange());
                            },
                            onTempo: (value) {
                              setState(() => _clickBpm = value);
                              unawaited(_applyMixChange());
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
          // On [_countingIn], not on the beat: the bar goes up the moment the
          // button is pressed, and the first beat waits on the recorder's
          // head start and the click. A screen that looked untouched for that
          // half second would be pressed again.
          if (_countingIn != null)
            Positioned.fill(
              child: TakeCountInScrim(
                key: const Key('take_count_in'),
                beats: _countingIn!.bar.beats,
                beat: _countInBeat,
              ),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
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
                  if (!canRecord)
                    const Expanded(
                      flex: 2,
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 14),
                        child: Text(
                          'You can listen in this room, not record.',
                          key: Key('layers_listen_only'),
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.muted, fontSize: 13, height: 1.35),
                        ),
                      ),
                    )
                  else
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
              // Says where it will land, the way the record button does.
              //
              // Every Musician, Same Song, 17 September 2026: the note is
              // pinned at the playhead, so the moment is decided before
              // anybody types and the label is the moment. A button rather
              // than a long-press on the lane: the plan's own audit found
              // that this app hides things brilliantly and announces
              // nothing, and a gesture nobody is told about is a feature
              // nobody has.
              if (_noteTargets.isNotEmpty)
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextButton.icon(
                        key: const Key('pin_moment_note'),
                        onPressed: _busy || _recording || _saying || _savingSaid
                            ? null
                            : () => unawaited(_pinNote()),
                        icon: const Icon(Icons.push_pin_outlined, size: 17),
                        label: Text(
                          'Note at ${_clock(_position)}',
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.gold,
                          disabledForegroundColor: AppColors.line,
                          minimumSize: const Size.fromHeight(36),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Or say it (0152). Beside the pin, because it is the
                    // same note said a different way: a teacher with a
                    // guitar in their hands holds this instead of typing.
                    SayItButton(
                      key: const Key('say_moment_note'),
                      saying: _saying,
                      elapsed: _said,
                      enabled: !_busy && !_recording && !_savingSaid,
                      onDown: () => unawaited(_startSaying()),
                      onUp: _letGo,
                    ),
                    // Or send somebody here. Beside the two ways of leaving
                    // words at this moment because it is the third thing to
                    // do with a moment: say it to the room now rather than
                    // leave it on the recording for later. Every Musician,
                    // Same Song, 17 September 2026 -- schools item 1.
                    IconButton(
                      key: const Key('copy_link_to_playhead'),
                      onPressed: _recording
                          ? null
                          : () => unawaited(_copyLinkTo(
                                takeId: _takeAtThePlayhead,
                                atMs: _position.inMilliseconds,
                              )),
                      tooltip: 'Copy link to here',
                      visualDensity: VisualDensity.compact,
                      color: AppColors.gold,
                      disabledColor: AppColors.line,
                      icon: const Icon(Icons.link_rounded, size: 18),
                    ),
                  ],
                ),
              // A minute of wav is about five megabytes, and on a slow
              // connection that is several seconds of greyed buttons. Said
              // here, under the button that was held, rather than nowhere.
              if (_savingSaid && _status != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    _status!,
                    key: const Key('saying_status'),
                    style: const TextStyle(color: AppColors.muted, fontSize: 12),
                  ),
                ),
              // The way back in, said in the words somebody would use for it.
              //
              // A phone in a room is the right tool for catching an idea and
              // the wrong one for a finished vocal. The moment two people
              // decide they are actually making something, one of them opens
              // a DAW — and until now that was where the song left CoLabRoom
              // for good, because a bounce had nowhere to return to.
              if (canRecord)
              TextButton.icon(
                onPressed: _busy || _recording
                    ? null
                    : () => unawaited(_importTake()),
                icon: const Icon(Icons.file_upload_outlined, size: 17),
                label: const Text(
                  'Recorded it elsewhere? Add a file',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.muted,
                  disabledForegroundColor: AppColors.line,
                  minimumSize: const Size.fromHeight(36),
                ),
              ),
            ],
          ),
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
      noteMarks: _noteMarksFor(take),
      focusedMark: _focusedMarkFor(take),
      silent: _silent.contains(take.id),
      onToggle: () => _toggle(take.id),
      // No delete on the reference: it is what every chord and lyric on the
      // song sheet came from, and a mixer should not be able to break those.
      onDelete: layer == null ? null : () => unawaited(_delete(layer)),
      // Only on your own take, and only while the room has not heard it.
      onShare: layer != null && mine && !layer.isShared
          ? () => unawaited(_share(layer))
          : null,
      shareLabel: shareLabelFor(_sendTo),
      onAdjust: layer != null
          ? (mine ? () => unawaited(_showLevels(layer, take)) : null)
          // The song itself. Not a take and not anybody's to re-balance for
          // the band — but everybody needs to set how loud it sits while they
          // play along, and until now nobody could.
          : (take.id == _referenceId ? () => unawaited(_showSongLevel()) : null),
    );
  }

  /// Which recording a note is on, in the words the lane uses for it.
  String _noteOnLabel(MomentNote note) {
    final id = _noteTakeId(note);
    for (final take in _takes) {
      if (take.id == id) {
        return take.id == _referenceId ? 'The song' : TakeNaming.describe(take);
      }
    }
    return 'a take';
  }

  /// Which take a note belongs to, as this screen names takes.
  ///
  /// The song's own recording is [_referenceId] here and a null `layer_id` in
  /// the database, because it is not a row in song_layers.
  String _noteTakeId(MomentNote note) => note.layerId ?? _referenceId;

  /// Where the notes on one take sit, 0..1 through the song.
  List<double> _noteMarksFor(Take take) {
    final span = _songSpan.inMilliseconds;
    if (span <= 0) return const <double>[];
    return <double>[
      for (final note in _notes)
        if (_noteTakeId(note) == take.id)
          (note.atMs / span).clamp(0.0, 1.0),
    ];
  }

  double? _focusedMarkFor(Take take) {
    final loop = _noteLoop;
    final span = _songSpan.inMilliseconds;
    if (loop == null || span <= 0 || _noteTakeId(loop) != take.id) return null;
    return (loop.atMs / span).clamp(0.0, 1.0);
  }

  /// Which recording a link at the playhead names.
  ///
  /// The newest one the playhead is actually inside, because that is what
  /// somebody listening is listening to: a harmony punched in over the last
  /// chorus is the thing being talked about while it plays. Null -- the
  /// song's own recording -- everywhere no take reaches, which is the honest
  /// answer for a moment that is about the song rather than about a take.
  ///
  /// Never a take the room cannot hear. A take of your own that nobody has
  /// been sent is audible to you alone (0057), so a link naming one would
  /// open for the person you sent it to on a lane that is not there.
  String? get _takeAtThePlayhead {
    final at = _position.inMilliseconds;
    String? named;
    for (final take in _takes) {
      final layer = _layerFor(take);
      if (layer != null && !layer.isShared) continue;
      if (at < take.startMs || at > take.startMs + take.durationMs) continue;
      named = layer?.id;
    }
    return named;
  }

  /// The recordings somebody may pin a note on.
  ///
  /// Not every lane: a take nobody has shared is heard by whoever recorded it
  /// and by nobody else (0057), so there is nothing to say to them about it
  /// and the database would refuse the row anyway. Offering the action and
  /// then failing would be the worse of the two.
  List<NoteTarget> get _noteTargets {
    final out = <NoteTarget>[];
    for (final take in _takes) {
      final layer = _layerFor(take);
      if (layer == null) {
        // The song's own recording, which everybody in the room can hear.
        out.add(NoteTarget(id: null, label: 'The song'));
        continue;
      }
      if (!layer.isShared && !_mine(take)) continue;
      out.add(NoteTarget(
        id: layer.id,
        label: TakeNaming.describe(take),
        // A take of your own that nobody has been sent. You may write on it;
        // what you write stays yours, this time and after you share it
        // (0141's on_shared_take), and the sheet says so.
        yoursAlone: !layer.isShared,
      ));
    }
    return out;
  }

  /// Pins words at the playhead.
  ///
  /// The moment is decided before the sheet opens, which is the whole
  /// difference between this and a comment: somebody hears the thing, says
  /// "there", and then types.
  Future<void> _pinNote() async {
    final repository = _repository;
    final targets = _noteTargets;
    if (repository == null || targets.isEmpty || _recording) return;
    final at = _position.inMilliseconds;
    final draft = await showMomentNoteSheet(
      context,
      atMs: at,
      on: targets,
      // The newest recording, which in a lesson room is the take that just
      // arrived and on any song is the one somebody is listening to.
      initialLayerId: targets.last.id,
    );
    if (draft == null || !mounted) return;
    try {
      await repository.addMomentNote(
        projectId: widget.projectId,
        layerId: draft.layerId,
        atMs: at,
        body: draft.body,
      );
      await _loadNotes();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = reportAndDescribe(
            error,
            service: 'layers',
            stage: 'takes.pin',
            route: 'Takes',
            projectId: widget.projectId,
          ));
    }
  }

  /// Opens the microphone under a finger that has just gone down (0152).
  ///
  /// The moment is where the playhead was at that instant, decided before
  /// anybody speaks. If the mix is playing it pauses, so the microphone
  /// hears the person and not the phone, and so the playhead stays on the
  /// bar being talked about.
  Future<void> _startSaying() async {
    if (_busy || _recording || _saying || _savingSaid || _noteTargets.isEmpty) {
      return;
    }
    _holding = true;
    final at = _position.inMilliseconds;
    final allowed = await MicrophoneAccess.ensureGranted(
      context,
      purpose: 'to say a note at this moment',
      request: _mic.hasPermission,
    );
    if (!allowed || !mounted || _saying) return;
    // The disclosure and the permission prompt both take a while, and a
    // finger that has lifted by the time they come back is not holding
    // anything. Opening the microphone anyway would leave it open with
    // nothing to close it but the one-minute cap. A tap lands here too,
    // and is told what the button wanted.
    if (!_holding) {
      setState(() => _error = _holdToSpeak);
      return;
    }
    try {
      if (_playing) await _togglePlay();
      await _mic.start();
    } catch (error) {
      if (!mounted) return;
      reportAndDescribe(
        error,
        service: 'layers',
        stage: 'takes.say',
        route: 'Takes',
        projectId: widget.projectId,
      );
      setState(() => _error = 'The microphone did not open. Hold and try again.');
      return;
    }
    if (!mounted || !_holding) {
      // Lifted while it was opening: nothing was said into it.
      unawaited(_mic.cancel());
      return;
    }
    setState(() {
      _saying = true;
      _sayingAt = at;
      _said = Duration.zero;
      _error = null;
    });
    _sayTimer?.cancel();
    _sayTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted) return;
      setState(() => _said += const Duration(milliseconds: 200));
      // A minute is the cap, and the cap ends the note the way letting go
      // does rather than throwing it away: what was said up to here was
      // said on purpose.
      if (_said >= MomentNote.spokenLimit) unawaited(_finishSaying());
    });
  }

  /// The finger came up.
  void _letGo() {
    _holding = false;
    if (_saying) unawaited(_finishSaying());
  }

  /// Closes the microphone and pins what was said, once the person has said
  /// which recording it is about and that they want to keep it.
  Future<void> _finishSaying() async {
    if (!_saying) return;
    _sayTimer?.cancel();
    setState(() {
      _saying = false;
      _savingSaid = true;
    });
    try {
      final said = await _heard();
      if (said == null) return;
      final repository = _repository;
      final targets = _noteTargets;
      if (repository == null || targets.isEmpty || !mounted) return;
      final draft = await showMomentNoteSheet(
        context,
        atMs: _sayingAt,
        on: targets,
        initialLayerId: targets.last.id,
        spoken: true,
      );
      // Thrown away on purpose, which the sheet's button says in as many
      // words.
      if (draft == null || !mounted) return;
      setState(() => _status = 'Saving what you said');
      try {
        await repository.addSpokenMomentNote(
          roomId: widget.roomId,
          projectId: widget.projectId,
          layerId: draft.layerId,
          atMs: _sayingAt,
          bytes: said,
        );
      } catch (error) {
        // A refusal, not a crash report. The failure goes to the table in
        // full for whoever reads it; the screen says the one thing the
        // person can do about it. A note that fails to save and says
        // nothing is a note the teacher believes they left, which is the
        // silent-upload failure that cost three rounds of testing on takes.
        reportAndDescribe(
          error,
          service: 'layers',
          stage: 'takes.say',
          route: 'Takes',
          projectId: widget.projectId,
        );
        if (mounted) {
          setState(() => _error = 'That one did not save. Hold and say it again.');
        }
        return;
      }
      await _loadNotes();
    } finally {
      if (mounted) {
        setState(() {
          _savingSaid = false;
          _status = null;
        });
      }
    }
  }

  /// What the microphone heard, or null -- said on screen -- when it heard
  /// nothing worth keeping.
  Future<Uint8List?> _heard() async {
    Uint8List? said;
    try {
      said = await _mic.stop();
    } catch (error) {
      reportAndDescribe(
        error,
        service: 'layers',
        stage: 'takes.say',
        route: 'Takes',
        projectId: widget.projectId,
      );
      if (mounted) {
        setState(() => _error = 'The microphone gave nothing back. Hold and say it again.');
      }
      return null;
    }
    if (said == null || said.length < SpokenNoteRecorder.shortestNote) {
      // A tap rather than a hold, or a microphone that opened and heard
      // nothing. Not a fault to report: the label says hold, and this says
      // it again in the place the person is looking.
      if (mounted) setState(() => _error = _holdToSpeak);
      return null;
    }
    return said;
  }

  static const String _holdToSpeak =
      'Nothing was heard. Hold the button while you speak.';

  /// Plays what was said, on its own.
  ///
  /// The mix pauses first so the voice is heard clear of it, and the
  /// playhead moves to the note's moment the way tapping the row does, so
  /// Play afterwards hears the bar the note is about.
  Future<void> _listen(MomentNote note) async {
    final repository = _repository;
    if (repository == null || !note.isSpoken) return;
    final voice = _voice ??= AudioPlayer();
    _voiceDone ??= voice.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _hearing = null);
    });
    try {
      if (_hearing == note.id) {
        await voice.stop();
        if (mounted) setState(() => _hearing = null);
        return;
      }
      await voice.stop();
      if (_playing) await _togglePlay();
      await _openNote(note, play: false);
      final bytes = await repository.loadSpokenNote(note);
      await voice.play(BytesSource(bytes, mimeType: 'audio/wav'));
      if (mounted) setState(() => _hearing = note.id);
    } catch (error) {
      reportAndDescribe(
        error,
        service: 'layers',
        stage: 'takes.listen',
        route: 'Takes',
        projectId: widget.projectId,
      );
      if (!mounted) return;
      setState(() {
        _hearing = null;
        _error = 'That one would not play. Try it again in a moment.';
      });
    }
  }

  /// Plays a note's moment: from three seconds before it, round and round.
  Future<void> _openNote(MomentNote note, {bool play = true}) async {
    if (!mounted) return;
    setState(() => _noteLoop = note);
    await _goTo(Duration(milliseconds: note.playFromMs),
        play: play, stage: 'takes.note');
  }

  /// Moves the playhead somewhere, and starts there if asked to.
  ///
  /// Shared by a note somebody tapped and a moment somebody was sent, which
  /// are the same arrival: a place in the song, three seconds early.
  Future<void> _goTo(
    Duration from, {
    required bool play,
    required String stage,
  }) async {
    // The moment is on the song, not on a passage heard twice.
    if (_thenAndNow != null) await _stopThenAndNow();
    if (!mounted) return;
    setState(() => _position = from);
    try {
      if (!play) {
        // Left where the moment is, so pressing Play lands on it.
        await _player.seek(from);
        return;
      }
      if (kIsWeb) {
        final single = _webSinglePath;
        if (single == null) return;
        await _player.play(audioSourceFor(single));
        await _player.seek(from);
      } else {
        if (_lastMixPath == null && !await _rebuildMix()) return;
        await _playMix(from: from);
      }
      _pausedAt = null;
      if (mounted) setState(() => _playing = true);
    } catch (error) {
      // The playhead has already moved, so the moment is open either way.
      // What must not happen is silence with no reason: audio that will not
      // start here looks exactly like a note that does nothing.
      if (!mounted) return;
      setState(() => _error = reportAndDescribe(
            error,
            service: 'layers',
            stage: stage,
            route: 'Takes',
            projectId: widget.projectId,
          ));
    }
  }

  /// Opens the moment a link named (Every Musician, Same Song, schools item
  /// 1): the take audible, the playhead three seconds before it, playing.
  ///
  /// Once. The takes are read again on a pull, a share and a delete, and
  /// none of those is somebody asking to go back to the bar they arrived at.
  Future<void> _openLinkedMoment() async {
    final at = widget.openAt;
    if (at == null || _openedTheLink || !mounted) return;
    _openedTheLink = true;
    // A link names one take, and hearing that take is the whole of why it
    // was sent. Lanes can be switched off before anybody arrives -- the
    // turns of a round are, and every go at a turn but the last (see
    // [_load]) -- so a link to one of those would have played the song with
    // the take it names silent, which is indistinguishable from a link that
    // does not work.
    final takeId = at.takeId;
    if (takeId != null &&
        !_enabled.contains(takeId) &&
        _takes.any((take) => take.id == takeId)) {
      setState(() => _enabled.add(takeId));
      await _applyMixChange();
      if (!mounted) return;
    }
    await _goTo(Duration(milliseconds: MomentNote.playFromOf(at.atMs)),
        play: true, stage: 'takes.link');
  }

  /// The address of a moment of this song, as somebody can paste it.
  ///
  /// The room is in it because what it names is something inside a room, and
  /// being in that room is the whole of who can open it. Nothing about the
  /// song travels with it -- see AppRoutes.moment.
  Future<void> _copyLinkTo({String? takeId, required int atMs}) async {
    await copyAndSay(
      context,
      momentLink(
        roomId: widget.roomId,
        projectId: widget.projectId,
        takeId: takeId,
        atMs: atMs,
      ),
      // Said every time, because it is the thing somebody about to paste it
      // into a class page needs to know and there is no other moment to say
      // it in.
      'Link copied. It opens for people in this room.',
    );
  }

  Future<void> _deleteNote(MomentNote note) async {
    final repository = _repository;
    if (repository == null) return;
    try {
      // A voice that is still playing when its row goes would play on with
      // nothing left on screen to stop it.
      if (_hearing == note.id) {
        await _voice?.stop();
        if (mounted) setState(() => _hearing = null);
      }
      await repository.deleteMomentNote(note);
      if (mounted && _noteLoop?.id == note.id) {
        setState(() => _noteLoop = null);
      }
      await _loadNotes();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = reportAndDescribe(
            error,
            service: 'layers',
            stage: 'takes.unpin',
            route: 'Takes',
            projectId: widget.projectId,
          ));
    }
  }

  /// Lets the room hear a take that was until now only yours — or, in a
  /// lesson room, sends it to the one person who is there.
  ///
  /// The asking itself lives in sending_a_take.dart, so both wordings can be
  /// read in a test.
  Future<void> _share(SharedLayer layer) async {
    final confirmed = await confirmSharing(context, teacher: _sendTo);
    if (!confirmed || !mounted) return;

    setState(() => _busy = true);
    try {
      await _service.share(layer.id);
      await _load();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = reportAndDescribe(
            error,
            service: 'layers',
            stage: 'share',
            route: 'Takes',
            projectId: widget.projectId,
          ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Puts a take of your own away until a day you choose.
  ///
  /// Every Musician, Same Song, 17 September 2026: "A year ago tonight you
  /// sealed this. Play it now?" The asking lives in sealing_a_take.dart, so
  /// the words can be read in a test. Afterwards the take is not in this
  /// list, for anybody, until Home offers it back on its day -- so the one
  /// way back before then is here, for the few seconds the message stays.
  Future<void> _seal(SharedLayer layer) async {
    final controller = BetaScope.maybeOf(context, listen: false);
    if (controller == null) return;
    final chosen = await askWhenToOpen(context);
    if (chosen == null || !mounted) return;

    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _busy = true);
    try {
      final opens = await controller.sealTake(layer.id, until: chosen);
      await _load();
      await _leaveOutOfTheMix();
      messenger?.showSnackBar(SnackBar(
        content: Text(sealedUntilWords(opens)),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => unawaited(_unseal(layer)),
        ),
      ));
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = reportAndDescribe(
            error,
            service: 'layers',
            stage: 'seal',
            route: 'Takes',
            projectId: widget.projectId,
          ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Undo, a moment after sealing. The same call that ends a seal on its
  /// day, because it is the same act.
  Future<void> _unseal(SharedLayer layer) async {
    final repository = _repository;
    if (repository == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await repository.unsealTake(layer.id);
      await _load();
      await _leaveOutOfTheMix();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = reportAndDescribe(
            error,
            service: 'layers',
            stage: 'unseal',
            route: 'Takes',
            projectId: widget.projectId,
          ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Brings the sound into line with the list after a take has left it or
  /// come back.
  ///
  /// A take that is put away must not go on playing from a mix that was
  /// built while it was here. Only when there is a mix: before anything has
  /// been played there is nothing to rebuild, and the first Play builds it
  /// from the list as it then is.
  Future<void> _leaveOutOfTheMix() async {
    final stale = _lastMixPath;
    if (stale == null || !mounted) return;
    try {
      await _applyMixChange();
    } catch (_) {
      // Dropped below, which comes to the same thing one press later.
    }
    if (_lastMixPath != stale) return;
    // Nothing new was written: the rebuild failed, or the take that left was
    // the only thing there was to play. The old mix still has it in, so it
    // stops and is forgotten.
    try {
      if (_playing) await _player.stop();
    } catch (_) {
      // A player that will not stop is still not pointed at anything new.
    }
    _lastMixPath = null;
    _pausedAt = null;
    if (mounted) setState(() => _playing = false);
  }

  /// How loud the song sits while somebody plays over it.
  ///
  /// Its own sheet rather than the take one, because almost nothing in that
  /// sheet applies: there is no timing to nudge on a reference, and this
  /// level is local rather than shared. Saying so on the sheet matters —
  /// a fader that looks shared and is not would have somebody wondering why
  /// their bandmate still cannot hear them.
  Future<void> _showSongLevel() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.deepNavy,
      builder: (sheetContext) {
        var level = _songLevel;
        return StatefulBuilder(
          builder: (context, setSheetState) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    'The song',
                    style: TextStyle(
                        color: AppColors.text,
                        fontSize: 17,
                        fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'How loud it sits while you play over it. Yours only — it '
                    'does not change what anybody else hears.',
                    style: TextStyle(
                        color: AppColors.muted, fontSize: 12, height: 1.4),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: <Widget>[
                      const Icon(Icons.volume_down_rounded,
                          size: 18, color: AppColors.muted),
                      Expanded(
                        child: Slider(
                          value: level.clamp(
                              SongLevelStore.min, SongLevelStore.max),
                          min: SongLevelStore.min,
                          max: SongLevelStore.max,
                          divisions: 30,
                          activeColor: AppColors.gold,
                          inactiveColor: AppColors.line,
                          label: '${(level * 100).round()}%',
                          onChanged: (value) =>
                              setSheetState(() => level = value),
                          onChangeEnd: (value) {
                            setState(() => _songLevel = value);
                            unawaited(
                                SongLevelStore.save(widget.projectId, value));
                            unawaited(_applyMixChange());
                          },
                          semanticFormatterCallback: (value) =>
                              'Song level ${(value * 100).round()} percent',
                        ),
                      ),
                      SizedBox(
                        width: 46,
                        child: Text('${(level * 100).round()}%',
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                                color: AppColors.gold,
                                fontSize: 13,
                                fontWeight: FontWeight.w800)),
                      ),
                    ],
                  ),
                  const Text(
                    'A phone records a good deal quieter than a mastered mix. '
                    'If your take is buried, this is the fader that fixes it.',
                    style: TextStyle(
                        color: AppColors.muted, fontSize: 11.5, height: 1.4),
                  ),
                ],
              ),
            ),
          ),
        );
      },
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
              // Scrolls when it has to. A sheet is at most nine sixteenths of
              // the screen, and on a 640-pixel phone volume, timing and the
              // seal come to fifteen pixels more than that.
              child: SingleChildScrollView(
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
                        'A song with a song sheet times each take automatically. This is '
                        'for the last few milliseconds.',
                        style: TextStyle(
                            color: AppColors.muted, fontSize: 11.5, height: 1.4),
                      ),
                      // Sealing, on the take's own sheet rather than on the
                      // lane: the lane's 104 pixels already hold mute, levels
                      // and delete, and this is pressed once a year rather
                      // than once a take. Offered on exactly the takes Share
                      // is offered on -- your own, that nobody else has heard
                      // (0158 refuses the rest) -- and only inside the app,
                      // where there is a repository to seal it through.
                      if (!layer.isShared && _repository != null) ...<Widget>[
                        const SizedBox(height: 10),
                        TextButton.icon(
                          key: const Key('seal_take'),
                          onPressed: () {
                            Navigator.pop(sheetContext);
                            unawaited(_seal(layer));
                          },
                          icon: const Icon(Icons.lock_clock_outlined, size: 17),
                          label: const Text(
                            sealItLabel,
                            style: TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w700),
                          ),
                          style: TextButton.styleFrom(
                            foregroundColor: AppColors.gold,
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(48, 44),
                            alignment: Alignment.centerLeft,
                          ),
                        ),
                      ],
                    ],
                  ),
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
    // Going somewhere else means letting go of a note's loop, or of then and
    // now, or the playhead would be dragged straight back to it.
    if (_thenAndNow != null) await _stopThenAndNow();
    setState(() {
      _position = at;
      _noteLoop = null;
    });
    try {
      await _player.seek(at);
    } catch (_) {
      // Nothing loaded yet. The playhead still moved, and the next press of
      // play starts from where they left it.
    }
  }

  /// Your part forward, or everyone but you: two chips for every take
  /// somebody recorded, once there are two takes to tell apart.
  ///
  /// Chips rather than a sheet because this is chosen in the same breath as
  /// pressing play, and the one chosen is the whole state -- there is no
  /// hidden setting to go looking for. Each names the part and the person,
  /// never a count of the others. Nothing on the lanes moves when one is
  /// chosen: the levels the room set are what everybody else hears, and the
  /// line under the chips says so, once, while one is on.
  /// The one strip that says what went wrong, drawn by both layouts.
  ///
  /// One widget rather than two copies, so that a refusal written for the
  /// portrait list cannot again be missing from the console.
  Widget _problemStrip() {
    return Container(
      key: const Key('takes_problem'),
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFF718B).withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(10),
      ),
      child: ProblemNote(_error!,
          color: const Color(0xFFFFA0B0),
          fontSize: 12,
          height: 1.45,
          route: 'Takes'),
    );
  }

  Widget _myPartRow() {
    final offered = MyPartMix.offered(_takes, referenceId: _referenceId);
    if (offered.isEmpty) return const SizedBox.shrink();
    final chosen = _myPart;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 6,
            runSpacing: 2,
            children: <Widget>[
              for (final take in offered)
                for (final way in MyPartWay.values)
                  _MyPartChip(
                    choice: MyPart(takeId: take.id, way: way),
                    name: TakeNaming.partAndPerson(take),
                    selected:
                        chosen != null && chosen.takeId == take.id && chosen.way == way,
                    onTap: () =>
                        unawaited(_setMyPart(MyPart(takeId: take.id, way: way))),
                  ),
            ],
          ),
          if (chosen != null)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                'Yours only — it does not change what anybody else hears.',
                key: Key('my_part_note'),
                style: TextStyle(color: AppColors.muted, fontSize: 11.5, height: 1.4),
              ),
            ),
        ],
      ),
    );
  }

  /// Then and now: one chip per part this person has recorded more than
  /// once. Their own takes only -- nobody is offered a bandmate's first go
  /// beside their latest (see ThenAndNow.pairs), so in a room the chip is
  /// on your screen and not on theirs.
  ///
  /// Beside the part chips because it is chosen in the same breath -- hear
  /// my part, hear my first one. Tapped, it plays the bars under the
  /// playhead from the first take and then from the latest; tapped again,
  /// it stops. The line under it says only which half is sounding and which
  /// bars: never how far apart the two are, and never which is better.
  /// Every Musician, Same Song, 17 September 2026.
  Widget _thenAndNowRow() {
    final pairs = ThenAndNow.pairs(
      <SharedLayer>[
        for (final layer in _layers ?? const <SharedLayer>[])
          if (_localPaths[layer.id] != null) layer,
      ],
      by: _me,
    );
    if (pairs.isEmpty) return const SizedBox.shrink();
    final heardTwice = _thenAndNow;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 6,
            runSpacing: 2,
            children: <Widget>[
              for (final pair in pairs)
                _ThenAndNowChip(
                  pair: pair,
                  // One pair needs no name. Several say which part.
                  named: pairs.length > 1,
                  selected: heardTwice != null && heardTwice.pair == pair,
                  onTap: _busy || _recording
                      ? null
                      : () => unawaited(_playThenAndNow(pair)),
                ),
            ],
          ),
          if (heardTwice != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${_half.label} · ${heardTwice.passage.label}',
                key: const Key('then_and_now_half'),
                style: const TextStyle(
                    color: AppColors.muted, fontSize: 11.5, height: 1.4),
              ),
            ),
        ],
      ),
    );
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
                        'automatically, even on a song with no song sheet.',
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
            'Every phone records a moment behind what it plays. A song with a '
            'song sheet times each take to its beat automatically — this is '
            'the fallback for songs without one yet, and for parts with no '
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

/// One way of listening to one take: "Alto 2 — Jess forward", or "Everyone
/// but Alto 2 — Jess". Drawn the way the note sheet draws its take chips,
/// so the screen has one kind of chip.
class _MyPartChip extends StatelessWidget {
  const _MyPartChip({
    required this.choice,
    required this.name,
    required this.selected,
    required this.onTap,
  });

  final MyPart choice;
  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      key: Key('my_part_${choice.keySuffix}'),
      label: Text(choice.label(name)),
      selected: selected,
      backgroundColor: AppColors.raised,
      selectedColor: AppColors.cyan.withValues(alpha: 0.22),
      labelStyle: const TextStyle(color: AppColors.text, fontSize: 12.5),
      side: BorderSide(color: AppColors.cyan.withValues(alpha: 0.25)),
      visualDensity: VisualDensity.compact,
      onSelected: (_) => onTap(),
    );
  }
}

/// The chip that plays a passage twice: "Then and now", or "Then and now ·
/// lead" when this person has more than one pair on the song to choose
/// from.
///
/// The same chip as the part chips, so the screen keeps one kind, with a
/// play mark on it because this one does something rather than stays
/// something: it is the difference between a setting and a button, and
/// the plan's own audit found this app hides things brilliantly and
/// announces nothing.
class _ThenAndNowChip extends StatelessWidget {
  const _ThenAndNowChip({
    required this.pair,
    required this.named,
    required this.selected,
    required this.onTap,
  });

  final ThenAndNowPair pair;
  final bool named;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tap = onTap;
    return ChoiceChip(
      key: Key('then_and_now_${pair.now.id}'),
      avatar: Icon(
        selected ? Icons.stop_rounded : Icons.play_arrow_rounded,
        size: 16,
        color: AppColors.cyan,
      ),
      label: Text(
        named ? '${ThenAndNow.chipLabel} · ${pair.name}' : ThenAndNow.chipLabel,
      ),
      selected: selected,
      backgroundColor: AppColors.raised,
      selectedColor: AppColors.cyan.withValues(alpha: 0.22),
      labelStyle: const TextStyle(color: AppColors.text, fontSize: 12.5),
      side: BorderSide(color: AppColors.cyan.withValues(alpha: 0.25)),
      visualDensity: VisualDensity.compact,
      onSelected: tap == null ? null : (_) => tap(),
    );
  }
}
