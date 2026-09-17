import 'dart:async';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../services/audio_source_for.dart';
import '../../services/follow_me.dart';
import 'package:flutter/services.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../domain/practice_mark.dart';
import '../../domain/song_analysis_models.dart';
import 'package:path_provider/path_provider.dart';

import '../../services/music_reference.dart' show noteInKey;
import '../../services/pitch.dart';
import '../../services/pitch_listener.dart';
import '../../services/play_along.dart';
import '../../services/song_analysis_service.dart';
import '../../services/user_facing_error.dart';
import '../../widgets/microphone_disclosure.dart';
import 'follow_me_bar.dart';
import 'live_countdown_store.dart';
import 'musician_sheet_line.dart';
import 'musician_sheet_logic.dart';
import 'practice_marks.dart';
import 'practice_rules.dart';
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
    this.together,
    this.me = '',
    this.keepPractice,
    this.practise,
    super.key,
  });

  /// Where what a followed session leaves behind goes: the part worked on,
  /// the speed, and the leader's note. Null keeps nothing, which is every
  /// screen that is not the song itself.
  final void Function(PracticeMark mark)? keepPractice;

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
  /// leader. Named up front, like the lesson's, so one visit is one mark.
  final PracticeLog _own = PracticeLog();
  final String _ownMarkId = newPracticeMarkId();

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
    // Perform opened from somewhere that is not the song itself keeps
    // nothing, the way it always did.
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
  /// is a section of the song's own structure -- Intro, Verse, Chorus -- so
  /// "again" means the part a musician would name, not a time range. The
  /// rate is applied to the player when there is one and to the wall clock
  /// when there is not, so a sheet with no recording still slows down.
  double _rate = 1;
  StructureSection? _loop;

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

  List<StructureSection> get _sections =>
      widget.analysis?.reference?.structureSections ??
      const <StructureSection>[];

  Melody? get _melody => widget.analysis?.reference?.melody;

  /// Whether somebody is practising rather than performing.
  ///
  /// A part on repeat, a slower speed, or singing along is the difference.
  /// On stage the controls get out of the way after a few seconds, which is
  /// right: the words are the point. Practising, the controls *are* the
  /// point -- the first device test of this screen spent half its taps
  /// revealing the bar before the chip underneath could be pressed.
  bool get _practising => _loop != null || _rate != 1 || _singing || _without != null;

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
      _loop = _sectionAt(practise.startMs, practise.endMs);
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
    if (reference != null) unawaited(_prepareAudio(reference));
    unawaited(_loadCountdownPrefs());
    unawaited(_loadTranspose());

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
    _loop = _sectionAt(state.loopStartMs, state.loopEndMs);
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

  /// The section on repeat, found by where it sits in the song.
  StructureSection? _sectionAt(int? startMs, int? endMs) {
    if (startMs == null || endMs == null) return null;
    for (final section in _sections) {
      if (section.startMs == startMs && section.endMs == endMs) return section;
    }
    return null;
  }

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

  /// A part named the way its chip is.
  String _partLabel(int? startMs, int? endMs) {
    if (startMs == null || endMs == null) return 'The whole song';
    final labels = sectionChipLabels(_sections);
    for (var i = 0; i < _sections.length; i++) {
      if (_sections[i].startMs == startMs && _sections[i].endMs == endMs) return labels[i];
    }
    return 'A part of the song';
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

  /// Loads the analyzed reference recording so "synced" mode can play the
  /// actual take underneath the scrolling lyrics — without this, "synced"
  /// was only ever a guess at where you should be, with no way to actually
  /// hear whether it lines up.
  Future<void> _prepareAudio(ReferenceTrack reference) async {
    try {
      final path = await SongAnalysisService().ensureLocalReference(reference);
      if (!mounted) return;
      _referencePath = path;
      final player = AudioPlayer();
      await player.setSource(audioSourceFor(path));
      if (_rate != 1) await player.setPlaybackRate(_rate);
      // The song may already be somewhere: Start pressed while this loaded,
      // or a leader followed from the first second. The recording starts
      // from there rather than from the top, under words that are not.
      if (_elapsed > Duration.zero) await player.seek(_elapsed);
      if (!mounted) {
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
      _audioCompleteSub = player.onPlayerComplete.listen((_) {
        if (mounted) setState(() => _playing = false);
      });
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
    _ear?.reading.removeListener(_earChanged);
    _ear?.dispose();
    _scroll.dispose();
    unawaited(_audioPositionSub?.cancel());
    unawaited(_audioCompleteSub?.cancel());
    unawaited(_audioPlayer?.dispose());
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
  void _onPlayPressed() {
    _takeOver();
    if (_countdownRemaining != null) {
      _cancelCountdown();
      return;
    }
    if (!_playing && _countdownEnabled) {
      _startCountdown();
      return;
    }
    _togglePlay();
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
    if (mounted) setState(() => _countdownRemaining = null);
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
      _audioCompleteSub = player.onPlayerComplete.listen((_) {
        if (mounted) setState(() => _playing = false);
      });
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

  /// Loop one part, or stop looping.
  ///
  /// Tapping the part already on repeat is the way out; any other part jumps
  /// there and stays there, playing or paused. Paused, the sheet still moves
  /// to the part so the next press of Start begins where the eye is.
  void _setLoop(StructureSection section) {
    _takeOver();
    _cancelCountdown();
    final same = identical(section, _loop);
    setState(() {
      _loop = same ? null : section;
      _controlsVisible = true;
      if (_mode == LiveScrollMode.off && _hasSync) _mode = LiveScrollMode.synced;
    });
    if (!same) {
      _seekTo(Duration(milliseconds: section.startMs));
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

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final landscape = media.orientation == Orientation.landscape;
    final baseSize = landscape ? 22.0 : 25.0;
    final lyricSize = baseSize * _fontScale;
    final sidePadding = landscape ? media.size.width * 0.12 : 24.0;
    final lines = _lines;
    final songKey = widget.analysis?.reference?.musicalKey?.trim();
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
        : keyAsPlayed(songKey, _transpose);
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
                            'Key of $playedKey',
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
                            transpose: _transpose,
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
                        sections: _sections,
                        sectionLabels: sectionChipLabels(_sections),
                        loop: _loop,
                        onLoop: _setLoop,
                        rate: _rate,
                        onRate: _setRate,
                        onSeek: _onSeek,
                        melody: _melody,
                        // Sing along compares against the tune in the key
                        // this person reads the song in, not the recording's.
                        transpose: _transpose,
                        musicalKey: spellingKey,
                        singing: _singing,
                        onSing: _toggleSinging,
                        heard: _singing ? _ear?.reading.value : null,
                        singError: _singError,
                        stems: widget.analysis?.stems ?? const <SongStem>[],
                        without: _without,
                        onWithout: _setWithout,
                        mixNote: _mixNote,
                      ),
                    ),
                  ),
                ),
                if (_countdownRemaining != null)
                  Positioned.fill(
                    child: _CountdownOverlay(
                      remaining: _countdownRemaining!,
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
class _CountdownOverlay extends StatelessWidget {
  const _CountdownOverlay({required this.remaining, required this.onCancel});

  final int remaining;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onCancel,
      child: Container(
        color: const Color(0xFF01050C).withValues(alpha: 0.82),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              transitionBuilder: (child, animation) =>
                  ScaleTransition(scale: animation, child: FadeTransition(opacity: animation, child: child)),
              child: Text(
                '$remaining',
                key: ValueKey<int>(remaining),
                style: const TextStyle(
                  color: AppColors.gold,
                  fontSize: 118,
                  fontWeight: FontWeight.w900,
                  height: 1,
                ),
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'Get ready — tap to skip',
              style: TextStyle(color: AppColors.muted, fontSize: 13, fontWeight: FontWeight.w600),
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
  });

  final bool enabled;
  final int seconds;

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
            const Text(
              "Give the band a few seconds to get ready before the scroll or sync starts.",
              style: TextStyle(color: AppColors.muted, fontSize: 12.5, height: 1.4),
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
            if (_enabled) ...<Widget>[
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
    required this.sections,
    required this.sectionLabels,
    required this.loop,
    required this.onLoop,
    required this.rate,
    required this.onRate,
    required this.onSeek,
    this.melody,
    required this.transpose,
    this.musicalKey,
    this.singing = false,
    this.onSing,
    this.heard,
    this.singError,
    this.stems = const <SongStem>[],
    this.without,
    this.onWithout,
    this.mixNote,
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

  /// The song's own parts, one chip each, and which one is on repeat.
  final List<StructureSection> sections;
  final List<String> sectionLabels;
  final StructureSection? loop;
  final ValueChanged<StructureSection> onLoop;

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
                    for (final each in practiceRates)
                      _ModeChip(
                        key: Key('live_rate_$each'),
                        label: rateLabel(each),
                        selected: rate == each,
                        onTap: () => onRate(each),
                      ),
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
                    if (sections.isNotEmpty) ...<Widget>[
                      const SizedBox(width: 6),
                      const Padding(
                        padding: EdgeInsets.only(right: 6),
                        child: Icon(Icons.repeat_rounded, size: 15, color: AppColors.muted),
                      ),
                      for (var i = 0; i < sections.length; i++)
                        _ModeChip(
                          key: Key('live_loop_$i'),
                          label: sectionLabels[i],
                          icon: identical(loop, sections[i]) ? Icons.repeat_rounded : null,
                          selected: identical(loop, sections[i]),
                          onTap: () => onLoop(sections[i]),
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
class _YouAndTheSong extends StatelessWidget {
  const _YouAndTheSong({
    required this.heard,
    required this.target,
    required this.transpose,
    this.musicalKey,
    this.error,
  });

  final PitchReading? heard;
  final MelodyNote? target;

  /// Semitones this person has moved the song, and the song's key before the
  /// move.
  final int transpose;
  final String? musicalKey;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final targetMidi = target == null ? null : target!.midi + transpose;
    final readingKey =
        musicalKey == null ? null : keyAsPlayed(musicalKey!, transpose);
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
                heard == null ? '—' : noteInKey(heard!.midi, readingKey),
                key: const Key('live_you_note'),
                style: noteStyle.copyWith(color: heard == null ? AppColors.muted : accent),
              ),
              const SizedBox(width: 16),
              Text('·', style: TextStyle(color: AppColors.muted.withValues(alpha: 0.6), fontSize: 18, height: 1)),
              const SizedBox(width: 16),
              const Text('Song', style: TextStyle(color: AppColors.muted, fontSize: 10.5, fontWeight: FontWeight.w700)),
              const SizedBox(width: 6),
              Text(
                targetMidi == null ? '—' : noteInKey(targetMidi, readingKey),
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
