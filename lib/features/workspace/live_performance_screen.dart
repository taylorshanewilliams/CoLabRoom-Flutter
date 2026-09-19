import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../services/audio_source_for.dart';
import '../../services/chord_beat_grid.dart'
    show barNumberAt, downbeatIndexOfBar, numberedBarCount;
import '../../services/click_player.dart';
import '../../services/follow_me.dart';
import 'package:flutter/services.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../domain/practice_mark.dart';
import '../../domain/song_analysis_models.dart';
import 'package:path_provider/path_provider.dart';

import '../../services/horn_reading.dart';
import '../../services/multitrack.dart';
import '../../services/music_reference.dart' show noteInKey;
import '../../services/number_reading.dart';
import '../../services/pitch.dart';
import '../../services/pitch_listener.dart';
import '../../services/play_along.dart';
import '../../services/rehearsal_letters.dart';
import '../../services/song_analysis_service.dart';
import '../../services/song_layer_service.dart';
import '../../services/take_naming.dart';
import '../../services/user_facing_error.dart';
import '../../widgets/microphone_disclosure.dart';
import '../layers/my_part.dart';
import '../layers/song_level_store.dart';
import '../layers/take_turns.dart';
import 'count_in.dart';
import 'follow_me_bar.dart';
import 'live_countdown_store.dart';
import 'musician_sheet_line.dart';
import 'musician_sheet_logic.dart';
import 'practice_marks.dart';
import 'practice_rules.dart';
import 'song_reading_store.dart';
import 'song_transpose_store.dart';

enum LiveScrollMode { off, synced, slow, medium, fast, timed }

/// Which lyric source Live Performance reads from — the live collaborative
/// workspace (whatever's currently typed, unfrozen), or the Song Sheet (the
/// snapshot from the last analysis, with chords). The user picks; neither
/// is silently preferred over the other.
enum LiveLyricSource { workspace, songSheet }

/// Where the line you are singing sits on screen.
///
/// Taylor, 15 September 2026: "the highlighted words are always at the very
/// top ... it would be nice if the highlighted words were maybe a little
/// above the middle of the screen, so this way you can always know where you
/// are in the song, what you just played and where you're going."
///
/// He is right, and it is not only a preference: a line pinned to the top
/// edge gives a player no past. You cannot glance back at the line you have
/// just sung to find your place again after looking at your hands, and the
/// first thing a singer does when they lose their place is look *up*. A
/// little above the middle leaves a third of the screen behind you and most
/// of it ahead.
const double kSingingLineFraction = 0.38;

/// How often Perform looks at itself: where the song is, and — below — what
/// is being practised.
const Duration kPerformTick = Duration(milliseconds: 50);

/// What Perform says when the song's recording could not be fetched.
const String recordingNotLoaded =
    'The recording could not be loaded. The words are here; the song is not.';

/// The scroll offset that puts the line at [lineOffset] on the anchor.
///
/// Clamped, because the first lines of a song cannot be pushed below the top
/// of the content and the last cannot be pulled past the end — near both
/// edges the line simply sits where it can.
double scrollToPutLineAtAnchor({
  required double lineOffset,
  required double viewportHeight,
  required double maxExtent,
}) {
  final target = lineOffset - viewportHeight * kSingingLineFraction;
  final limit = maxExtent > 0 ? maxExtent : 0.0;
  return target.clamp(0.0, limit).toDouble();
}

class LivePerformanceScreen extends StatefulWidget {
  const LivePerformanceScreen({
    required this.project,
    this.analysis,
    this.openMicrophone,
    this.playAlongMixer,
    this.partMixer,
    this.layerService,
    this.analysisService,
    this.together,
    this.me = '',
    this.keepPractice,
    this.ownMarkId,
    this.practise,
    this.click,
    this.missing,
    this.onSayBarOne,
    super.key,
  });

  /// Says which downbeat of the analysis is bar 1, or hands the song back to
  /// the detected bars with a null.
  ///
  /// A shared fact, not a reading: it moves everybody's bar numbers, so only
  /// the room's owner and its editors may write it (0161). Null for somebody
  /// who may only look, and for a door that has no room to ask — the songs
  /// kept on this phone, which are opened with no network. The picker then
  /// offers no way to move bar 1, and simply counts from wherever the song
  /// already says.
  final Future<void> Function(int? downbeat)? onSayBarOne;

  /// What counts the band in on the song's own bar. Production leaves this
  /// null and uses the metronome's click; a test hands in a silent one.
  final ClickPlayer? click;

  /// What this phone could not get for this song, said once as the screen
  /// opens. Null when nothing is missing, which is nearly always.
  ///
  /// The door that opens Perform asks for the sheet and may get neither the
  /// server's nor a copy kept on this phone. Opened silently with the words
  /// alone, that looks exactly like a song that has no recording, and a
  /// person in a basement would not know whether to blame the song or the
  /// signal (Every Musician, Same Song, 17 September 2026). See
  /// SongAnalysisService.sheetForPerform for the sentences.
  final String? missing;

  /// Where what a session leaves behind goes: the part worked on, the speed,
  /// and the leader's note when there was a leader. Null keeps nothing, which
  /// is a preview or a test that is not asking for it.
  final void Function(PracticeMark mark)? keepPractice;

  /// The mark this person's own practice on this song is already kept under,
  /// so tonight's session updates it instead of adding another. Null starts a
  /// new one. See ownPracticeMarkId in practice_marks.dart.
  final String? ownMarkId;

  /// Opened from a practice mark on Home: already on this part, at this
  /// speed, waiting for Start.
  final PracticePart? practise;

  final SongProject project;

  /// Follow me, when the song is open on other phones: this screen leads
  /// them, follows whoever leads, or offers to. Null when the song is opened
  /// from somewhere that is not the song itself, which then works exactly
  /// as it always did.
  final FollowSession? together;

  /// Who is looking, so "your other device" can be told apart from a
  /// bandmate. Only read by the Follow me row.
  final String me;

  /// Analyzed sync data for this song (from Song Analysis), if any. When
  /// this has real per-line timing (`hasSyncedLyrics`), Live mode drives the
  /// scroll position off the actual lyric timestamps instead of a constant
  /// speed, and highlights the line that should be sung right now.
  final SongAnalysisBundle? analysis;

  /// Where the singer's voice comes from when they sing along. Production
  /// leaves this null and uses the microphone; a test hands in a tone.
  final Future<Stream<Uint8List>> Function()? openMicrophone;

  /// Builds the band-without-you mix and returns its local path. Production
  /// leaves this null and uses PlayAlong over the cached stems; a test hands
  /// in something that answers at once.
  final Future<String> Function(
    List<SongStem> stems,
    StemKind without,
    void Function(String stage) onProgress,
  )? playAlongMixer;

  /// Writes the song's takes, already at the levels this person is
  /// listening at, into one file and returns its path. Production leaves
  /// this null and uses Multitrack over the cached takes; a test hands in
  /// something that answers at once and keeps what it was given.
  final Future<String> Function(
    List<Take> takes,
    void Function(String stage) onProgress,
  )? partMixer;

  /// Where the song's takes and its recording come from. Null in production,
  /// which reaches for the real services; a test hands in ones that answer
  /// without a network, the same seam the takes screen has.
  final SongLayerService? layerService;
  final SongAnalysisService? analysisService;

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
  Timer? _countdownTimer;
  DateTime? _lastTick;
  bool _countdownEnabled = false;
  int _countdownSeconds = LiveCountdownStore.defaultSeconds;
  int? _countdownRemaining;

  /// The bar being counted in, when the song has a beat of its own, and which
  /// beat of it is sounding now. The bar is set the moment play is pressed;
  /// the beat only once the click is actually going, so the dots and the
  /// clicks start together rather than a click's loading time apart.
  CountIn? _countInBar;
  int? _countInBeat;

  /// Which count-in is the current one. A second tap while the click is still
  /// being prepared must not leave the first one to start counting after it.
  int _countInGeneration = 0;

  /// The click that counts the bar, made only if a song ever needs one.
  ClickPlayer? _clickPlayer;
  ClickPlayer get _click => _clickPlayer ??= widget.click ?? WavClickPlayer();

  LiveScrollMode _mode = LiveScrollMode.off;
  bool _playing = false;
  bool _controlsVisible = true;
  bool _showChords = true;

  /// The key this person plays the song in, as they left it on the sheet.
  ///
  /// Perform drew every chord with a transpose of zero, so a song moved down
  /// two to fit somebody's voice went on stage in its original key (audit,
  /// 17 September 2026). Read from this device and never from Follow me: a
  /// leader moves where the song is, not what key a follower reads it in.
  int _transpose = 0;

  /// The instrument this person reads the song for, as they left it on the
  /// sheet's key badge. Stacks on [_transpose], and personal for the same
  /// reason: a B♭ player and a guitarist follow the same leader through the
  /// same song and read two different pages (Every Musician, Same Song, 17
  /// September 2026).
  HornReading _reading = HornReading.concert;

  /// Which fret the capo is on and whether the chords read as numbers, both
  /// as this person left them on the sheet. Personal like the transpose, and
  /// read back here so a guitarist who set the song up before rehearsal still
  /// has it on stage (Every Musician, Same Song, 17 September 2026).
  int _capo = 0;
  NumberReading _numbers = NumberReading.letters;
  double _fontScale = 1;
  Duration _songDuration = const Duration(minutes: 3, seconds: 30);
  Duration _elapsed = Duration.zero;
  String? _activeLineKey;
  String? _lastLayoutKey;
  late final List<MusicianSheetLine> _workspaceLines;
  late final List<MusicianSheetLine> _sheetLines;
  late final Map<String, Color> _colorByContributionId;
  late LiveLyricSource _source;
  AudioPlayer? _audioPlayer;
  StreamSubscription<Duration>? _audioPositionSub;
  StreamSubscription<void>? _audioCompleteSub;
  bool _audioReady = false;

  /// When [_elapsed] was last read off the player. The player reports its
  /// position a few times a second; two phones comparing those reports
  /// would disagree by up to twice that for no reason, and correct each
  /// other into a stutter. See [_elapsedNow].
  DateTime? _elapsedStamp;

  StreamSubscription<FollowState>? _followSub;
  StreamSubscription<String>? _noteSub;
  StreamSubscription<FollowEnded>? _endSub;
  bool _hadLeader = false;

  /// What following has worked on, and the mark it will be kept as. The
  /// mark is named up front so that saving it again -- the student took the
  /// song back, then followed again -- updates one mark rather than adding a
  /// second. A new name only once a leader has stopped.
  PracticeLog _practice = PracticeLog();
  String _markId = newPracticeMarkId();
  String? _markNote;
  String? _markLeaderName;
  String? _markLeaderId;

  /// The leader's clock at the last state heard, and this phone's at the
  /// moment it arrived. Practice is timed on the leader's clock -- the
  /// states say when they left, two seconds apart while playing -- and the
  /// stretch after the last one is carried on from there.
  int? _heardSentAt;
  int? _heardLocalAt;

  int _practiceNow() {
    final sent = _heardSentAt;
    final local = _heardLocalAt;
    if (sent == null || local == null) return DateTime.now().millisecondsSinceEpoch;
    return sent + (DateTime.now().millisecondsSinceEpoch - local);
  }

  /// What this person has practised on their own, and the mark it will be
  /// kept as.
  ///
  /// A lesson is not the only practice there is. Somebody who opens Perform
  /// on a Tuesday with nobody waiting on them, puts Chorus 2 on repeat and
  /// slows it to three quarters has practised, and until now the app kept
  /// nothing of it: only a followed session left a mark (Every Musician,
  /// Same Song, 17 September 2026). The rules are the same ones — a part on
  /// repeat or a slower speed, long enough to be more than passing through —
  /// and what is kept is kept on the way out, with this person as their own
  /// leader. Named up front, like the lesson's, so one visit is one mark --
  /// and named with [LivePerformanceScreen.ownMarkId] when this song already
  /// has one of these, so a habit is one mark kept up to date rather than a
  /// fortnight of rows.
  final PracticeLog _own = PracticeLog();
  late final String _ownMarkId = widget.ownMarkId ?? newPracticeMarkId();

  /// The clock the solo log is kept on: one tick is one [kPerformTick].
  ///
  /// Counted rather than read off the wall, because under load the ticker is
  /// the honest measure of how much of this screen actually ran, and because
  /// nothing anywhere says how long anybody played for — this is a threshold
  /// to cross, not a number to show. A test can drive it, which a stopwatch
  /// on DateTime.now() could not.
  int _ownAtMs = 0;

  /// Credits the tick just past to whatever this phone was doing, when the
  /// song was this phone's to move.
  ///
  /// Following, the song belongs to the leader and what the lesson leaves is
  /// built from their own states in [_applyFollow]; leading or alone, it is
  /// being moved here, so it is this person's own practice. [_followStateNow]
  /// is exactly what this screen is doing this instant, which is what the log
  /// reads.
  void _logOwnPractice() {
    // Nowhere to put it: a preview, or a test that did not ask.
    if (widget.keepPractice == null) return;
    _ownAtMs += kPerformTick.inMilliseconds;
    if (widget.together?.following ?? false) {
      _own.pause(_ownAtMs);
      return;
    }
    _own.heard(_followStateNow(), _ownAtMs);
  }

  /// Practising: one part on repeat, and the recording slowed.
  ///
  /// Both belong to synced mode, the one where the song is the clock. A loop
  /// is a section of the song's own structure -- Intro, Verse, Chorus -- or a
  /// run of bars off the recording's own grid, so "again" means either the
  /// part a musician would name or the bars they would count, never a raw
  /// time range. The rate is applied to the player when there is one and to
  /// the wall clock when there is not, so a sheet with no recording still
  /// slows down.
  double _rate = 1;
  PracticeLoop? _loop;

  /// Singing along: the phone's ear open, the singer's note beside the
  /// song's. Only offered when the recording has a tune to sing against.
  PitchListener? _ear;
  bool _singing = false;
  String? _singError;

  /// The band without you: which part is left out of what is playing, the
  /// recording's own local path to go back to, and what the mixer is
  /// saying while it works (or why it could not).
  StemKind? _without;
  String? _referencePath;
  bool _mixing = false;
  String? _mixNote;

  /// Your part forward, or everyone but you: the song's takes, the local
  /// copies fetched so far (only when a part is first chosen -- opening the
  /// words must not download a choir), and which take this person is
  /// listening for. See MyPartMix. Kept on this phone per song, like the
  /// key, and never carried by Follow me.
  List<SharedLayer> _layers = const <SharedLayer>[];
  final Map<String, String> _localTakes = <String, String>{};
  MyPart? _myPart;

  /// The takes that are turns of a round (0159), which are left out here for
  /// the reason the takes screen leaves them out: they all sit on the same
  /// few bars, so a mix with every one of them switched on is four solos
  /// playing at once, which nobody played. A round is heard in order, from
  /// its own card on the takes screen. Every Musician, Same Song, 17
  /// September 2026.
  Set<String> _turns = const <String>{};

  /// Done once the recording is local, or has failed to be. A part kept
  /// from last time is restored after this, so the mix is built with the
  /// song in it. Whichever of the two makes the player first keeps it; see
  /// _prepareAudio.
  final Completer<void> _referenceReady = Completer<void>();

  /// The last part mix written, deleted when the next one replaces it. Each
  /// build is a new file because audioplayers keys its cache on the path:
  /// one name rewritten would play the first mix ever built under it.
  String? _lastPartMixPath;

  SongAnalysisService get _analysis => widget.analysisService ?? SongAnalysisService();
  SongLayerService get _layerService => widget.layerService ?? SongLayerService();

  List<StructureSection> get _sections =>
      widget.analysis?.reference?.structureSections ??
      const <StructureSection>[];

  /// A letter per part, the way a band names them: "from B". Derived from
  /// the sections every time rather than kept, so a re-analysis or a rename
  /// cannot leave a stale letter behind (see rehearsal_letters.dart).
  List<RehearsalLetter> get _letters => rehearsalLetters(_sections);

  /// The first beat of each bar, which is the whole of what bar loops are
  /// built on. Empty for a recording analysed before beat tracking, or one
  /// the tracker gave no confident answer for: those songs keep section
  /// loops and are offered no bars at all.
  List<int> get _downbeats =>
      widget.analysis?.reference?.downbeatsMs ?? const <int>[];

  /// Which downbeat the band counts as bar 1 (0161), and whether that is the
  /// analysis's own answer or one somebody gave.
  ///
  /// Kept here as well as on the song because this screen is pushed with a
  /// copy of the song and never handed another one: saying it in the bar
  /// picker has to move the numbers on this screen at once, and the song in
  /// the rooms catches up behind it.
  late int? _barOneSaid = widget.project.barOneDownbeat;

  int get _barOne => _barOneSaid == null || _barOneSaid! < 1 ? 1 : _barOneSaid!;

  /// Where the recording stops, for the one bar that has no next downbeat to
  /// end on. Not [_songDuration], which a manual "song time" can set to
  /// something the recording is not.
  int? get _recordingEndMs {
    final duration = widget.analysis?.reference?.durationMs;
    if (duration != null && duration > 0) return duration;
    return _sheetLines.isEmpty ? null : _sheetLines.last.endMs;
  }

  Melody? get _melody => widget.analysis?.reference?.melody;

  /// Whether somebody is practising rather than performing.
  ///
  /// A part on repeat, a slower speed, or singing along is the difference.
  /// On stage the controls get out of the way after a few seconds, which is
  /// right: the words are the point. Practising, the controls *are* the
  /// point -- the first device test of this screen spent half its taps
  /// revealing the bar before the chip underneath could be pressed.
  bool get _practising =>
      _loop != null || _rate != 1 || _singing || _without != null || _myPart != null;

  /// Whether the practice row is on screen, so the words can leave room
  /// for it rather than run underneath.
  bool get _practiceRowShown => _mode == LiveScrollMode.synced && _hasSync;

  static const _emptyBundle =
      SongAnalysisBundle(reference: null, lyricCues: <LyricSyncCue>[], chordCues: <ChordCue>[]);

  List<MusicianSheetLine> get _lines =>
      _source == LiveLyricSource.workspace ? _workspaceLines : _sheetLines;

  // The Song Sheet always carries real per-line timing (transcript word
  // timestamps, or evenly-spaced chord groupings for instrumental-only
  // recordings) — "synced" scroll is available whenever there's a sheet to
  // read from, keyed by MusicianSheetLine.startMs/endMs rather than
  // LyricSyncCue (which analysis no longer writes, since lyrics are never
  // aligned to a Contribution anymore).
  bool get _hasSync => _source == LiveLyricSource.songSheet && _sheetLines.isNotEmpty;

  @override
  void initState() {
    super.initState();
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    // Both modes are built from the same unified line logic the Song Sheet
    // view uses (buildMusicianSheetLines) — "workspace" just passes an
    // empty analysis bundle, so it always reflects the live collaborative
    // lyrics (no chords, no frozen timing) regardless of what the last
    // analysis produced. "Song Sheet" passes the real analysis, which may
    // itself be a generated transcript when the project had no lyrics of
    // its own at analysis time.
    _workspaceLines = buildMusicianSheetLines(widget.project, _emptyBundle);
    _sheetLines = buildMusicianSheetLines(
      widget.project,
      widget.analysis ?? _emptyBundle,
      ignoreWorkspaceLyrics: true,
    );
    _colorByContributionId = <String, Color>{
      for (final contribution in widget.project.contributions)
        contribution.id: Color(contribution.colorValue),
    };
    final sheetReady = widget.analysis?.ready ?? false;
    _source = sheetReady ? LiveLyricSource.songSheet : LiveLyricSource.workspace;
    _mode = _hasSync ? LiveScrollMode.synced : LiveScrollMode.off;
    // Opened to practise: the part and the speed from the mark, the song at
    // the start of that part, and nothing playing until Start.
    final practise = widget.practise;
    if (practise != null && _hasSync) {
      _rate = practise.rate;
      _loop = _loopFor(practise.startMs, practise.endMs);
      _elapsed = Duration(milliseconds: _loop?.startMs ?? 0);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        _captureLineOffsets();
        final position = _scroll.position;
        if (position.maxScrollExtent > 0) _tickSynced(position, position.maxScrollExtent);
      });
    }
    if (_hasSync) {
      final track = widget.analysis?.reference;
      final lastLineEnd = _sheetLines.isEmpty ? 0 : _sheetLines.last.endMs;
      final durationMs = track?.durationMs ?? lastLineEnd;
      if (durationMs > 0) _songDuration = Duration(milliseconds: durationMs);
    }
    _ticker = Timer.periodic(kPerformTick, (_) => _tick());
    _armControlHide();
    final reference = widget.analysis?.reference;
    if (reference != null) {
      unawaited(_prepareAudio(reference));
    } else {
      // Nothing to wait for: a part mix on a song with no recording is the
      // takes alone.
      _referenceReady.complete();
    }
    unawaited(_loadTakes());
    unawaited(_loadCountdownPrefs());
    unawaited(_loadTranspose());
    unawaited(_loadReading());
    unawaited(_loadCapo());
    unawaited(_loadNumbers());
    final missing = widget.missing;
    if (missing != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _say(missing));
    }

    final together = widget.together;
    if (together != null) {
      together.addListener(_togetherChanged);
      _hadLeader = together.leader != null;
      _followSub = together.states.listen(_applyFollow);
      _noteSub = together.notes.listen(_say);
      _endSub = together.endings.listen(_followEnded);
      // Arrived by pressing Follow on the song: catch up with the leader
      // as soon as there are words on screen to move.
      final leader = together.leader;
      if (together.following && leader != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _applyFollow(leader.state));
      }
    }
  }

  /// Where the song is this instant: the player's last report, moved on by
  /// the time since it was made. See [_elapsedStamp].
  Duration get _elapsedNow {
    final stamp = _elapsedStamp;
    final audioIsClock = _audioPlayer != null && _mode == LiveScrollMode.synced;
    if (!_playing || !audioIsClock || stamp == null) return _elapsed;
    return _elapsed + atRate(DateTime.now().difference(stamp), _rate);
  }

  void _togetherChanged() {
    if (!mounted) return;
    final hasLeader = widget.together?.leader != null;
    final arrived = hasLeader && !_hadLeader;
    _hadLeader = hasLeader;
    // Somebody just started leading: show the bar, because Follow is on it
    // and a hidden button is not an offer.
    if (arrived) {
      _showControls();
    } else {
      setState(() {});
    }
  }

  void _say(String note) {
    if (!mounted) return;
    // Cleared rather than only the current one hidden: a sentence still
    // queued behind the one on screen would play after the newer one that
    // replaced it ("Taylor stopped leading." three seconds after "Taylor
    // stopped leading. Chorus at ¾ is on your Home").
    ScaffoldMessenger.maybeOf(context)
      ?..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(note), duration: const Duration(seconds: 4)));
  }

  /// What this screen tells its followers: where the song is, and nothing
  /// about what this phone is hearing (see follow_me.dart).
  FollowState _followStateNow() {
    final synced = _mode == LiveScrollMode.synced && _hasSync;
    final loop = _loop;
    return FollowState(
      sheet: _source == LiveLyricSource.songSheet,
      synced: synced,
      // A count-in is not playing yet; followers start when the song does.
      playing: _playing,
      positionMs: synced ? _elapsedNow.inMilliseconds : 0,
      rate: _rate,
      sentAt: DateTime.now().millisecondsSinceEpoch,
      loopStartMs: synced ? loop?.startMs : null,
      loopEndMs: synced ? loop?.endMs : null,
      lineKey: synced ? null : _lineOnAnchor(),
      // Where bar 1 is goes with it, whether or not the song is the clock: a
      // loop sent as two times is named on the other phone, and it can only
      // be named in the same numbers if the other phone counts from the same
      // bar 1 (0161). Sent as 0 when nobody has said, so that clearing it
      // reaches the followers too.
      barOne: _barOneSaid ?? 0,
    );
  }

  /// Puts this screen where the leader's is.
  ///
  /// Only what is shared moves: which words, whether the song is the clock,
  /// the speed, the part on repeat, playing or not, and where. A small
  /// disagreement is left alone, because every correction is a seek and a
  /// seek is a hiccup you can hear.
  void _applyFollow(FollowState state) {
    final together = widget.together;
    if (!mounted || together == null || !together.following) return;
    _practice.heard(state, state.sentAt);
    _heardSentAt = state.sentAt;
    _heardLocalAt = DateTime.now().millisecondsSinceEpoch;
    final leader = together.leader;
    if (leader != null) {
      _markLeaderName = leader.name;
      _markLeaderId = leader.userId.isEmpty ? null : leader.userId;
    }
    _cancelCountdown();
    // Before anything is named. This screen was handed its copy of the song
    // once, when it was pushed, so a bar 1 said in the middle of the lesson
    // never reaches it any other way — and the middle of the lesson is
    // exactly when somebody notices the count-in (0161; review, 18 September
    // 2026). A message from a build that does not say leaves it alone.
    final saidBarOne = state.barOne;
    if (saidBarOne != null) {
      _barOneSaid = saidBarOne < 1 ? null : saidBarOne;
    }
    final source = state.sheet && _sheetLines.isNotEmpty
        ? LiveLyricSource.songSheet
        : LiveLyricSource.workspace;
    if (source != _source) _switchSource(source);
    if (state.synced && _hasSync) {
      _followClock(state, together);
    } else {
      _followLine(state);
    }
  }

  void _followClock(FollowState state, FollowSession together) {
    final audio = _audioPlayer;
    if (_mode != LiveScrollMode.synced) {
      _mode = LiveScrollMode.synced;
      _markOffsetsDirty();
    }
    if (_rate != state.rate) {
      _rate = state.rate;
      if (audio != null) unawaited(audio.setPlaybackRate(state.rate));
    }
    _loop = _loopFor(state.loopStartMs, state.loopEndMs);
    final target = together.targetMs() ?? state.positionMs;
    final moved = worthCorrecting(_elapsedNow.inMilliseconds, target);
    if (moved) _seekTo(Duration(milliseconds: target));
    final started = state.playing != _playing;
    if (started) {
      _playing = state.playing;
      if (audio != null) unawaited(_playing ? audio.resume() : audio.pause());
    }
    _lastTick = null;
    setState(() {});
    // Only when playing starts or stops. A heartbeat arrives every two
    // seconds, and re-arming on each one would keep the controls over the
    // words for the whole song on a phone sitting on a music stand.
    if (started) _armControlHide();
    if (!_playing && moved) {
      // Paused, the words still go to where the leader is looking.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        final position = _scroll.position;
        if (position.maxScrollExtent > 0) _tickSynced(position, position.maxScrollExtent);
      });
    }
  }

  /// A leader scrolling by hand, or at a speed, has no clock to share; what
  /// they are looking at is the line on their anchor, so that line comes to
  /// this phone's anchor. The words follow, not the recording.
  void _followLine(FollowState state) {
    final audio = _audioPlayer;
    if (_playing) {
      _playing = false;
      if (audio != null) unawaited(audio.pause());
    }
    _loop = null;
    if (_mode == LiveScrollMode.synced) _mode = LiveScrollMode.off;
    setState(() {});
    final key = state.lineKey;
    if (key == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (_offsetsDirty || !_lineOffsets.containsKey(key)) _captureLineOffsets();
      final offset = _lineOffsets[key];
      if (offset == null) return;
      final target = scrollToPutLineAtAnchor(
        lineOffset: offset,
        viewportHeight: _viewportHeight,
        maxExtent: _scroll.position.maxScrollExtent,
      );
      unawaited(_scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      ));
    });
  }

  /// What is on repeat, found by where it sits in the song: the part with
  /// those edges, or the bars it covers. See loopFor.
  PracticeLoop? _loopFor(int? startMs, int? endMs) => loopFor(
        startMs,
        endMs,
        sections: _sections,
        downbeatsMs: _downbeats,
        // One funnel for every name a stretch of this song gets: the chip,
        // the follower's chip, and what a practice mark remembers. They agree
        // because they all come through here (0161).
        barOne: _barOne,
      );

  /// Following ended. Whatever was worked on is kept, with the leader's
  /// note; when it was the leader who stopped, the phone says where it went,
  /// because that sentence is the only way anybody finds out Home has it.
  void _followEnded(FollowEnded end) {
    _practice.pause(_practiceNow());
    _markLeaderName = end.leaderName;
    _markLeaderId = end.leaderUserId ?? _markLeaderId;
    if (end.note != null) _markNote = end.note;
    final mark = _keepPractice();
    // Only a leader who said they had stopped ends the lesson. Losing touch
    // keeps the same mark open: this phone follows again if they come back.
    if (!end.stopped) return;
    if (mark != null && mounted) {
      final worked = practiceWorked(mark);
      _say(worked == null
          ? '${end.said} Their note is on your Home.'
          : '${end.said} $worked is on your Home to practise.');
    }
    // A leader who stopped ended that lesson. Following somebody again on
    // this screen is a new one.
    _practice = PracticeLog();
    _markId = newPracticeMarkId();
    _markNote = null;
    _heardSentAt = null;
    _heardLocalAt = null;
  }

  /// Hands what has been worked on to [LivePerformanceScreen.keepPractice],
  /// when there is anything worth a card.
  PracticeMark? _keepPractice() {
    final keep = widget.keepPractice;
    final mark = _practiceMark();
    if (keep == null || mark == null) return null;
    keep(mark);
    return mark;
  }

  /// What following has worked on so far, as a mark, or null when nothing
  /// was practised and nothing was said.
  PracticeMark? _practiceMark() {
    if (widget.keepPractice == null) return null;
    final parts = _practice.parts(_partLabel);
    if (!worthKeeping(parts, _markNote)) return null;
    return PracticeMark(
      id: _markId,
      projectId: widget.project.id,
      ledBy: _markLeaderId,
      ledByName: _markLeaderName ?? 'Someone',
      note: _markNote,
      parts: parts,
      updatedAt: DateTime.now(),
    );
  }

  /// What this person has practised on their own so far, as a mark of their
  /// own, or null when nothing was put on repeat or slowed for long enough.
  PracticeMark? _ownMark() {
    // Signed out there is nobody to keep it for, and a mark whose leader is
    // not known could not be told from a lesson's on the card.
    if (widget.keepPractice == null || widget.me.isEmpty) return null;
    final parts = _own.parts(_partLabel);
    // No note: practising alone, nobody said anything.
    if (!worthKeeping(parts, null)) return null;
    return PracticeMark(
      id: _ownMarkId,
      projectId: widget.project.id,
      ledBy: widget.me,
      // Never read back — the card says "Your practice" rather than a name —
      // but the mark is not allowed a blank one.
      ledByName: 'You',
      parts: parts,
      updatedAt: DateTime.now(),
    );
  }

  /// A part named the way its chip is -- "Chorus 2", or "Bars 9–12" for a run
  /// of bars, which is what makes a practice mark read "Bars 9–12 at 70%".
  String _partLabel(int? startMs, int? endMs) {
    if (startMs == null || endMs == null) return 'The whole song';
    return _loopFor(startMs, endMs)?.label ?? 'A part of the song';
  }

  /// Stop leading. With somebody following, first the chance to leave them
  /// something to practise from.
  Future<void> _stopLeading() async {
    final together = widget.together;
    if (together == null || !together.leading) return;
    if (together.followers == 0) {
      together.stopLeading();
      return;
    }
    final note = await showLeaveANote(context, followers: together.followers);
    if (note == null || !mounted) return;
    together.stopLeading(note: note);
  }

  /// A follower touched the song, so it is theirs now.
  ///
  /// Only the controls that move the song count. Bigger words, chords, a
  /// part left out and singing along are each person's own, and never end
  /// following.
  void _takeOver() {
    final together = widget.together;
    if (together == null) return;
    final wasFollowing = together.following;
    // Also forgets a leader this phone lost touch with and was waiting for:
    // pressing Start is choosing the song, and a leader coming back must
    // not take it away again.
    together.unfollow();
    if (wasFollowing) _say('You have the song now. Follow again from the bar.');
  }

  Future<void> _loadCountdownPrefs() async {
    final (enabled, seconds) = await LiveCountdownStore.load();
    if (!mounted) return;
    setState(() {
      _countdownEnabled = enabled;
      _countdownSeconds = seconds;
    });
  }

  Future<void> _loadTranspose() async {
    final kept = await SongTransposeStore.load(widget.project.id);
    if (!mounted || kept == _transpose) return;
    setState(() => _transpose = kept);
    // A chord name changes width when it moves ("G" to "Bb"), which can move
    // where a line wraps and so where the synced scroll thinks it is.
    _markOffsetsDirty();
  }

  /// The instrument this person reads the song for, chosen on the song
  /// sheet's key badge and read back here so a horn player who set their part
  /// up before rehearsal still has it on stage.
  Future<void> _loadReading() async {
    final kept = await SongReadingStore.load(widget.project.id);
    if (!mounted || kept == _reading) return;
    setState(() => _reading = kept);
    _markOffsetsDirty();
  }

  /// The capo and the number reading, chosen on the song sheet's key badge
  /// and read back here for the same reason the instrument's part is.
  Future<void> _loadCapo() async {
    final kept = await SongCapoStore.load(widget.project.id);
    if (!mounted || kept == _capo) return;
    setState(() => _capo = kept);
    _markOffsetsDirty();
  }

  Future<void> _loadNumbers() async {
    final style = await SongNumbersStore.load(widget.project.id);
    final minor = await MinorNumbersStore.load();
    final kept = NumberReading(style: style, minor: minor);
    if (!mounted || kept == _numbers) return;
    setState(() => _numbers = kept);
    // A chord name changes width when it becomes a number, which can move
    // where a line wraps and so where the synced scroll thinks it is.
    _markOffsetsDirty();
  }

  /// Loads the analyzed reference recording so "synced" mode can play the
  /// actual take underneath the scrolling lyrics — without this, "synced"
  /// was only ever a guess at where you should be, with no way to actually
  /// hear whether it lines up.
  Future<void> _prepareAudio(ReferenceTrack reference) async {
    final String path;
    try {
      path = await _analysis.ensureLocalReference(reference);
    } catch (_) {
      // Said, not swallowed. A recording that will not fetch -- no signal
      // and no copy kept on this phone, most often -- used to leave the
      // words scrolling on their own with no word about why, which is
      // exactly what a song with no recording looks like (Every Musician,
      // Same Song, 17 September 2026). The player failing, below, stays
      // quiet as it always did: that is the phone, not the song.
      _say(recordingNotLoaded);
      if (!_referenceReady.isCompleted) _referenceReady.complete();
      return;
    }
    try {
      if (!mounted) return;
      _referencePath = path;
      // The path is all a part mix needs, so a part kept from last time can
      // start building now rather than after the player below is ready.
      if (!_referenceReady.isCompleted) _referenceReady.complete();
      final player = AudioPlayer();
      await player.setSource(audioSourceFor(path));
      if (_rate != 1) await player.setPlaybackRate(_rate);
      // The song may already be somewhere: Start pressed while this loaded,
      // or a leader followed from the first second. The recording starts
      // from there rather than from the top, under words that are not.
      if (_elapsed > Duration.zero) await player.seek(_elapsed);
      // Gone, or a mix got here first: a part mix, or the band without a
      // part, put its own player under the words while the recording
      // loaded, and that one has the recording in it already. Until this
      // check the recording on its own replaced it, and the mix player
      // leaked.
      if (!mounted || _audioPlayer != null) {
        await player.dispose();
        return;
      }
      _audioPositionSub = player.onPositionChanged.listen((position) {
        // Only the actual clock for "synced" mode — other scroll modes keep
        // their own manual speed, with audio just playing alongside.
        if (_playing && _mode == LiveScrollMode.synced) {
          _elapsed = position;
          _elapsedStamp = DateTime.now();
        }
      });
      _audioCompleteSub = player.onPlayerComplete.listen((_) => _audioEnded());
      setState(() {
        _audioPlayer = player;
        _audioReady = true;
      });
      // If playback was already started (Play tapped before this finished
      // loading), the audio needs to catch up now rather than sitting
      // loaded-but-silent until the next play/pause toggle.
      if (_playing) unawaited(player.resume());
    } catch (_) {
      // Non-fatal: Live mode falls back to manual scroll speeds with no
      // audio, same as before this was added.
    } finally {
      // Either way, a part kept from last time may now be put back.
      if (!_referenceReady.isCompleted) _referenceReady.complete();
    }
  }

  void _selectSource(LiveLyricSource source) {
    if (source == _source) return;
    _takeOver();
    _switchSource(source);
  }

  void _switchSource(LiveLyricSource source) {
    _cancelCountdown();
    final audio = _audioPlayer;
    if (audio != null) {
      unawaited(audio.pause());
      unawaited(audio.seek(Duration.zero));
    }
    setState(() {
      _source = source;
      _playing = false;
      _loop = null;
      _mode = _hasSync ? LiveScrollMode.synced : LiveScrollMode.off;
      _elapsed = Duration.zero;
      _activeLineKey = null;
    });
    _lastTick = null;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _markOffsetsDirty();
  }

  @override
  void dispose() {
    // Closing the song keeps what was worked on, quietly: the ending the
    // session sends after this screen is gone has nobody left to hear it, and
    // a solo session has nothing to announce the end of at all. Both marks
    // are built now and handed over after the frame -- Home listens to where
    // they go.
    final together = widget.together;
    PracticeMark? closing;
    if (together != null) {
      together.removeListener(_togetherChanged);
      if (together.following) {
        _practice.pause(_practiceNow());
        closing = _practiceMark();
      }
    }
    _own.pause(_ownAtMs);
    final ownClosing = _ownMark();
    final keep = widget.keepPractice;
    // After this frame: the song underneath listens to the session, and
    // telling it anything while this screen is being taken down would ask
    // a locked tree to rebuild.
    scheduleMicrotask(() {
      if (closing != null) keep?.call(closing);
      if (ownClosing != null) keep?.call(ownClosing);
      together?.stopLeading();
      together?.unfollow();
    });
    unawaited(_followSub?.cancel());
    unawaited(_noteSub?.cancel());
    unawaited(_endSub?.cancel());
    _ticker?.cancel();
    _hideControls?.cancel();
    _countdownTimer?.cancel();
    // Only if a song ever needed counting in: the click makes an audio player
    // the first time it is asked for, and most songs never ask.
    final click = _clickPlayer;
    if (click != null) {
      unawaited(click.stop().then((_) => click.dispose()));
    }
    _ear?.reading.removeListener(_earChanged);
    _ear?.dispose();
    _scroll.dispose();
    unawaited(_audioPositionSub?.cancel());
    unawaited(_audioCompleteSub?.cancel());
    unawaited(_audioPlayer?.dispose());
    // The part mix under the words, if there was one: a whole song as WAV
    // that nothing will play again. The stems' mix stays -- PlayAlong keeps
    // that one on purpose, under a name it finds again next time.
    final partMix = _lastPartMixPath;
    if (partMix != null) unawaited(_deleteQuietly(partMix));
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

  /// Bigger or smaller words, without losing the line you are on.
  ///
  /// The words are laid out again at the new size, which moves every line to
  /// a different pixel, and the scroll offset did not move with them -- so
  /// the song jumped somewhere else the moment the button was pressed. The
  /// line under the anchor is remembered first and put back on the anchor
  /// after the re-measure; a sheet with no measured lines falls back to
  /// holding the same fraction of the way through.
  void _setFontScale(double next) {
    final scale = next.clamp(0.72, 1.35).toDouble();
    if (scale == _fontScale) return;
    final anchored = _lineOnAnchor();
    final position = _scroll.hasClients ? _scroll.position : null;
    final through = position != null && position.maxScrollExtent > 0
        ? position.pixels / position.maxScrollExtent
        : 0.0;

    setState(() => _fontScale = scale);

    // After the build that this triggers, and after the re-measure that
    // build asks for.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _captureLineOffsets();
      final maxExtent = _scroll.position.maxScrollExtent;
      final offset = anchored == null ? null : _lineOffsets[anchored];
      final target = offset != null
          ? scrollToPutLineAtAnchor(
              lineOffset: offset,
              viewportHeight: _viewportHeight,
              maxExtent: maxExtent,
            )
          : (through * maxExtent).clamp(0.0, maxExtent).toDouble();
      _scroll.jumpTo(target);
    });
  }

  /// The line sitting on the anchor: the one being sung when the song is
  /// following itself, and otherwise whichever line is nearest to it.
  String? _lineOnAnchor() {
    final active = _activeLineKey;
    if (active != null && _lineOffsets.containsKey(active)) return active;
    if (!_scroll.hasClients || _lineOffsets.isEmpty) return null;
    final at = _scroll.position.pixels + _viewportHeight * kSingingLineFraction;
    String? nearest;
    var best = double.infinity;
    for (final entry in _lineOffsets.entries) {
      final distance = (entry.value - at).abs();
      if (distance < best) {
        best = distance;
        nearest = entry.key;
      }
    }
    return nearest;
  }

  void _markOffsetsDirty() {
    _offsetsDirty = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _captureLineOffsets();
    });
  }

  void _tick() {
    // Leading: offered every tick, sent only when it says something new.
    final together = widget.together;
    if (together != null && together.leading) together.publish(_followStateNow());
    // Before the returns below: a tick where nothing is playing is what ends
    // a stretch of practice, and it has to be seen for that.
    _logOwnPractice();
    if (!_playing || !_scroll.hasClients) {
      _lastTick = null;
      return;
    }
    // When real audio is playing in synced mode, _elapsed is kept current by
    // the player's own onPositionChanged stream (see _prepareAudio) — that's
    // the actual clock the user hears, so this tick must not also advance it
    // by wall-clock time on top of that or the two would drift apart.
    final audioIsClock = _audioPlayer != null && _mode == LiveScrollMode.synced;
    var delta = Duration.zero;
    if (!audioIsClock) {
      final now = DateTime.now();
      final previous = _lastTick ?? now;
      _lastTick = now;
      delta = now.difference(previous);
      if (delta <= Duration.zero) return;
      _elapsed += _mode == LiveScrollMode.synced ? atRate(delta, _rate) : delta;
    }

    if (_offsetsDirty && _mode == LiveScrollMode.synced) _captureLineOffsets();

    final position = _scroll.position;
    final maxExtent = position.maxScrollExtent;
    if (maxExtent <= 0) return;

    if (_mode == LiveScrollMode.synced) {
      _tickSynced(position, maxExtent);
      return;
    }

    // Scaled by the size of the words, because the speeds below are read in
    // lines per minute and stored in pixels per second. Make the words a
    // third bigger and every line is a third taller, so an unscaled speed
    // reads a third slower and the song runs away from the player -- which
    // is what "it no longer scrolls properly after the plus button" was.
    // Timed mode is already told the distance and the time, so it needs no
    // scaling: it re-derives its own speed from what is left of both.
    final pixelsPerSecond = switch (_mode) {
      LiveScrollMode.slow => 9.5 * _fontScale,
      LiveScrollMode.medium => 17.0 * _fontScale,
      LiveScrollMode.fast => 27.0 * _fontScale,
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

  /// Keys a line the same way _lineKeys/_lineOffsets do, so both the
  /// timing math below and the widget build loop always agree on identity
  /// even for generated lines with no backing Contribution.
  String _lineKey(int index) => _lines[index].contributionId ?? 'line_$index';

  void _tickSynced(ScrollPosition position, double maxExtent) {
    // Past the end of the part on repeat: back to its start, recording and
    // all. Checked here rather than in the player's position stream so a
    // sheet with no recording loops too.
    final loop = _loop;
    if (loop != null && _elapsed.inMilliseconds >= loop.endMs) {
      _seekTo(keepInside(_elapsed, loop));
    }
    final elapsedMs = _elapsed.inMilliseconds;
    final lines = _lines;
    if (lines.isEmpty) {
      setState(() => _playing = false);
      _lastTick = null;
      return;
    }

    final target = _syncedScrollTarget(lines, elapsedMs, maxExtent);
    if (target != null && (target - position.pixels).abs() > 0.01) {
      position.jumpTo(target.clamp(0.0, maxExtent));
    }

    final nextActiveKey = _lineKeyAt(lines, elapsedMs);
    final songEndMs = _songDuration.inMilliseconds;
    final finished = songEndMs > 0 ? elapsedMs >= songEndMs : elapsedMs >= lines.last.endMs;

    if (finished) {
      position.jumpTo(maxExtent);
      setState(() {
        _playing = false;
        _activeLineKey = nextActiveKey;
      });
      _lastTick = null;
    } else if (mounted) {
      setState(() => _activeLineKey = nextActiveKey);
    }
  }

  /// Finds the key of the line that should be highlighted as "currently
  /// sung" at [elapsedMs].
  String? _lineKeyAt(List<MusicianSheetLine> lines, int elapsedMs) {
    String? current;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].startMs <= elapsedMs) {
        current = _lineKey(i);
      } else {
        break;
      }
    }
    return current;
  }

  /// Maps [elapsedMs] to a scroll pixel offset by interpolating between the
  /// measured positions of the surrounding timed lines. This keeps the
  /// current line in view and naturally slows through instrumental gaps
  /// instead of assuming lyrics are spread evenly through the song.
  double? _syncedScrollTarget(List<MusicianSheetLine> lines, int elapsedMs, double maxExtent) {
    if (_lineOffsets.isEmpty) return null;

    double? offsetFor(int index) => _lineOffsets[_lineKey(index)];

    // Every line-derived target is measured from the top of the content and
    // then lifted onto the anchor, so the words being sung sit a little above
    // the middle instead of against the top edge. See kSingingLineFraction.
    double onAnchor(double offset) => scrollToPutLineAtAnchor(
          lineOffset: offset,
          viewportHeight: _viewportHeight,
          maxExtent: maxExtent,
        );

    // Before the first line: hold at the top of it.
    if (elapsedMs <= lines.first.startMs) {
      return onAnchor(offsetFor(0) ?? 0);
    }
    // After the last line: settle at the very bottom.
    final last = lines.last;
    if (elapsedMs >= last.endMs) {
      return maxExtent;
    }

    for (var i = 0; i < lines.length - 1; i++) {
      final current = lines[i];
      final next = lines[i + 1];
      if (elapsedMs >= current.startMs && elapsedMs < next.startMs) {
        final currentOffset = offsetFor(i);
        final nextOffset = offsetFor(i + 1);
        if (currentOffset == null || nextOffset == null) {
          final known = currentOffset ?? nextOffset;
          return known == null ? null : onAnchor(known);
        }
        final span = next.startMs - current.startMs;
        if (span <= 0) return onAnchor(currentOffset);
        final progress = (elapsedMs - current.startMs) / span;
        return onAnchor(
          currentOffset + (nextOffset - currentOffset) * progress.clamp(0.0, 1.0),
        );
      }
    }
    final lastOffset = offsetFor(lines.length - 1);
    return lastOffset == null ? maxExtent : onAnchor(lastOffset);
  }

  /// How tall the words are on screen right now, for the anchor above.
  double get _viewportHeight =>
      _scroll.hasClients ? _scroll.position.viewportDimension : 0;

  double _timedPixelsPerSecond(double maxExtent) {
    final remainingTime = _songDuration - _elapsed;
    if (remainingTime <= Duration.zero) return maxExtent;
    final remainingPixels = math.max(0.0, maxExtent - _scroll.position.pixels).toDouble();
    return remainingPixels / (remainingTime.inMilliseconds / 1000);
  }

  void _armControlHide() {
    _hideControls?.cancel();
    if (!_playing || _practising) return;
    _hideControls = Timer(const Duration(seconds: 4), () {
      if (mounted && _playing) setState(() => _controlsVisible = false);
    });
  }

  void _showControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _armControlHide();
  }

  /// Entry point from the play button — inserts the count-in before actually
  /// starting playback (if enabled), rather than starting the scroll/sync
  /// instantly. Pausing, and tapping play again mid-countdown to cancel it,
  /// both skip straight to _togglePlay.
  ///
  /// Two counts, because a count-in is two different things. A song the
  /// analysis found a beat in is counted in on its own bar, at its own tempo
  /// and at whatever speed it is about to play at. A song with no beat keeps
  /// the seconds, which promise nothing about the song (Every Musician, Same
  /// Song, 17 September 2026).
  void _onPlayPressed() {
    _takeOver();
    if (_countdownRemaining != null || _countInBar != null) {
      _cancelCountdown();
      return;
    }
    if (!_playing && _countdownEnabled) {
      // The metre is counted from bar 1, so a count-in left on the front of
      // the recording cannot decide how many beats are in a bar of the song
      // it is counting into (0161).
      final countIn = countInForSong(
        widget.analysis?.reference,
        rate: _rate,
        barOne: _barOne,
      );
      if (countIn == null) {
        _startCountdown();
      } else {
        unawaited(_startCountIn(countIn));
      }
      return;
    }
    _togglePlay();
  }

  /// One bar of the song, counted out loud, seen and felt.
  ///
  /// The bar of clicks is one file, so the beats inside it are exactly where
  /// the tempo puts them; a click fired from a timer drifts by however long
  /// each play call takes. It is started first and waited for, and the dots
  /// and the haptics run from a timer alongside it — a count you can see a
  /// beat away from the one you can hear is worse than either on its own.
  ///
  /// The song comes in one whole bar after the first beat of the count, which
  /// is the beat after the last one counted — but only if the song is sitting
  /// on a downbeat when it comes in, which [_startOnADownbeat] is what makes
  /// true.
  Future<void> _startCountIn(CountIn countIn) async {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    final generation = ++_countInGeneration;
    setState(() {
      _startOnADownbeat();
      _countInBar = countIn;
      _countInBeat = null;
    });
    try {
      await _click.play(
        bpm: countIn.bpm,
        beatsPerBar: countIn.beats,
        bars: 1,
        loop: false,
      );
    } catch (_) {
      // No click on this device, or no audio at all. The bar is still
      // counted, seen and felt — a silent count-in beats no count-in.
    }
    // Tapped again, or left, while the click was being prepared.
    if (!mounted || generation != _countInGeneration) return;
    setState(() => _countInBeat = 1);
    _feelBeat();
    _countdownTimer = Timer.periodic(countIn.beat, (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final next = (_countInBeat ?? 0) + 1;
      if (next > countIn.beats) {
        timer.cancel();
        _countdownTimer = null;
        setState(() {
          _countInBar = null;
          _countInBeat = null;
        });
        _togglePlay();
        return;
      }
      setState(() => _countInBeat = next);
      _feelBeat();
    });
  }

  /// Moves the song back to the start of the bar it is sitting in, so the
  /// count hands over onto a real one.
  ///
  /// Four beats at the song's tempo are only a count-in if the song's own
  /// beats fall where they say they will. Paused halfway through a bar at
  /// 0:41.300 and started again, the count would be at the right speed and in
  /// the wrong place: the song would arrive three tenths after the beat the
  /// player was just counted to. Coming back in from the top of the bar is
  /// what anybody in a room says out loud anyway.
  ///
  /// Only where the song's own clock is what the play button starts. In the
  /// scrolling modes the scroll is the clock and there is no recording to be
  /// in phase with, so there is nothing to move. And before the first
  /// downbeat — a pickup, or the top of a song that starts a moment before
  /// its own one — nothing moves either: the song begins there, and there is
  /// no earlier bar it could be taken from.
  void _startOnADownbeat() {
    final synced = _mode == LiveScrollMode.synced ||
        (_mode == LiveScrollMode.off && _hasSync);
    if (!synced) return;
    final at = _elapsed.inMilliseconds;
    final downbeat = downbeatAtOrBefore(at, _downbeats);
    if (downbeat == null || downbeat == at) return;
    // Never out of the front of what is on repeat: the loop's start is where
    // the player said this passage begins.
    final loop = _loop;
    if (loop != null && downbeat < loop.startMs) return;
    _seekTo(Duration(milliseconds: downbeat));
  }

  /// A light tick on each beat of the count.
  ///
  /// So the bar can be felt with the phone on a stand and both eyes on the
  /// instrument, which is where they are in the four beats before a song.
  /// Nothing on a device with no motor, and never allowed to fail a count-in.
  void _feelBeat() {
    unawaited(HapticFeedback.selectionClick().catchError((Object _) {}));
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    setState(() => _countdownRemaining = _countdownSeconds);
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final next = (_countdownRemaining ?? 1) - 1;
      if (next <= 0) {
        timer.cancel();
        _countdownTimer = null;
        if (!mounted) return;
        setState(() => _countdownRemaining = null);
        _togglePlay();
        return;
      }
      if (!mounted) return;
      setState(() => _countdownRemaining = next);
    });
  }

  void _cancelCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    // Also disowns a bar count-in whose click is still being written, so it
    // cannot start counting a song somebody has already moved on from.
    _countInGeneration += 1;
    unawaited(_clickPlayer?.stop());
    if (mounted) {
      setState(() {
        _countdownRemaining = null;
        _countInBar = null;
        _countInBeat = null;
      });
    }
  }

  void _togglePlay() {
    final audio = _audioPlayer;
    setState(() {
      if (_mode == LiveScrollMode.off) {
        _mode = _hasSync ? LiveScrollMode.synced : LiveScrollMode.medium;
      }
      _playing = !_playing;
      _controlsVisible = true;
    });
    if (_mode == LiveScrollMode.synced) _markOffsetsDirty();
    _lastTick = null;
    if (audio != null) {
      unawaited(_playing ? audio.resume() : audio.pause());
    }
    _armControlHide();
  }

  void _restart() {
    _takeOver();
    _cancelCountdown();
    if (_scroll.hasClients) _scroll.jumpTo(0);
    final audio = _audioPlayer;
    if (audio != null) {
      unawaited(audio.seek(Duration.zero));
      unawaited(audio.pause());
    }
    setState(() {
      _elapsed = Duration.zero;
      _playing = false;
      _loop = null;
      _controlsVisible = true;
      _activeLineKey = null;
    });
    _lastTick = null;
  }

  Future<void> _chooseTimedDuration() async {
    final result = await showModalBottomSheet<Duration>(
      context: context,
      backgroundColor: AppColors.deepNavy,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => _DurationSheet(initial: _songDuration),
    );
    if (result == null || !mounted) return;
    final audio = _audioPlayer;
    if (audio != null) {
      unawaited(audio.seek(Duration.zero));
      unawaited(audio.pause());
    }
    setState(() {
      _songDuration = result;
      _elapsed = Duration.zero;
      _mode = LiveScrollMode.timed;
      _playing = false;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _selectMode(LiveScrollMode mode) {
    _takeOver();
    _cancelCountdown();
    if (mode == LiveScrollMode.timed) {
      unawaited(_chooseTimedDuration());
      return;
    }
    final audio = _audioPlayer;
    if (audio != null) {
      unawaited(audio.seek(Duration.zero));
      if (mode == LiveScrollMode.off) unawaited(audio.pause());
    }
    setState(() {
      _mode = mode;
      if (mode == LiveScrollMode.off) _playing = false;
      _loop = null;
      _elapsed = Duration.zero;
      _activeLineKey = null;
    });
    _lastTick = null;
    if (mode == LiveScrollMode.synced) _markOffsetsDirty();
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// Moves the song, and the recording with it.
  ///
  /// Synced mode only: in the manual modes the scroll is the clock and there
  /// is nothing to seek. The active line is cleared so the next tick finds
  /// the right one rather than fading between two.
  void _seekTo(Duration where) {
    _elapsed = where;
    _elapsedStamp = DateTime.now();
    _activeLineKey = null;
    final audio = _audioPlayer;
    if (audio != null) unawaited(audio.seek(where));
  }

  /// The recording reached its own end.
  ///
  /// Normally that is the song finishing. But a loop over the last bar ends
  /// where the recording does (see barEndMs), and in synced mode the player's
  /// position stream is the clock -- its final event lands a little short of
  /// the duration, so the tick never sees the loop's end go by and the turn
  /// round has to happen here instead. Without this, the one run of bars a
  /// player drills most, the ending, is the one that stops dead every time.
  void _audioEnded() {
    if (!mounted) return;
    final loop = _loop;
    if (_playing && loop != null && _mode == LiveScrollMode.synced) {
      setState(() => _seekTo(Duration(milliseconds: loop.startMs)));
      _lastTick = null;
      unawaited(_audioPlayer?.resume());
      return;
    }
    setState(() => _playing = false);
  }

  void _onSeek(Duration where) {
    _takeOver();
    setState(() {
      _seekTo(where);
      _controlsVisible = true;
    });
    _lastTick = null;
    _armControlHide();
  }

  void _setRate(double rate) {
    _takeOver();
    setState(() {
      _rate = rate;
      _controlsVisible = true;
    });
    final audio = _audioPlayer;
    if (audio != null) unawaited(audio.setPlaybackRate(rate));
    _armControlHide();
  }

  void _earChanged() {
    if (mounted) setState(() {});
  }

  /// Play along with everyone but you, or with everyone again.
  ///
  /// The mix is one file (see PlayAlong), built the first time a part is
  /// left out and kept, then swapped in under the player at the moment the
  /// song is at -- paused or playing, at whatever speed -- so the words do
  /// not jump. Tapping the chosen part again puts the whole recording back.
  Future<void> _setWithout(StemKind kind) async {
    if (_mixing) return;
    final stems = widget.analysis?.stems ?? const <SongStem>[];
    final leaving = _without == kind;
    setState(() {
      _mixing = true;
      _mixNote = leaving ? 'Everyone back in…' : 'Mixing the band without the ${kind.label.toLowerCase()}…';
      _controlsVisible = true;
    });
    try {
      final String path;
      if (leaving) {
        final reference = _referencePath;
        if (reference == null) throw StateError('The recording has not loaded yet.');
        path = reference;
      } else {
        final mixer = widget.playAlongMixer ?? _defaultMixer;
        path = await mixer(stems, kind, (stage) {
          if (mounted) setState(() => _mixNote = stage);
        });
      }
      if (!mounted) return;
      await _swapAudio(path);
      if (!mounted) return;
      setState(() {
        _without = leaving ? null : kind;
        _mixNote = null;
        // A part left out of the stems replaces a take that was forward:
        // both decide what is under the words, and it is one file.
        if (_myPart != null) {
          _myPart = null;
          unawaited(MyPartStore.save(widget.project.id, null));
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() => _mixNote = reportAndDescribe(error,
            service: 'app', stage: 'play_along.mix', route: 'Perform'));
      }
    } finally {
      if (mounted) setState(() => _mixing = false);
      _armControlHide();
    }
  }

  static Future<String> _defaultMixer(
    List<SongStem> stems,
    StemKind without,
    void Function(String stage) onProgress,
  ) async {
    final directory = await getTemporaryDirectory();
    return PlayAlong.mixWithout(
      stems: stems,
      without: without,
      ensureLocalStem: SongAnalysisService().ensureLocalStem,
      directory: directory.path,
      onProgress: onProgress,
    );
  }

  /// Not a uuid, so it can never collide with a real take's id. The same
  /// name the takes screen gives the song's own recording.
  static const String _referenceTakeId = 'reference';

  /// The song's own recording as a take, the way the takes screen mixes it.
  Take _referenceTake(ReferenceTrack reference,
      {required String path, required double level}) {
    return Take(
      id: _referenceTakeId,
      path: path,
      label: reference.displayName,
      recordedAt: DateTime.now(),
      durationMs: reference.durationMs ?? 0,
      gain: level,
      part: TakePart.other,
      namedByHand: true,
    );
  }

  /// The takes that can be somebody's part, which is what the chips are
  /// built from. See MyPartMix.offered.
  ///
  /// The paths are the local copies where there are any and empty where
  /// there are none yet: a chip needs only the name, and the mix fetches
  /// what it needs when a part is chosen. None in a browser, which has no
  /// file to write a mix to -- the same floor the takes screen stands on.
  List<Take> get _partTakes {
    if (kIsWeb) return const <Take>[];
    final reference = widget.analysis?.reference;
    final takes = <Take>[
      if (reference != null)
        _referenceTake(reference, path: _referencePath ?? '', level: 1),
      for (final layer in _layers)
        // Not a turn of a round: it is not a part somebody plays through the
        // song, it is one of several goes at the same few bars, and a chip
        // for each would offer to bring one of them forward over the rest.
        if (!_turns.contains(layer.id))
          layer.toTake(_localTakes[layer.id] ?? '', enabled: true),
    ];
    return MyPartMix.offered(takes, referenceId: _referenceTakeId);
  }

  String _partName(String takeId) {
    for (final take in _partTakes) {
      if (take.id == takeId) return TakeNaming.partAndPerson(take);
    }
    return 'that part';
  }

  /// The song's takes, listed once the screen is up, and the part this
  /// person was listening for last time, put back once the recording is in.
  ///
  /// Best-effort: a song whose takes will not load still performs, with no
  /// chips and no sentence about it. The words are what this screen is for.
  Future<void> _loadTakes() async {
    final List<SharedLayer> layers;
    try {
      layers = await _layerService.listLayers(widget.project.id);
    } catch (_) {
      return;
    }
    // Which of them are turns, on the same terms as the takes: a song whose
    // rounds will not load still performs. Read before the first mix is
    // built, because it decides what goes in one.
    final turns = await _readTurns();
    final kept = await MyPartStore.load(widget.project.id);
    if (!mounted) return;
    setState(() {
      _layers = layers;
      _turns = turns;
    });
    if (kept == null || !_partTakes.any((take) => take.id == kept.takeId)) return;
    await _referenceReady.future;
    // Somebody was quicker than the recording, or the recording never came:
    // a song that plays as it did before any of this is not a fault to
    // report on a screen nobody has asked anything of.
    if (!mounted || _myPart != null || _without != null) return;
    if (widget.analysis?.reference != null && _referencePath == null) return;
    await _setMyPart(kept);
  }

  /// The takes that are turns of a round on this song, or none when there
  /// is no repository above this screen (a widget test) or the rounds will
  /// not load. Never throws: see [_loadTakes].
  Future<Set<String>> _readTurns() async {
    if (!mounted) return const <String>{};
    final repository = BetaScope.maybeOf(context, listen: false)?.repository;
    if (repository == null) return const <String>{};
    try {
      return TakeTurns.turnIds(
          await repository.loadLoopRounds(widget.project.id));
    } catch (_) {
      return const <String>{};
    }
  }

  /// Every take as this listener hears it, each one local, with the song's
  /// own recording first at the level this person keeps for it -- which is
  /// theirs as well (SongLevelStore). The room's levels are read here and
  /// never written.
  Future<List<Take>> _takesForMix(MyPart? choice) async {
    final reference = widget.analysis?.reference;
    final takes = <Take>[];
    if (reference != null) {
      final path = _referencePath;
      if (path == null) throw StateError('The recording could not be loaded.');
      takes.add(_referenceTake(reference,
          path: path, level: await SongLevelStore.load(widget.project.id)));
    }
    for (final layer in _layers) {
      // A turn of a round is not fetched and not switched on. The mixer
      // skips a take that is off, so it needs no file -- and nobody should
      // pay for downloading a solo they are not going to hear.
      if (_turns.contains(layer.id)) {
        takes.add(layer.toTake(_localTakes[layer.id] ?? '', enabled: false));
        continue;
      }
      var local = _localTakes[layer.id];
      if (local == null) {
        final name = TakeNaming.partAndPerson(layer.toTake('', enabled: true));
        if (mounted) setState(() => _mixNote = 'Fetching $name…');
        local = await _layerService.ensureLocal(layer);
        _localTakes[layer.id] = local;
      }
      takes.add(layer.toTake(local, enabled: true));
    }
    return MyPartMix.apply(takes, choice);
  }

  /// Your part forward, or everyone but you -- or, tapped again, the whole
  /// recording.
  ///
  /// The mix is one file (see Multitrack: players drift, a file cannot),
  /// written from the takes at the levels the room set with this person's
  /// choice on top, and swapped in under the player at the moment the song
  /// is at, exactly as a part left out is. On a song with no recording of
  /// its own, going back means the takes as the room mixed them.
  Future<void> _setMyPart(MyPart choice) async {
    if (_mixing) return;
    final leaving = _myPart == choice;
    setState(() {
      _mixing = true;
      _mixNote = leaving
          ? 'Everyone back in…'
          : '${choice.label(_partName(choice.takeId))}…';
      _controlsVisible = true;
    });
    try {
      // The chips are up as soon as the list of takes is, which can be
      // before the recording has come down. A tap then waits for it rather
      // than being told it is not here yet: _mixing keeps a second tap out
      // meanwhile, and the note above says which part is on its way.
      await _referenceReady.future;
      final String path;
      if (leaving && widget.analysis?.reference != null) {
        final reference = _referencePath;
        if (reference == null) throw StateError('The recording could not be loaded.');
        path = reference;
      } else {
        final mixer = widget.partMixer ?? _defaultPartMixer;
        path = await mixer(await _takesForMix(leaving ? null : choice), (stage) {
          if (mounted) setState(() => _mixNote = stage);
        });
      }
      if (!mounted) return;
      await _swapAudio(path);
      if (!mounted) return;
      setState(() {
        _myPart = leaving ? null : choice;
        _without = null;
        _mixNote = null;
      });
      unawaited(MyPartStore.save(widget.project.id, _myPart));
    } catch (error) {
      if (mounted) {
        setState(() => _mixNote = reportAndDescribe(error,
            service: 'app', stage: 'my_part.mix', route: 'Perform'));
      }
    } finally {
      if (mounted) setState(() => _mixing = false);
      _armControlHide();
    }
  }

  /// A new file every time, for the reason the takes screen learned the
  /// hard way: audioplayers keys its cache on the path, so one name
  /// rewritten plays the first mix ever built under it. The one before is
  /// deleted once the new one exists.
  Future<String> _defaultPartMixer(
    List<Take> takes,
    void Function(String stage) onProgress,
  ) async {
    final directory = await getTemporaryDirectory();
    if (!_sweptOldPartMixes) {
      _sweptOldPartMixes = true;
      await _sweepOldPartMixes(directory);
    }
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final path = '${directory.path}/colabroom_mypart_${widget.project.id}_$stamp.wav';
    onProgress('Mixing…');
    final result = await Multitrack.writeMixdown(takes: takes, outputPath: path);
    if (result == null) throw StateError('None of the parts could be read.');
    final previous = _lastPartMixPath;
    _lastPartMixPath = path;
    if (previous != null) await _deleteQuietly(previous);
    return path;
  }

  bool _sweptOldPartMixes = false;

  /// Part mixes left behind by earlier visits, which nothing will play
  /// again. Each is a whole song as WAV, and the last one built survived
  /// the screen being closed, so one song a visit was quietly filling the
  /// phone. Swept the way the takes screen sweeps its own, the first time
  /// there is a mix to write; a mix this screen is playing is left alone.
  Future<void> _sweepOldPartMixes(Directory directory) async {
    try {
      await for (final entry in directory.list()) {
        if (entry is! File) continue;
        final name = entry.uri.pathSegments.last;
        if (!name.startsWith('colabroom_mypart_') || !name.endsWith('.wav')) continue;
        if (entry.path == _lastPartMixPath) continue;
        await entry.delete();
      }
    } catch (_) {
      // Clutter, not a failure worth showing anybody.
    }
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      final stale = File(path);
      if (await stale.exists()) await stale.delete();
    } catch (_) {
      // Clutter in a temporary directory, not a failure worth a sentence.
    }
  }

  /// Puts [path] under the player at the current moment, keeping the speed
  /// and whether it was playing.
  Future<void> _swapAudio(String path) async {
    var player = _audioPlayer;
    final wasPlaying = _playing;
    if (player == null) {
      player = AudioPlayer();
      _audioPositionSub = player.onPositionChanged.listen((position) {
        if (_playing && _mode == LiveScrollMode.synced) {
          _elapsed = position;
          _elapsedStamp = DateTime.now();
        }
      });
      _audioCompleteSub = player.onPlayerComplete.listen((_) => _audioEnded());
      _audioPlayer = player;
    } else {
      await player.pause();
    }
    await player.setSource(audioSourceFor(path));
    await player.seek(_elapsed);
    if (_rate != 1) await player.setPlaybackRate(_rate);
    if (mounted) setState(() => _audioReady = true);
    if (wasPlaying) await player.resume();
  }

  /// Sing along, or stop.
  ///
  /// Opens the same ear the tuner uses, with the same disclosure -- nothing
  /// is recorded and nothing leaves the phone -- and from then on the bar
  /// shows the note being sung beside the note the song is on. The
  /// microphone is only ever opened from this tap, never on entering the
  /// screen: a page that listens to you the moment it opens is a different
  /// kind of page.
  Future<void> _toggleSinging() async {
    if (_singing) {
      await _ear?.stop();
      if (!mounted) return;
      setState(() {
        _singing = false;
        _controlsVisible = true;
      });
      _armControlHide();
      return;
    }
    final ear = _ear ??= PitchListener(openStream: widget.openMicrophone)
      ..reading.addListener(_earChanged);
    try {
      await ear.start(
        allowed: () => MicrophoneAccess.ensureGranted(
          context,
          purpose: 'to hear the note you are singing',
          request: ear.hasPermission,
          use: MicrophoneUse.listen,
        ),
        onError: (Object error) {
          if (mounted) {
            setState(() => _singError = reportAndDescribe(error,
                service: 'app', stage: 'sing.stream', route: 'Perform'));
          }
        },
      );
      if (!mounted) return;
      setState(() {
        _singing = true;
        _singError = null;
        _controlsVisible = true;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _singError = reportAndDescribe(error,
            service: 'app', stage: 'sing.open', route: 'Perform'));
      }
    }
    _armControlHide();
  }

  /// Loop one part or one run of bars, or stop looping.
  ///
  /// Choosing what is already on repeat is the way out; anything else jumps
  /// there and stays there, playing or paused. Paused, the sheet still moves
  /// to it so the next press of Start begins where the eye is.
  void _setLoop(PracticeLoop loop) {
    _takeOver();
    _cancelCountdown();
    final same = loop == _loop;
    setState(() {
      _loop = same ? null : loop;
      _controlsVisible = true;
      if (_mode == LiveScrollMode.off && _hasSync) _mode = LiveScrollMode.synced;
    });
    if (!same) {
      _seekTo(Duration(milliseconds: loop.startMs));
      if (_mode == LiveScrollMode.synced) {
        _markOffsetsDirty();
        if (!_playing) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_scroll.hasClients) return;
            final position = _scroll.position;
            final maxExtent = position.maxScrollExtent;
            if (maxExtent > 0) _tickSynced(position, maxExtent);
          });
        }
      }
    }
    _lastTick = null;
    _armControlHide();
  }

  /// "From B": the song jumps to that part and plays on through it.
  ///
  /// A loop comes off, because the sentence is "from B", not "B again" —
  /// somebody asking for a letter is asking to run the song from there, and
  /// a repeat still on would pull them back into the part they just left
  /// (Every Musician, Same Song, 17 September 2026). "B again" is the loop
  /// chip, which is a tap away in the same row.
  ///
  /// Playing or paused, the same as choosing a part to loop: paused, the
  /// words still move so the next press of Start begins where the eye is.
  ///
  /// Nothing new is needed for this to reach a room that is following. Follow
  /// me carries where the song is and what is on repeat, and this changes
  /// both; the next heartbeat takes it, exactly as a section jump has always
  /// travelled (see _followStateNow and worthSending).
  void _jumpToLetter(RehearsalLetter letter) {
    _takeOver();
    _cancelCountdown();
    final at = sectionDownbeatMs(letter.startMs, _downbeats);
    setState(() {
      _loop = null;
      _controlsVisible = true;
      if (_mode == LiveScrollMode.off && _hasSync) _mode = LiveScrollMode.synced;
      _seekTo(Duration(milliseconds: at));
    });
    if (_mode == LiveScrollMode.synced) {
      _markOffsetsDirty();
      if (!_playing) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scroll.hasClients) return;
          final position = _scroll.position;
          final maxExtent = position.maxScrollExtent;
          if (maxExtent > 0) _tickSynced(position, maxExtent);
        });
      }
    }
    _lastTick = null;
    _armControlHide();
  }

  /// Pick the bars to put on repeat.
  ///
  /// It opens on the bars the song is sitting in rather than on bar 1, so
  /// parking on the passage that will not come out and pressing Bars offers
  /// that passage. Four bars is the phrase a teacher hands out when they
  /// hand one out.
  void _openBarLoop() {
    final downbeats = _downbeats;
    if (downbeats.length < 2) return;
    _showControls();
    final current = _loop;
    final bars = numberedBarCount(_barOne, downbeats.length);
    final here =
        barNumberAt(_elapsedNow.inMilliseconds, downbeats, barOne: _barOne) ?? 1;
    unawaited(showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.deepNavy,
      showDragHandle: true,
      // The sheet takes the height its own content needs. Left to the default
      // it is capped at nine sixteenths of the screen, which on the phone in
      // landscape this screen is built for cuts the bottom off the button
      // that starts the loop.
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => _BarLoopSheet(
        barCount: bars,
        firstBar: current?.firstBar ?? here,
        lastBar: current?.lastBar ?? math.min(here + 3, bars),
        looping: current?.isBars ?? false,
        hasPickup: pickupLoop(downbeats, barOne: _barOne) != null,
        barOneSaid: _barOneSaid != null,
        // The sheet counts in printed bar numbers; the song is told in
        // downbeats, which is the one thing that does not move when bar 1
        // does. Null goes straight through: it is "use the detected bars".
        onSayBarOne: widget.onSayBarOne == null
            ? null
            : (bar) {
                Navigator.of(sheetContext).pop();
                unawaited(_sayBarOne(bar == null
                    ? null
                    : downbeatIndexOfBar(bar, _barOne, downbeats.length) + 1));
              },
        onPickup: () {
          Navigator.of(sheetContext).pop();
          final pickup = pickupLoop(downbeats, barOne: _barOne);
          if (pickup != null && pickup != _loop) _setLoop(pickup);
        },
        onChoose: (first, last) {
          Navigator.of(sheetContext).pop();
          final chosen = barLoop(
            firstBar: first,
            lastBar: last,
            downbeatsMs: downbeats,
            songEndMs: _recordingEndMs,
            barOne: _barOne,
          );
          if (chosen == null) return;
          // Named the way it will be named when it comes back from a
          // heartbeat or a practice mark, so bars that happen to be exactly
          // the chorus say Chorus on the way in as well as on the way back.
          final loop = _loopFor(chosen.startMs, chosen.endMs) ?? chosen;
          if (loop != _loop) _setLoop(loop);
        },
        onStop: () {
          Navigator.of(sheetContext).pop();
          final on = _loop;
          if (on != null) _setLoop(on);
        },
      ),
    ));
  }

  /// "This is bar 1", from the bar picker, or the detected bars put back.
  ///
  /// The numbers on this screen move first and the write follows, because
  /// the person is looking at a picker that has to answer the tap. A refusal
  /// puts them back: the room is where this is decided, and a screen that
  /// kept counting from a bar 1 the room refused would be lying quietly.
  Future<void> _sayBarOne(int? downbeat) async {
    final write = widget.onSayBarOne;
    if (write == null) return;
    final before = _barOneSaid;
    setState(() {
      _barOneSaid = downbeat;
      // Whatever was on repeat was named in the old numbering, and its bars
      // are not the same bars any more.
      _loop = _loopFor(_loop?.startMs, _loop?.endMs);
    });
    try {
      await write(downbeat);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _barOneSaid = before;
        _loop = _loopFor(_loop?.startMs, _loop?.endMs);
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(reportAndDescribe(
          error,
          service: 'app',
          stage: 'set_bar_one',
          route: 'Perform',
          projectId: widget.project.id,
        )),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final landscape = media.orientation == Orientation.landscape;
    final baseSize = landscape ? 22.0 : 25.0;
    final lyricSize = baseSize * _fontScale;
    final sidePadding = landscape ? media.size.width * 0.12 : 24.0;
    final lines = _lines;
    // What the band said the song is in, or failing that what the analysis
    // found. The override stands in front of the detected key everywhere the
    // key is read, here included, and it survives re-analysis because it
    // lives on the song rather than on the recording (0144).
    final songKey = widget.project.songKey(
      widget.analysis?.reference?.musicalKey,
    );
    // A capo is a guitar answer about the key the band is in, so it is only
    // ever in play in concert pitch -- see the capo rows in the key sheet.
    final capo = _reading == HornReading.concert ? _capo : 0;
    // The typed words have no chords over them, so no key to be in either.
    // Nor does a sheet with its chords turned off: somebody reading only the
    // words has said they do not want the harmony, and a key over bare
    // lyrics is a label for nothing (review, 17 September 2026).
    //
    // The badge deliberately follows the chord row and not the note names
    // under the words, which are keyed too and are drawn whenever a line is
    // being sung. Naming the key would mean a badge appearing and vanishing
    // under the title as synced mode starts and stops, which is worse than
    // an unnamed key -- and the transpose is this person's own saved choice,
    // so it is not news to them. Taylor's call if it should say it anyway.
    final playedKey = songKey == null ||
            songKey.isEmpty ||
            _source != LiveLyricSource.songSheet ||
            !_showChords
        ? null
        // A horn reading names both keys, because the written key is what
        // this player reads and the concert key is what they have to say to
        // everybody else before the count-in.
        : _reading != HornReading.concert
            ? keyAsRead(songKey, transpose: _transpose, reading: _reading)
            : capo > 0
                // Both keys, the shapes because they are what is under the
                // hand and the sounding key because that is what the singer
                // and everybody else are in.
                ? capoLine(songKey, capo: capo, transpose: _transpose)
                : 'Key of ${keyAsPlayed(songKey, _transpose)}';
    // The person's key with their instrument's transposition on top, which
    // is what every note name under a word is written in. The chords come
    // down by the capo on top of that; the notes do not, because a capo
    // moves the hand and not the voice.
    final readTranspose = _transpose + _reading.semitones;
    // The key the chords and the note names are spelled by: the song's own
    // key before the move, which is what chordAsPlayed and noteAsPlayed both
    // take. Not playedKey above -- that one is the badge under the title, and
    // it is absent when there is no chord row to label, while a note under a
    // word is still spelled by the key the singer is in.
    final spellingKey = songKey == null || songKey.isEmpty ? null : songKey;
    // If a layout-affecting input changed since the last measurement, the
    // line offsets used by synced-scroll need to be recaptured post-frame.
    // Chords on or off is one: it adds or removes a row over every line, and
    // the key under the title with them.
    final layoutKey =
        '$landscape:${_fontScale.toStringAsFixed(2)}:${lines.length}:$_showChords';
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
                      // The bar is a row taller while practising; the last
                      // line of the song was underneath it on the device.
                      (landscape ? 90 : 128) + (_practiceRowShown ? 48 : 0),
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
                        // The key the chords below are in, under the title
                        // where a chart prints it. Transposed, it is the one
                        // thing a band needs to hear before the count-in,
                        // and it differs from the recording's.
                        if (playedKey != null) ...<Widget>[
                          const SizedBox(height: 4),
                          Text(
                            playedKey,
                            key: const Key('live_key'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppColors.muted.withValues(alpha: 0.62),
                              fontSize: lyricSize * 0.42,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ],
                        SizedBox(height: landscape ? 22 : 34),
                        for (var i = 0; i < lines.length; i++)
                          _PerformanceLine(
                            key: _lineKeys.putIfAbsent(
                              lines[i].contributionId ?? 'line_$i',
                              () => GlobalKey(),
                            ),
                            line: lines[i],
                            dotColor: lines[i].contributionId != null
                                ? (_colorByContributionId[lines[i].contributionId] ?? AppColors.gold)
                                : AppColors.gold,
                            fontSize: lyricSize,
                            compact: landscape,
                            showChords: _showChords,
                            transpose: readTranspose,
                            capo: capo,
                            numbers: _numbers,
                            musicalKey: spellingKey,
                            active: _mode == LiveScrollMode.synced &&
                                _lineKey(i) == _activeLineKey,
                            elapsedMs: _mode == LiveScrollMode.synced &&
                                    _lineKey(i) == _activeLineKey
                                ? _elapsed.inMilliseconds
                                : null,
                            // The tune, for the line being sung and no
                            // other: notes under every word is a score.
                            melody: _mode == LiveScrollMode.synced &&
                                    _lineKey(i) == _activeLineKey
                                ? widget.analysis?.reference?.melody
                                : null,
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
                        onSmaller: () => _setFontScale(_fontScale - 0.08),
                        onLarger: () => _setFontScale(_fontScale + 0.08),
                        source: _source,
                        onSource: _selectSource,
                        showChords: _showChords,
                        onToggleChords: () => setState(() => _showChords = !_showChords),
                        countdownEnabled: _countdownEnabled,
                        onOpenCountdownSettings: _openCountdownSettings,
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
                        together: widget.together != null && TogetherRow.shows(widget.together!)
                            ? TogetherRow(
                                session: widget.together!,
                                me: widget.me,
                                onStopLeading: () => unawaited(_stopLeading()),
                              )
                            : null,
                        mode: _mode,
                        playing: _playing,
                        elapsed: _elapsed,
                        duration: _songDuration,
                        hasSync: _hasSync,
                        hasAudio: _audioReady,
                        onPlay: _onPlayPressed,
                        onMode: _selectMode,
                        loops: sectionLoops(_sections),
                        loop: _loop,
                        onLoop: _setLoop,
                        letters: _letters,
                        onLetter: _jumpToLetter,
                        barCount: _downbeats.length,
                        onBars: _openBarLoop,
                        rate: _rate,
                        onRate: _setRate,
                        onSeek: _onSeek,
                        melody: _melody,
                        // Sing along compares against the tune in the key
                        // this person reads the song in, not the recording's.
                        // The reading goes with it so the row is named the
                        // same way as the notes under the words -- see
                        // _YouAndTheSong: the comparison stays in concert
                        // pitch, only the two names move, and they move
                        // together.
                        transpose: _transpose,
                        reading: _reading,
                        musicalKey: spellingKey,
                        singing: _singing,
                        onSing: _toggleSinging,
                        heard: _singing ? _ear?.reading.value : null,
                        singError: _singError,
                        stems: widget.analysis?.stems ?? const <SongStem>[],
                        without: _without,
                        onWithout: _setWithout,
                        mixNote: _mixNote,
                        parts: _partTakes,
                        myPart: _myPart,
                        onMyPart: _setMyPart,
                      ),
                    ),
                  ),
                ),
                // On [_countInBar], not on the beat: the bar is set the moment
                // the button is pressed and the first beat waits on the click
                // file being written, which on a cold start is a few hundred
                // milliseconds. Without this the screen looked untouched for
                // that whole window while a second press would already have
                // cancelled the count nobody could see had started.
                if (_countdownRemaining != null || _countInBar != null)
                  Positioned.fill(
                    child: _CountdownOverlay(
                      key: const Key('live_count_in'),
                      count: _countInBar != null
                          ? _countInBeat ?? 0
                          : _countdownRemaining!,
                      beatsInBar: _countInBar?.beats,
                      onCancel: _cancelCountdown,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openCountdownSettings() {
    unawaited(showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.deepNavy,
      showDragHandle: true,
      builder: (_) => _CountdownSettingsSheet(
        enabled: _countdownEnabled,
        seconds: _countdownSeconds,
        // The seconds are for songs with no beat of their own. This one has
        // one, so a slider setting how long it is would set nothing.
        onTheBeat:
            countInForSong(widget.analysis?.reference, barOne: _barOne) != null,
        onChanged: (enabled, seconds) {
          setState(() {
            _countdownEnabled = enabled;
            _countdownSeconds = seconds;
          });
          unawaited(LiveCountdownStore.save(enabled: enabled, seconds: seconds));
        },
      ),
    ));
  }
}

class _PerformanceLine extends StatelessWidget {
  const _PerformanceLine({
    required this.line,
    required this.dotColor,
    required this.fontSize,
    required this.compact,
    required this.showChords,
    required this.transpose,
    this.capo = 0,
    this.numbers = NumberReading.letters,
    this.active = false,
    this.elapsedMs,
    this.melody,
    this.musicalKey,
    super.key,
  });

  /// For spelling chords the way the key writes them: the song's key before
  /// [transpose] moves it.
  final String? musicalKey;

  /// Semitones this person has moved the song on this device.
  final int transpose;

  /// Which fret the capo is on. The chords come down by it and the notes
  /// under the words do not -- see MusicianChordLyricLine.capo.
  final int capo;

  /// Letters, numbers or numerals. See MusicianChordLyricLine.numbers.
  final NumberReading numbers;

  final MusicianSheetLine line;
  final Color dotColor;
  final double fontSize;
  final bool compact;
  final bool showChords;
  final bool active;

  /// Where the song is, when this is the line being sung. See
  /// MusicianChordLyricLine.elapsedMs.
  final int? elapsedMs;

  /// What the line is sung to, when this is the line being sung. See
  /// MusicianChordLyricLine.melody.
  final Melody? melody;

  @override
  Widget build(BuildContext context) {
    final body = line.body;
    final section = line.section;
    if (body.trim().isEmpty) {
      return SizedBox(height: compact ? fontSize * 0.65 : fontSize * 0.9);
    }
    if (section) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: compact ? 3 : 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.only(top: fontSize * 0.48, right: compact ? 9 : 12),
              child: Container(
                width: compact ? 5 : 6,
                height: compact ? 5 : 6,
                decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
              ),
            ),
            Expanded(
              child: Text(
                // Uppercased, matching the Song Sheet's section treatment.
                // Sections are set smaller than the lyrics on purpose — they
                // are signposts, not the thing being sung — and at a metre
                // away small mixed-case gold text reads as just another line.
                // Caps plus wider tracking is what makes it scan as a marker.
                body.toUpperCase(),
                style: TextStyle(
                  color: AppColors.gold.withValues(alpha: 0.92),
                  fontSize: fontSize * 0.72,
                  height: 1.25,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.4,
                ),
              ),
            ),
          ],
        ),
      );
    }
    // Chords are rendered above the exact word they change on, via the
    // same widget the Song Sheet uses (musician_sheet_line.dart) — Live
    // mode previously showed lyric text only, with no chords at all.
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      padding: EdgeInsets.symmetric(vertical: compact ? 3 : 5, horizontal: active ? 8 : 0),
      margin: EdgeInsets.symmetric(vertical: active ? 2 : 0),
      decoration: BoxDecoration(
        color: active ? AppColors.gold.withValues(alpha: 0.1) : Colors.transparent,
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
                color: active ? AppColors.gold : dotColor,
                shape: BoxShape.circle,
              ),
            ),
          ),
          Expanded(
            child: MusicianChordLyricLine(
              line: line,
              transpose: transpose,
              capo: capo,
              numbers: numbers,
              musicalKey: musicalKey,
              fontScale: fontSize / 13.0,
              showChords: showChords,
              liveMode: true,
              active: active,
              elapsedMs: elapsedMs,
              melody: melody,
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
    required this.source,
    required this.onSource,
    required this.showChords,
    required this.onToggleChords,
    required this.countdownEnabled,
    required this.onOpenCountdownSettings,
  });

  final VoidCallback onClose;
  final VoidCallback onRestart;
  final VoidCallback onSmaller;
  final VoidCallback onLarger;
  final LiveLyricSource source;
  final ValueChanged<LiveLyricSource> onSource;
  final bool showChords;
  final VoidCallback onToggleChords;
  final bool countdownEnabled;
  final VoidCallback onOpenCountdownSettings;

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
                color: AppColors.gold,
                fontSize: 11,
                fontWeight: FontWeight.w900,
                letterSpacing: 2.2,
              ),
            ),
          ),
          PopupMenuButton<LiveLyricSource>(
            key: const Key('live_source_menu'),
            tooltip: 'Lyric source',
            initialValue: source,
            onSelected: onSource,
            icon: Icon(
              source == LiveLyricSource.songSheet
                  ? Icons.description_rounded
                  : Icons.edit_note_rounded,
              size: 20,
            ),
            itemBuilder: (_) => <PopupMenuEntry<LiveLyricSource>>[
              PopupMenuItem<LiveLyricSource>(
                value: LiveLyricSource.workspace,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.edit_note_rounded),
                  title: const Text('Live workspace'),
                  trailing: source == LiveLyricSource.workspace
                      ? const Icon(Icons.check_rounded, color: AppColors.gold)
                      : null,
                ),
              ),
              PopupMenuItem<LiveLyricSource>(
                value: LiveLyricSource.songSheet,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.description_rounded),
                  title: const Text('Song Sheet'),
                  trailing: source == LiveLyricSource.songSheet
                      ? const Icon(Icons.check_rounded, color: AppColors.gold)
                      : null,
                ),
              ),
            ],
          ),
          IconButton(
            key: const Key('live_toggle_chords'),
            onPressed: onToggleChords,
            tooltip: showChords ? 'Hide chords' : 'Show chords',
            icon: Icon(
              showChords ? Icons.music_note_rounded : Icons.music_off_rounded,
              size: 19,
              color: showChords ? AppColors.gold : AppColors.muted,
            ),
          ),
          IconButton(
            key: const Key('live_countdown_settings'),
            onPressed: onOpenCountdownSettings,
            tooltip: 'Count-in before play',
            icon: Icon(
              Icons.timer_outlined,
              size: 19,
              color: countdownEnabled ? AppColors.gold : AppColors.muted,
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

/// Full-screen scrim shown between tapping play and the scroll/sync actually
/// starting, when the count-in is enabled — gives the band a beat to get
/// instruments up and eyes on the screen before anything moves.
///
/// Two shapes. Without [beatsInBar] it is the seconds Perform has always
/// counted, swelling one into the next. With it, the song has a beat of its
/// own and this is a bar of that beat: a dot for each one, filling as the
/// count goes, and a number that snaps rather than swells — a count-in is
/// four hard edges, and an animation across them is exactly the wrong
/// feeling to hand somebody about to play.
class _CountdownOverlay extends StatelessWidget {
  const _CountdownOverlay({
    required this.count,
    required this.onCancel,
    this.beatsInBar,
    super.key,
  });

  /// The seconds left, or — with [beatsInBar] — the beat being counted.
  ///
  /// Zero is the moment between the button being pressed and the first beat
  /// sounding: the bar is there to be seen, and no beat of it has happened
  /// yet.
  final int count;

  /// Beats in the bar, when the count is on the song's own beat.
  final int? beatsInBar;

  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final beats = beatsInBar;
    // The empty box keeps the bar's height before the first beat, so the dots
    // do not jump down the screen when the number arrives.
    final number = count < 1
        ? const SizedBox(key: ValueKey<int>(0), height: 118)
        : Text(
            '$count',
            key: ValueKey<int>(count),
            style: const TextStyle(
              color: AppColors.gold,
              fontSize: 118,
              fontWeight: FontWeight.w900,
              height: 1,
            ),
          );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onCancel,
      child: Container(
        color: const Color(0xFF01050C).withValues(alpha: 0.82),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (beats == null)
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                transitionBuilder: (child, animation) =>
                    ScaleTransition(scale: animation, child: FadeTransition(opacity: animation, child: child)),
                child: number,
              )
            else ...<Widget>[
              number,
              const SizedBox(height: 18),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  for (var beat = 1; beat <= beats; beat += 1)
                    Container(
                      key: Key('live_count_in_dot_$beat'),
                      width: beat == count ? 17 : 11,
                      height: beat == count ? 17 : 11,
                      margin: const EdgeInsets.symmetric(horizontal: 7),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: beat == count
                            ? AppColors.gold
                            : beat < count
                                ? AppColors.gold.withValues(alpha: 0.35)
                                : Colors.white.withValues(alpha: 0.18),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            Text(
              beats == null ? 'Get ready — tap to skip' : 'Counting you in — tap to skip',
              style: const TextStyle(color: AppColors.muted, fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class _CountdownSettingsSheet extends StatefulWidget {
  const _CountdownSettingsSheet({
    required this.enabled,
    required this.seconds,
    required this.onChanged,
    this.onTheBeat = false,
  });

  final bool enabled;
  final int seconds;

  /// Whether this song has a beat of its own to be counted in on. The seconds
  /// belong to the songs that do not, so offering both here would be a slider
  /// that changes nothing.
  final bool onTheBeat;

  /// Fired whenever either value changes — the sheet applies live rather
  /// than waiting for a "Done" tap, matching every other Live setting
  /// (font scale, chords toggle) which take effect immediately.
  final void Function(bool enabled, int seconds) onChanged;

  @override
  State<_CountdownSettingsSheet> createState() => _CountdownSettingsSheetState();
}

class _CountdownSettingsSheetState extends State<_CountdownSettingsSheet> {
  late bool _enabled = widget.enabled;
  late int _seconds = widget.seconds;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 4, 22, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Count-in before play',
              style: TextStyle(color: AppColors.text, fontSize: 17, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              widget.onTheBeat
                  ? 'This song has a beat, so play is counted in one bar of it — '
                      'clicked, seen and felt.'
                  : 'Give the band a few seconds to get ready before the scroll or sync starts.',
              style: const TextStyle(color: AppColors.muted, fontSize: 12.5, height: 1.4),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              activeThumbColor: AppColors.gold,
              value: _enabled,
              onChanged: (value) {
                setState(() => _enabled = value);
                widget.onChanged(_enabled, _seconds);
              },
              title: const Text('Enabled', style: TextStyle(color: AppColors.text, fontSize: 14)),
            ),
            if (_enabled && !widget.onTheBeat) ...<Widget>[
              const SizedBox(height: 4),
              Row(
                children: <Widget>[
                  Text(
                    '$_seconds sec',
                    style: const TextStyle(
                      color: AppColors.gold,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: _seconds.toDouble(),
                      min: 3,
                      max: 10,
                      divisions: 7,
                      activeColor: AppColors.gold,
                      label: '$_seconds sec',
                      onChanged: (value) => setState(() => _seconds = value.round()),
                      onChangeEnd: (_) => widget.onChanged(_enabled, _seconds),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LiveControls extends StatelessWidget {
  const _LiveControls({
    this.together,
    required this.mode,
    required this.playing,
    required this.elapsed,
    required this.duration,
    required this.hasSync,
    required this.hasAudio,
    required this.onPlay,
    required this.onMode,
    required this.loops,
    required this.loop,
    required this.onLoop,
    this.letters = const <RehearsalLetter>[],
    this.onLetter,
    this.barCount = 0,
    this.onBars,
    required this.rate,
    required this.onRate,
    required this.onSeek,
    this.melody,
    required this.transpose,
    this.reading = HornReading.concert,
    this.musicalKey,
    this.singing = false,
    this.onSing,
    this.heard,
    this.singError,
    this.stems = const <SongStem>[],
    this.without,
    this.onWithout,
    this.mixNote,
    this.parts = const <Take>[],
    this.myPart,
    this.onMyPart,
  });

  /// Follow me's line, when the song is open on more than one phone.
  final Widget? together;

  final LiveScrollMode mode;
  final bool playing;
  final Duration elapsed;
  final Duration duration;
  final bool hasSync;
  final bool hasAudio;
  final VoidCallback onPlay;
  final ValueChanged<LiveScrollMode> onMode;

  /// The tune, when the recording has one; whether the singer is singing
  /// along; what the ear hears; and why it could not open, if it could not.
  final Melody? melody;

  /// How far this person has moved the song, and the song's key before the
  /// move: the tune is asked for in the key they are reading in.
  final int transpose;

  /// The instrument the part is written for, which names the two notes in the
  /// row without changing what is compared. See _YouAndTheSong.
  final HornReading reading;
  final String? musicalKey;

  final bool singing;
  final VoidCallback? onSing;
  final PitchReading? heard;
  final String? singError;

  /// The band without you: the separated parts, which one is left out of
  /// the mix (null for the whole recording), and what the mixer is doing
  /// or why it could not.
  final List<SongStem> stems;
  final StemKind? without;
  final ValueChanged<StemKind>? onWithout;
  final String? mixNote;

  /// Your part forward, or everyone but you: the takes that can be
  /// somebody's part (already only those, see MyPartMix.offered), and which
  /// one this person is listening for, which way.
  final List<Take> parts;
  final MyPart? myPart;
  final ValueChanged<MyPart>? onMyPart;

  /// The song's own parts, one chip each, and what is on repeat -- one of
  /// them, or a run of bars.
  final List<PracticeLoop> loops;
  final PracticeLoop? loop;
  final ValueChanged<PracticeLoop> onLoop;

  /// A letter per part of the song, in order, and where a tap on one goes.
  /// Empty for a recording with no sections found, and then the row is not
  /// there at all — see rehearsal_letters.dart.
  final List<RehearsalLetter> letters;
  final ValueChanged<RehearsalLetter>? onLetter;

  /// How many bars the recording has, and the way to pick a run of them.
  /// Nought means no beat grid was found, and then there are no bar
  /// controls at all: sections are the only thing that can be looped.
  final int barCount;
  final VoidCallback? onBars;

  /// How fast the song goes, and where in it we are.
  final double rate;
  final ValueChanged<double> onRate;
  final ValueChanged<Duration> onSeek;

  bool get _synced => mode == LiveScrollMode.synced;
  bool get _showProgress => mode == LiveScrollMode.timed || _synced;

  /// Looping and slowing only mean something when the song is the clock.
  /// In the manual modes the scroll is a speed, and a "chorus" is wherever
  /// the eye happens to be.
  bool get _showPractice => _synced && hasSync;

  /// One bar is a grid nobody can choose a run from, so the chip needs two.
  bool get _canLoopBars => barCount >= 2 && onBars != null;

  /// A run of bars is what is on repeat, rather than a named part.
  bool get _barsOn => loop?.isBars ?? false;

  /// The letters are offered on the same terms as the loops: a jump only
  /// means something when the song is the clock. In a manual scroll mode
  /// there is nothing to seek, so "from B" would have nowhere to go.
  bool get _showLetters =>
      _showPractice && letters.isNotEmpty && onLetter != null;

  /// Which part the song is in, so the letter being played is the one lit.
  /// -1 before the first section and after the last, which is a real place
  /// to be on plenty of recordings.
  int get _letterHere {
    final at = elapsed.inMilliseconds;
    for (var index = letters.length - 1; index >= 0; index -= 1) {
      if (at >= letters[index].startMs && at < letters[index].endMs) {
        return index;
      }
    }
    return -1;
  }

  @override
  Widget build(BuildContext context) {
    final total = duration.inMilliseconds;
    final fraction = total <= 0
        ? 0.0
        : (elapsed.inMilliseconds / total).clamp(0.0, 1.0).toDouble();
    return Material(
      color: const Color(0xE6091424),
      borderRadius: BorderRadius.circular(22),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (together != null) ...<Widget>[together!, const SizedBox(height: 2)],
            // The form, above the transport, where a band's eyes already
            // are. One tap is "from B" — the sentence rehearsals are run on
            // (Every Musician, Same Song, 17 September 2026). The name of
            // the part is on the letter's label underneath it, so nothing
            // has to be explained: the row teaches itself by being used.
            if (_showLetters) ...<Widget>[
              SizedBox(
                // The row is as tall as the letters actually are on this
                // phone. A fixed height would be a clamp on the reader's own
                // text size, which is the one thing this screen must not do.
                height: MediaQuery.textScalerOf(context).scale(_letterSize) *
                        1.1 +
                    12,
                child: ListView(
                  key: const Key('live_letters'),
                  scrollDirection: Axis.horizontal,
                  children: <Widget>[
                    for (var i = 0; i < letters.length; i += 1)
                      _LetterChip(
                        key: Key('live_letter_$i'),
                        letter: letters[i],
                        here: i == _letterHere,
                        onTap: () => onLetter!(letters[i]),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
            ],
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
                const SizedBox(width: 6),
                Icon(
                  Icons.headphones_rounded,
                  size: 16,
                  color: hasAudio ? AppColors.gold : AppColors.muted,
                  semanticLabel: hasAudio
                      ? 'The recording plays along with this'
                      : 'No recording available to play along',
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
              const SizedBox(height: 4),
              Row(
                children: <Widget>[
                  Text(_clock(elapsed), style: const TextStyle(color: AppColors.muted, fontSize: 10)),
                  const SizedBox(width: 8),
                  Expanded(
                    // Synced, the bar is the song and you can put your finger
                    // on it. Timed, it is a guess at where you are, and
                    // dragging a guess does not move the words.
                    child: _synced
                        ? SizedBox(
                            height: 22,
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 2,
                                activeTrackColor: AppColors.gold,
                                inactiveTrackColor: AppColors.line,
                                thumbColor: AppColors.gold,
                                overlayColor: AppColors.gold.withValues(alpha: 0.2),
                                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                              ),
                              child: Slider(
                                key: const Key('live_seek'),
                                value: fraction,
                                onChanged: total <= 0
                                    ? null
                                    : (value) => onSeek(
                                          Duration(milliseconds: (value * total).round()),
                                        ),
                              ),
                            ),
                          )
                        : LinearProgressIndicator(
                            value: fraction,
                            minHeight: 2,
                            color: AppColors.gold,
                          ),
                  ),
                  const SizedBox(width: 8),
                  Text(_clock(duration), style: const TextStyle(color: AppColors.muted, fontSize: 10)),
                ],
              ),
            ],
            if (_showPractice) ...<Widget>[
              if (singing || singError != null) ...<Widget>[
                const SizedBox(height: 4),
                _YouAndTheSong(
                  heard: heard,
                  target: melody?.noteAt(elapsed.inMilliseconds),
                  transpose: transpose,
                  reading: reading,
                  musicalKey: musicalKey,
                  error: singError,
                ),
              ],
              if (mixNote != null) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  mixNote!,
                  key: const Key('live_mix_note'),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.muted, fontSize: 11, height: 1.3),
                ),
              ],
              const SizedBox(height: 2),
              // Speed first, then the parts. One scrolling row rather than
              // two stacked ones: on a phone in landscape this bar is already
              // a third of the lyrics' height.
              SizedBox(
                height: 34,
                child: ListView(
                  key: const Key('live_practice_row'),
                  scrollDirection: Axis.horizontal,
                  children: <Widget>[
                    _RateStepper(rate: rate, onRate: onRate),
                    // Sing along, when there is a tune to sing against. A
                    // recording analysed before the pipeline could hear one
                    // simply has no chip -- not a chip that says no.
                    if (melody != null && !melody!.isEmpty && onSing != null) ...<Widget>[
                      const SizedBox(width: 6),
                      _ModeChip(
                        key: const Key('live_sing'),
                        label: 'Sing',
                        icon: singing ? Icons.mic_rounded : Icons.mic_none_rounded,
                        selected: singing,
                        onTap: onSing!,
                      ),
                    ],
                    // The band without you: one chip per separated part,
                    // and the chosen one is the part you are playing. Tap it
                    // again for the whole recording. A recording that was
                    // never separated simply has no chips.
                    if (stems.isNotEmpty && onWithout != null) ...<Widget>[
                      const SizedBox(width: 6),
                      const Padding(
                        padding: EdgeInsets.only(right: 6),
                        child: Icon(Icons.person_off_outlined, size: 15, color: AppColors.muted),
                      ),
                      for (final stem in stems)
                        _ModeChip(
                          key: Key('live_without_${stem.kind.name}'),
                          label: 'No ${stem.kind.label.toLowerCase()}',
                          selected: without == stem.kind,
                          onTap: () => onWithout!(stem.kind),
                        ),
                    ],
                    // Your part forward, or everyone but you: two chips for
                    // each take somebody recorded, naming the part and the
                    // person. Beside the parts left out because it answers
                    // the same question from the takes instead of the
                    // stems -- a choir's alto is a take, never a stem. A
                    // song with one take, or none, has no chips here.
                    if (parts.isNotEmpty && onMyPart != null) ...<Widget>[
                      const SizedBox(width: 6),
                      const Padding(
                        padding: EdgeInsets.only(right: 6),
                        child: Icon(Icons.record_voice_over_outlined,
                            size: 15, color: AppColors.muted),
                      ),
                      for (final take in parts)
                        for (final way in MyPartWay.values)
                          _ModeChip(
                            key: Key('live_part_${way.name}_${take.id}'),
                            label: MyPart(takeId: take.id, way: way)
                                .label(TakeNaming.partAndPerson(take)),
                            selected: myPart?.takeId == take.id && myPart?.way == way,
                            onTap: () => onMyPart!(MyPart(takeId: take.id, way: way)),
                          ),
                    ],
                    if (loops.isNotEmpty || _canLoopBars) ...<Widget>[
                      const SizedBox(width: 6),
                      const Padding(
                        padding: EdgeInsets.only(right: 6),
                        child: Icon(Icons.repeat_rounded, size: 15, color: AppColors.muted),
                      ),
                      // Bars first, because the run a player is stuck on is
                      // rarely a whole part of the song. Without a beat grid
                      // there is no chip here at all -- see [barCount].
                      if (_canLoopBars)
                        _ModeChip(
                          key: const Key('live_loop_bars'),
                          label: _barsOn ? loop!.label : 'Bars',
                          icon: _barsOn ? Icons.repeat_rounded : null,
                          selected: _barsOn,
                          onTap: onBars!,
                        ),
                      for (var i = 0; i < loops.length; i++)
                        _ModeChip(
                          key: Key('live_loop_$i'),
                          label: loops[i].label,
                          icon: loop == loops[i] ? Icons.repeat_rounded : null,
                          selected: loop == loops[i],
                          onTap: () => onLoop(loops[i]),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The singer's note beside the song's, and one word about the distance.
///
/// Two notes, the same size, because neither is the answer key: the song's
/// is where the recording went as this person reads it, the singer's is
/// where they are, and a voice an octave from that note is on it (see
/// singingVerdict).
/// Green when they agree, gold with a direction when they do not, and the
/// hint spells out the one thing that makes this honest without headphones:
/// the microphone hears the song too.
///
/// The song's note is asked for where this person is playing it, not where it
/// was recorded: somebody who moved the song down two to fit their voice was
/// told to sing the recording's pitch, two semitones from every chord in
/// front of them. Both notes are spelled by the key that lands in, so the
/// same pitch cannot read B♭ on one side of the row and A♯ on the other.
///
/// A horn reading names both of them too, and by the same amount. Naming one
/// side written and the other concert would put two names for one pitch on
/// one screen, which is the thing the paragraph above exists to stop -- and
/// the note names under the words are already written, because they ride the
/// same transpose as the chords over them. Shifting both sides equally leaves
/// the comparison underneath untouched: it is still the microphone against
/// the recording, in concert pitch, so a singer who sings the right note is
/// still told they are on it (review, 17 September 2026).
class _YouAndTheSong extends StatelessWidget {
  const _YouAndTheSong({
    required this.heard,
    required this.target,
    required this.transpose,
    this.reading = HornReading.concert,
    this.musicalKey,
    this.error,
  });

  final PitchReading? heard;
  final MelodyNote? target;

  /// Semitones this person has moved the song, and the song's key before the
  /// move.
  final int transpose;

  /// The instrument the part in front of them is written for. It names the
  /// notes and nothing else.
  final HornReading reading;
  final String? musicalKey;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final targetMidi = target == null ? null : target!.midi + transpose;
    // How far the two names move, and the key they are spelled by once they
    // have. The pitches themselves do not move.
    final written = reading.semitones;
    final readingKey = musicalKey == null
        ? null
        : keyAsPlayed(musicalKey!, transpose + written);
    final verdict = singingVerdict(heard?.midi, targetMidi);
    final accent = switch (verdict) {
      Singing.onIt => AppColors.green,
      Singing.low || Singing.high => AppColors.gold,
      Singing.nothing || Singing.noTarget => AppColors.muted,
    };
    const noteStyle = TextStyle(fontSize: 22, fontWeight: FontWeight.w900, height: 1);
    return Padding(
      key: const Key('live_you_and_the_song'),
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              const Text('You', style: TextStyle(color: AppColors.muted, fontSize: 10.5, fontWeight: FontWeight.w700)),
              const SizedBox(width: 6),
              Text(
                heard == null
                    ? '—'
                    : noteInKey(heard!.midi + written, readingKey),
                key: const Key('live_you_note'),
                style: noteStyle.copyWith(color: heard == null ? AppColors.muted : accent),
              ),
              const SizedBox(width: 16),
              Text('·', style: TextStyle(color: AppColors.muted.withValues(alpha: 0.6), fontSize: 18, height: 1)),
              const SizedBox(width: 16),
              const Text('Song', style: TextStyle(color: AppColors.muted, fontSize: 10.5, fontWeight: FontWeight.w700)),
              const SizedBox(width: 6),
              Text(
                targetMidi == null
                    ? '—'
                    : noteInKey(targetMidi + written, readingKey),
                key: const Key('live_song_note'),
                style: noteStyle.copyWith(color: target == null ? AppColors.muted : AppColors.gold),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            error ?? singingHint(verdict),
            key: const Key('live_sing_hint'),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: error != null ? const Color(0xFFFF9CAA) : accent,
              fontSize: 11,
              height: 1.3,
              fontWeight: verdict == Singing.onIt ? FontWeight.w800 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// How big a rehearsal letter is set, before the phone's own text size is
/// applied to it. Read by the row that holds the letters as well, so the row
/// is as tall as its letters however large they come out.
const double _letterSize = 12.5;

/// One rehearsal letter.
///
/// The letter alone, because the row underneath already names every part of
/// the song on its loop chips and this bar is a third of the lyrics' height
/// on the phone in landscape it is built for. The name is what a screen
/// reader says instead, so "B" is never only a shape.
class _LetterChip extends StatelessWidget {
  const _LetterChip({
    required this.letter,
    required this.here,
    required this.onTap,
    super.key,
  });

  final RehearsalLetter letter;

  /// Whether the song is inside this part now.
  final bool here;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = letter.label.trim();
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Semantics(
        button: true,
        label: name.isEmpty ? letter.letter : '${letter.letter}, $name',
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(9),
          child: Container(
            constraints: const BoxConstraints(minWidth: 28),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: here ? AppColors.gold : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: here ? AppColors.gold : AppColors.line,
              ),
            ),
            child: Text(
              letter.letter,
              style: TextStyle(
                color: here ? AppColors.ink : AppColors.text,
                fontSize: _letterSize,
                height: 1.1,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.6,
              ),
            ),
          ),
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
            : Icon(icon, size: 14, color: selected ? AppColors.ink : AppColors.muted),
        label: Text(label),
        onSelected: (_) => onTap(),
        selectedColor: AppColors.gold,
        labelStyle: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
          color: selected ? AppColors.ink : AppColors.muted,
        ),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

/// The speed, and the two ways to move it.
///
/// Seven speeds would be seven chips, and the practice row already carries
/// the sing chip, the parts left out and every section of the song. So the
/// speeds became one reading with an arrow either side: it takes less width
/// than the three chips it replaces and holds twice as many steps (Every
/// Musician, Same Song, 17 September 2026). The reading is gold once the
/// song is slowed, because a speed you have forgotten you set is the reason
/// a passage "still sounds wrong" at the end of an hour.
class _RateStepper extends StatelessWidget {
  const _RateStepper({required this.rate, required this.onRate});

  final double rate;
  final ValueChanged<double> onRate;

  @override
  Widget build(BuildContext context) {
    final slower = rateStep(rate, faster: false);
    final faster = rateStep(rate, faster: true);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.line),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _RateArrow(
              key: const Key('live_rate_slower'),
              icon: Icons.remove_rounded,
              tooltip: 'Slower',
              onTap: slower == null ? null : () => onRate(slower),
            ),
            SizedBox(
              width: 34,
              child: Text(
                rateLabel(rate),
                key: const Key('live_rate'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  color: rate == 1 ? AppColors.muted : AppColors.gold,
                ),
              ),
            ),
            _RateArrow(
              key: const Key('live_rate_faster'),
              icon: Icons.add_rounded,
              tooltip: 'Faster',
              onTap: faster == null ? null : () => onRate(faster),
            ),
          ],
        ),
      ),
    );
  }
}

class _RateArrow extends StatelessWidget {
  const _RateArrow({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 30, height: 30),
      color: AppColors.text,
      disabledColor: AppColors.line,
    );
  }
}

/// Choosing the bars to put on repeat.
///
/// "Bars nine to twelve" is the sentence a teacher says more than any other,
/// and until now the smallest thing this app could repeat was a whole chorus
/// (Every Musician, Same Song, 17 September 2026). The two ends move in whole
/// bars, so what is chosen always starts and ends on a downbeat the recording
/// actually has; there is nothing here to type and nothing to get wrong.
class _BarLoopSheet extends StatefulWidget {
  const _BarLoopSheet({
    required this.barCount,
    required this.firstBar,
    required this.lastBar,
    required this.looping,
    required this.onChoose,
    required this.onStop,
    this.hasPickup = false,
    this.barOneSaid = false,
    this.onSayBarOne,
    this.onPickup,
  });

  final int barCount;
  final int firstBar;
  final int lastBar;

  /// A run of bars is already on repeat, so there is a way back out of it.
  final bool looping;

  /// Whether anything is played ahead of bar 1 — which only happens once
  /// somebody has said the song starts a few downbeats in (0161).
  final bool hasPickup;

  /// Whether that somebody has already said it, so the detected bars can be
  /// put back.
  final bool barOneSaid;

  /// Says that a bar shown here — by the number this sheet is printing — is
  /// bar 1, or hands the song back to the detected bars with a null. Itself
  /// null for somebody who may not say (see
  /// LivePerformanceScreen.onSayBarOne).
  final void Function(int? bar)? onSayBarOne;

  /// Puts the pickup on repeat on its own.
  final VoidCallback? onPickup;

  final void Function(int firstBar, int lastBar) onChoose;
  final VoidCallback onStop;

  @override
  State<_BarLoopSheet> createState() => _BarLoopSheetState();
}

class _BarLoopSheetState extends State<_BarLoopSheet> {
  late int _first;
  late int _last;

  @override
  void initState() {
    super.initState();
    _first = widget.firstBar.clamp(1, widget.barCount).toInt();
    _last = widget.lastBar.clamp(_first, widget.barCount).toInt();
  }

  /// The two ends, kept inside the song and in order.
  ///
  /// One end moving stops where the other one is rather than dragging it
  /// along: an arrow should only ever move the end it belongs to. Both moving
  /// at once is the slider, which hands them over already in order.
  void _move({int? first, int? last}) {
    var start = (first ?? _first).clamp(1, widget.barCount).toInt();
    var end = (last ?? _last).clamp(1, widget.barCount).toInt();
    if (first != null && last == null) {
      start = math.min(start, _last);
    } else if (last != null && first == null) {
      end = math.max(end, _first);
    } else if (end < start) {
      final held = start;
      start = end;
      end = held;
    }
    setState(() {
      _first = start;
      _last = end;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      // Scrollable so the sheet is never taller than the screen it is on: in
      // landscape, with the text scaled up, this content is taller than a
      // phone's remaining height.
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 4, 22, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                'Loop bars',
                style: TextStyle(color: AppColors.text, fontSize: 17, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 10),
              Text(
                barsLabel(_first, _last),
                key: const Key('live_bar_range_label'),
                style: const TextStyle(
                  color: AppColors.gold,
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                ),
              ),
              // Only with two bars to choose between. A song whose bar 1 is
              // its last downbeat has one numbered bar, and a slider from 1
              // to 1 has no divisions to lay out.
              if (widget.barCount > 1)
                RangeSlider(
                  key: const Key('live_bar_range'),
                  values: RangeValues(_first.toDouble(), _last.toDouble()),
                  min: 1,
                  max: widget.barCount.toDouble(),
                  divisions: widget.barCount - 1,
                  activeColor: AppColors.gold,
                  inactiveColor: AppColors.line,
                  labels: RangeLabels('$_first', '$_last'),
                  onChanged: (values) => _move(
                    first: values.start.round(),
                    last: values.end.round(),
                  ),
                ),
              // The slider crosses the whole song, so on a long one a bar is
              // a couple of pixels wide and a thumb lands near the bars you
              // meant rather than on them. These land on them: drag to the
              // passage, then step each end a bar at a time. The reading
              // above is what is chosen either way.
              Wrap(
                spacing: 14,
                runSpacing: 6,
                children: <Widget>[
                  _BarNudge(
                    name: 'First',
                    bar: _first,
                    earlier: _first > 1 ? () => _move(first: _first - 1) : null,
                    later: _first < _last ? () => _move(first: _first + 1) : null,
                    keyPrefix: 'live_bar_first',
                  ),
                  _BarNudge(
                    name: 'Last',
                    bar: _last,
                    earlier: _last > _first ? () => _move(last: _last - 1) : null,
                    later: _last < widget.barCount ? () => _move(last: _last + 1) : null,
                    keyPrefix: 'live_bar_last',
                  ),
                ],
              ),
              // On the first bar shown, because that is the bar somebody has
              // just walked to with the arrows while counting along a printed
              // part: "this one, the one I am looking at, is bar 1". Said
              // small and in passing rather than explained — the picker
              // closes and the numbers behind it have moved, which is the
              // whole of the teaching (Every Musician, Same Song,
              // 17 September 2026).
              if (widget.onSayBarOne != null)
                Wrap(
                  spacing: 6,
                  children: <Widget>[
                    TextButton(
                      key: const Key('live_this_is_bar_one'),
                      onPressed: () => widget.onSayBarOne!(_first),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: AppColors.muted,
                      ),
                      // The size on the label, not on the style: styleFrom
                      // replaces the resolved text style outright and takes
                      // the font family with it (see
                      // button_labels_keep_their_font_test).
                      child: const Text(
                        'This is bar 1',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    if (widget.barOneSaid)
                      TextButton(
                        key: const Key('live_use_detected_bars'),
                        onPressed: () => widget.onSayBarOne!(null),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          foregroundColor: AppColors.muted,
                        ),
                        child: const Text(
                          'Use the detected bars',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                  ],
                ),
              const SizedBox(height: 10),
              // Wrapped rather than a row with a spacer: at the text sizes
              // somebody reading from a music stand actually uses, the two
              // buttons are wider than the sheet and one of them would be cut
              // off at the edge.
              SizedBox(
                width: double.infinity,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 4,
                  children: <Widget>[
                    // What is played before bar 1, on its own. Until bar 1
                    // could be moved this stretch had no number, so there was
                    // no way to ask for it — and a pickup phrase is exactly
                    // the bar a teacher drills on a song that has one (0161).
                    if (widget.hasPickup && widget.onPickup != null)
                      TextButton(
                        key: const Key('live_bar_loop_pickup'),
                        onPressed: widget.onPickup,
                        child: const Text('Loop the pickup'),
                      ),
                    if (widget.looping)
                      TextButton(
                        key: const Key('live_bar_loop_stop'),
                        onPressed: widget.onStop,
                        child: const Text('Stop looping'),
                      ),
                    FilledButton(
                      key: const Key('live_bar_loop_apply'),
                      onPressed: () => widget.onChoose(_first, _last),
                      child: const Text('Loop these bars'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One end of the loop, a bar at a time.
///
/// The same shape as the speed stepper, for the same reason: a number and the
/// two ways to move it, where the thumb cannot miss.
class _BarNudge extends StatelessWidget {
  const _BarNudge({
    required this.name,
    required this.bar,
    required this.earlier,
    required this.later,
    required this.keyPrefix,
  });

  final String name;
  final int bar;
  final VoidCallback? earlier;
  final VoidCallback? later;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(name, style: const TextStyle(color: AppColors.muted, fontSize: 12)),
        const SizedBox(width: 6),
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.line),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _RateArrow(
                key: Key('${keyPrefix}_back'),
                icon: Icons.remove_rounded,
                tooltip: 'A bar earlier',
                onTap: earlier,
              ),
              SizedBox(
                width: 30,
                child: Text(
                  '$bar',
                  key: Key(keyPrefix),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              _RateArrow(
                key: Key('${keyPrefix}_on'),
                icon: Icons.add_rounded,
                tooltip: 'A bar later',
                onTap: later,
              ),
            ],
          ),
        ),
      ],
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
