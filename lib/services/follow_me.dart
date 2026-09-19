import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../domain/song_cycle.dart';

/// Follow me: one person leads, and everybody else's song moves with them.
///
/// Taylor, 16 September 2026: teachers starting lesson rooms, bandmates in a
/// session, "a user you met across the world" -- with the song sheet and the
/// tools there while it happens. Video is the part every app already has.
/// The part only this one can do is put the teacher's loop on the student's
/// screen, so that is built first, and it works with no video at all: a
/// lesson in the same room, a band with a phone on every music stand, or a
/// call running beside it.
///
/// **What is shared is where the song is: whether it is playing, where, how
/// fast, which part is on repeat, and which words are up.** What each person
/// hears (a part left out, singing along) and how big their words are stays
/// on their own phone. A teacher saying "chorus again, slower" moves the
/// student's song; the student's own guitar staying muted is theirs.
///
/// Nothing is recorded or stored. Every phone plays its own copy of the
/// song, so the messages are a few numbers each, never audio -- and it rides
/// on the live connection the song already opens for "who is here".

/// Where the leader's song is, at the moment [sentAt] on the leader's clock.
@immutable
class FollowState {
  const FollowState({
    required this.sheet,
    required this.synced,
    required this.playing,
    required this.positionMs,
    required this.rate,
    required this.sentAt,
    this.loopStartMs,
    this.loopEndMs,
    this.lineKey,
    this.barOne,
    this.cycleBeats,
    this.cycleAccents,
  });

  /// Reading the song sheet (true) or the words as typed in the song.
  final bool sheet;

  /// The song is the clock. When false the leader is scrolling by hand or
  /// at a speed, and what follows is the line on their anchor, not a time.
  final bool synced;

  final bool playing;
  final int positionMs;
  final double rate;

  /// The part on repeat, by its place in the song rather than its name:
  /// two phones name sections the same way, but a time cannot be misread.
  final int? loopStartMs;
  final int? loopEndMs;

  /// The line on the leader's anchor, for following when not [synced].
  final String? lineKey;

  /// Which downbeat the song calls bar 1, or 0 when nobody has said and the
  /// first downbeat stands (0161). Null only from a build that predates this,
  /// and then the follower keeps whatever its own copy of the song says.
  ///
  /// This is not a reading and does not break the rule that readings stay on
  /// the phone they were chosen on. A person's numbers, horn part and capo
  /// are theirs; where bar 1 is belongs to the song, the way the band's key
  /// does, and the likeliest moment for it to be said is in the middle of the
  /// lesson it fixes — the teacher hears the count-in, moves bar 1, and asks
  /// for bars nine to twelve. Without it on the heartbeat the student's chip
  /// would answer with different numbers for the rest of the hour, and the
  /// practice mark kept for them would be written in them too (review, 18
  /// September 2026).
  final int? barOne;

  /// How many beats the cycle the band counts goes round in, or 0 when
  /// nobody is counting one and the analysed bars stand (0162). Null only
  /// from a build that predates this, and then the follower keeps whatever
  /// its own copy of the song says.
  ///
  /// Here for the reason [barOne] is here, and not a reading for the same
  /// reason either: what the room counts is a fact about the song, and the
  /// likeliest moment for it to be said is in the middle of the lesson it
  /// fixes. Without it the teacher's chip reads "Cycles 4-5" while the
  /// student's reads "Bars 22-25" for the rest of the hour, the loop the
  /// teacher sends is named in the wrong count on the other phone, and the
  /// practice mark kept for the student is labelled in a count nobody said
  /// out loud (review, 18 September 2026).
  final int? cycleBeats;

  /// Which beats of that cycle after the first are stressed, so the
  /// follower's count-in strikes where the leader's does. Empty is a cycle
  /// with nothing said inside it; null is a build that does not say.
  final List<int>? cycleAccents;

  /// The leader's wall clock, in milliseconds since the epoch.
  final int sentAt;

  /// The cycle this state is counting, or null for the analysed bars.
  SongCycle? get cycle =>
      cycleBeats == null ? null : SongCycle.of(cycleBeats, cycleAccents);

  bool get looping => loopStartMs != null && loopEndMs != null && loopEndMs! > loopStartMs!;

  /// Everything but the moving parts: a change here is a decision somebody
  /// made, and is sent at once.
  bool sameDecisions(FollowState other) =>
      sheet == other.sheet &&
      synced == other.synced &&
      playing == other.playing &&
      rate == other.rate &&
      loopStartMs == other.loopStartMs &&
      loopEndMs == other.loopEndMs &&
      barOne == other.barOne &&
      cycleBeats == other.cycleBeats &&
      _sameAccents(cycleAccents, other.cycleAccents);

  static bool _sameAccents(List<int>? a, List<int>? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i += 1) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'sheet': sheet,
        'synced': synced,
        'playing': playing,
        'at': positionMs,
        'rate': rate,
        'sent': sentAt,
        if (looping) 'loop': <int>[loopStartMs!, loopEndMs!],
        if (lineKey != null) 'line': lineKey,
        // Sent even when it is 0, unlike the two above: 0 is the leader
        // saying "use the detected bars", and a key left out of the message
        // would read on the other phone as an older build with nothing to
        // say, which leaves the follower counting from the bar 1 that was
        // just cleared.
        if (barOne != null) 'bar1': barOne,
        // And the cycle, on the same terms and for the same reason: 0 is the
        // leader saying "use the detected bars" in the cycle sheet, and it
        // has to reach the room or half of it goes on counting sevens.
        if (cycleBeats != null) 'cyc': cycleBeats,
        if (cycleBeats != null) 'cycacc': cycleAccents ?? const <int>[],
      };

  /// Null for anything that does not read as a state. A message from a
  /// build newer or older than this one is not a reason to throw.
  static FollowState? fromJson(Object? json) {
    if (json is! Map) return null;
    final at = json['at'];
    final rate = json['rate'];
    final sent = json['sent'];
    if (at is! num || rate is! num || sent is! num) return null;
    if (rate <= 0 || rate > 4) return null;
    final loop = json['loop'];
    int? loopStart;
    int? loopEnd;
    if (loop is List && loop.length == 2 && loop[0] is num && loop[1] is num) {
      loopStart = (loop[0] as num).round();
      loopEnd = (loop[1] as num).round();
      if (loopEnd <= loopStart) {
        loopStart = null;
        loopEnd = null;
      }
    }
    final line = json['line'];
    final bar1 = json['bar1'];
    final counted = json['cyc'];
    final stressed = json['cycacc'];
    return FollowState(
      sheet: json['sheet'] == true,
      synced: json['synced'] == true,
      playing: json['playing'] == true,
      positionMs: math.max(0, at.round()),
      rate: rate.toDouble(),
      sentAt: sent.round(),
      loopStartMs: loopStart,
      loopEndMs: loopEnd,
      lineKey: line is String ? line : null,
      // Anything that is not a number at all is a build that does not say,
      // and a negative one is nonsense: both read as nothing said rather
      // than as a reason to drop the whole message.
      barOne: bar1 is num ? math.max(0, bar1.round()) : null,
      // Read the same way, and the stresses only if there is a count for
      // them to sit in. SongCycle.of tidies whatever arrives, so a message
      // from a build that counted differently costs the follower nothing.
      cycleBeats: counted is num ? math.max(0, counted.round()) : null,
      cycleAccents: counted is num && stressed is List
          ? <int>[
              for (final beat in stressed)
                if (beat is num) beat.round(),
            ]
          : null,
    );
  }
}

/// Where [state]'s song is at [leaderNowMs] on the leader's clock.
///
/// Paused, exactly where it was left. Playing, moved on by the time since at
/// the song's speed, and brought back round inside the part on repeat the
/// way the leader's own screen does it.
int followTargetMs(FollowState state, int leaderNowMs) {
  if (!state.playing) return state.positionMs;
  final since = math.max(0, leaderNowMs - state.sentAt);
  var target = state.positionMs + (since * state.rate).round();
  if (state.looping && target >= state.loopEndMs!) {
    final start = state.loopStartMs!;
    final length = state.loopEndMs! - start;
    target = start + (target - start) % length;
  }
  return target;
}

/// How far two phones may disagree before the follower is moved.
///
/// Every move is a seek, and a seek is a hiccup you can hear, so small
/// differences are left alone. A quarter of a second is about where two
/// phones playing the same song in one room start to sound like an echo.
const int followToleranceMs = 250;

bool worthCorrecting(int localMs, int targetMs) =>
    (localMs - targetMs).abs() > followToleranceMs;

/// How often the leader says where the song is when nothing has changed:
/// soon enough that somebody arriving mid-song catches up in a moment, and
/// that a phone which drifted is put right before anybody hears it.
const int heartbeatPlayingMs = 2000;
const int heartbeatPausedMs = 5000;

/// The shortest gap between two sends about the same decisions. A finger
/// dragging the seek bar changes the position every frame; the followers
/// need where it lands, not every place it passed through.
const int minimumGapMs = 200;

/// Whether the leader should send [now], having last sent [last].
bool worthSending(FollowState? last, FollowState now) {
  if (last == null) return true;
  if (!last.sameDecisions(now)) return true;
  final gap = now.sentAt - last.sentAt;
  if (gap < minimumGapMs) return false;
  if (now.synced) {
    // Somebody moved the song: a seek, a restart, a part picked again.
    final expected = followTargetMs(last, now.sentAt);
    if ((expected - now.positionMs).abs() > followToleranceMs) return true;
  } else if (now.lineKey != last.lineKey) {
    return true;
  }
  return gap >= (now.playing ? heartbeatPlayingMs : heartbeatPausedMs);
}

/// The leader's clock, as far as this phone can tell.
///
/// Two phones' clocks disagree, sometimes by seconds, and "playing from 0:42
/// as of now" is only useful if both agree what now is. Every message says
/// when it left; it arrived later than that by however long the trip took,
/// which is never negative. So each message puts a floor under the
/// difference between the two clocks, and the highest floor -- the message
/// that travelled fastest -- is the best estimate. A window rather than all
/// time, so a clock that is corrected mid-lesson is followed.
class LeaderClock {
  LeaderClock({this.window = 20});

  final int window;
  final List<int> _samples = <int>[];

  void heard({required int sentAt, required int receivedAt}) {
    _samples.add(sentAt - receivedAt);
    if (_samples.length > window) _samples.removeAt(0);
  }

  /// Leader's clock minus this phone's, or null before anything was heard.
  int? get offsetMs => _samples.isEmpty ? null : _samples.reduce(math.max);

  int leaderNow(int localNowMs) => localNowMs + (offsetMs ?? 0);

  void reset() => _samples.clear();
}

/// One phone with the song open.
@immutable
class SongDevice {
  const SongDevice({
    required this.device,
    required this.userId,
    required this.displayName,
    this.following,
  });

  final String device;
  final String userId;
  final String displayName;

  /// The device this one is following, if any.
  final String? following;
}

/// Who else has the song open, in a few words.
///
/// Names rather than a count, because "Jess is here" is a person you can
/// lead and "1 other" is a statistic. [me] is left out; the same person on
/// another phone is said as that, since leading your own tablet from your
/// phone is a real thing to do.
String whoIsHere(List<SongDevice> others, String me) {
  final names = <String>[];
  var mine = false;
  for (final each in others) {
    if (each.userId == me) {
      mine = true;
      continue;
    }
    if (!names.contains(each.displayName)) names.add(each.displayName);
  }
  return switch (names.length) {
    0 => mine ? 'Also open on your other device' : 'Nobody else here',
    1 => '${names[0]} is here',
    2 => '${names[0]} and ${names[1]} are here',
    _ => '${names[0]} and ${names.length - 1} others are here',
  };
}

/// The live connection under a song, as Follow me needs it. The song's
/// cowork channel is the real one; tests wire two sessions to one bus.
abstract class FollowLine {
  /// This phone, for as long as the song is open. Not the person: somebody
  /// with the song open on a tablet and a phone can lead from one and
  /// follow on the other.
  String get device;

  /// Follow me's messages from everybody on the song, this phone included.
  Stream<Map<String, dynamic>> get followMessages;

  /// Who has the song open, one entry per phone.
  Stream<List<SongDevice>> get devices;

  Future<void> sendFollow(Map<String, dynamic> message);

  /// Tells everyone which device this one is following, or none.
  Future<void> markFollowing(String? device);
}

/// Somebody else leading this song, as heard here.
@immutable
class SongLeader {
  const SongLeader({
    required this.device,
    required this.userId,
    required this.name,
    required this.since,
    required this.state,
    required this.heardAt,
  });

  final String device;
  final String userId;
  final String name;
  final int since;
  final FollowState state;
  final int heardAt;
}

/// Following ended, and how.
@immutable
class FollowEnded {
  const FollowEnded({
    required this.leaderName,
    required this.byLeader,
    required this.said,
    this.stopped = false,
    this.leaderUserId,
    this.note,
  });

  final String leaderName;
  final String? leaderUserId;

  /// The leader stopped or went quiet, rather than this phone taking the
  /// song back.
  final bool byLeader;

  /// The leader said they had stopped. False when this phone only lost
  /// touch with them, which may yet be followed again (see
  /// FollowSession.rejoinWithinMs) -- so the lesson is not over.
  final bool stopped;

  /// What happened, as a sentence ("Taylor stopped leading.").
  final String said;

  /// What the leader left on the way out, if anything.
  final String? note;
}

/// The longest note a leader can leave when they stop.
const int leaderNoteMax = 280;

String? _cleanNote(Object? note) {
  if (note is! String) return null;
  final trimmed = note.trim();
  if (trimmed.isEmpty) return null;
  return trimmed.length > leaderNoteMax ? trimmed.substring(0, leaderNoteMax) : trimmed;
}

/// Follow me for one open song: who leads, who follows, and what to tell.
///
/// One leader at a time. When two people press Lead, the later press wins
/// -- the one who just decided to lead meant it more recently -- and the
/// other is told who has it now. Following is always a tap: a phone never
/// starts moving on its own because somebody else pressed something.
class FollowSession extends ChangeNotifier {
  FollowSession({
    required this.line,
    required this.userId,
    this.name = 'Someone',
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _messagesSub = line.followMessages.listen(_heard);
    _devicesSub = line.devices.listen(_heardDevices);
  }

  final FollowLine line;
  final String userId;
  String name;
  final int Function() _now;

  late final StreamSubscription<Map<String, dynamic>> _messagesSub;
  late final StreamSubscription<List<SongDevice>> _devicesSub;
  final StreamController<FollowState> _states = StreamController<FollowState>.broadcast();
  final StreamController<String> _notes = StreamController<String>.broadcast();
  final StreamController<FollowEnded> _endings = StreamController<FollowEnded>.broadcast();
  final LeaderClock _clock = LeaderClock();
  Timer? _quiet;

  bool _leading = false;
  int _since = 0;
  FollowState? _lastSent;
  bool _following = false;
  SongLeader? _leader;
  List<SongDevice> _here = const <SongDevice>[];
  final Set<String> _seen = <String>{};
  bool _closed = false;

  /// The leader this phone lost touch with while following, and until when
  /// it follows them again by itself if they come back.
  SongLeader? _rejoin;
  int _rejoinUntil = 0;
  int? _lastQuietCheck;

  /// Nothing heard from a leader for this long means they are gone, even
  /// if the connection has not said so yet.
  static const int quietAfterMs = 9000;

  /// How long a follower who lost touch goes on waiting for the same
  /// leader. Found on the second two-phone test: the follower dropped for a
  /// few seconds while the leader's phone was busy, never followed again,
  /// and so never received the teacher's note at the end. Nobody chose to
  /// stop following; a signal flickered. A minute and a half covers a lift,
  /// a tunnel, a phone locked and unlocked, and is short enough that coming
  /// back to somebody who has moved on to another song is not a surprise.
  static const int rejoinWithinMs = 90000;

  bool get leading => _leading;
  bool get following => _following && _leader != null;

  /// Somebody else leading, whether or not this phone follows them.
  SongLeader? get leader => _leader;

  /// Every other phone with the song open.
  List<SongDevice> get others =>
      _here.where((each) => each.device != line.device).toList(growable: false);

  /// How many phones are following this one.
  int get followers => _here.where((each) => each.following == line.device).length;

  /// The leader's latest word, for a follower to put their song to.
  Stream<FollowState> get states => _states.stream;

  /// Sentences worth a moment on screen: somebody stopped leading, somebody
  /// else took over.
  Stream<String> get notes => _notes.stream;

  /// Every time this phone stops following, however it happened. What the
  /// session leaves behind is kept from here (see practice_marks.dart).
  Stream<FollowEnded> get endings => _endings.stream;

  /// Where the leader's song is right now, or null with nobody leading.
  int? targetMs() {
    final leader = _leader;
    if (leader == null) return null;
    return followTargetMs(leader.state, _clock.leaderNow(_now()));
  }

  void lead() {
    if (_closed || _leading) return;
    _rejoin = null;
    if (_following) {
      _following = false;
      unawaited(line.markFollowing(null));
      _ended(byLeader: false);
    }
    _leading = true;
    _since = _now();
    _lastSent = null;
    notifyListeners();
  }

  /// Offered on every tick of the leader's screen; only what is worth
  /// sending leaves the phone.
  void publish(FollowState state) {
    if (!_leading || _closed) return;
    if (!worthSending(_lastSent, state)) return;
    _lastSent = state;
    unawaited(_send(<String, dynamic>{
      'kind': 'lead',
      'device': line.device,
      'user': userId,
      'name': name,
      'since': _since,
      'state': state.toJson(),
    }));
  }

  /// Stops leading, leaving [note] with whoever was following: "keep it
  /// slow until the change is clean". It travels inside the stop message
  /// and is kept only on the phones that were following.
  void stopLeading({String? note}) {
    if (!_leading) return;
    _leading = false;
    _lastSent = null;
    final cleaned = _cleanNote(note);
    unawaited(_send(<String, dynamic>{
      'kind': 'end',
      'device': line.device,
      if (cleaned != null) 'note': cleaned,
    }));
    if (!_closed) notifyListeners();
  }

  /// Follows whoever is leading, and hands the screen their latest state.
  void follow() {
    final leader = _leader;
    if (_closed || leader == null) return;
    if (_leading) stopLeading();
    _rejoin = null;
    _following = true;
    unawaited(line.markFollowing(leader.device));
    notifyListeners();
    _states.add(leader.state);
  }

  /// Stops following -- and stops waiting to follow again a leader this
  /// phone lost touch with, because taking the song back is a choice.
  void unfollow() {
    _rejoin = null;
    if (!_following) return;
    _following = false;
    unawaited(line.markFollowing(null));
    _ended(byLeader: false);
    if (!_closed) notifyListeners();
  }

  void _ended({
    required bool byLeader,
    bool stopped = false,
    String? said,
    String? note,
    SongLeader? leader,
  }) {
    final who = leader ?? _leader;
    if (who == null || _endings.isClosed) return;
    _endings.add(FollowEnded(
      leaderName: who.name,
      leaderUserId: who.userId.isEmpty ? null : who.userId,
      byLeader: byLeader,
      stopped: stopped,
      said: said ?? 'You stopped following ${who.name}.',
      note: note,
    ));
  }

  Future<void> _send(Map<String, dynamic> message) async {
    try {
      await line.sendFollow(message);
    } catch (_) {
      // One lost message is repaired by the next heartbeat.
    }
  }

  void _heard(Map<String, dynamic> message) {
    if (_closed) return;
    final device = message['device'];
    if (device is! String || device == line.device) return;
    switch (message['kind']) {
      case 'lead':
        _heardLead(device, message);
      case 'end':
        // From the leader being followed, or from the one this phone lost
        // touch with and is waiting for: the note is theirs either way.
        final who = _leader?.device == device
            ? _leader
            : (_rejoin?.device == device ? _rejoin : null);
        if (who != null) {
          _lose('${who.name} stopped leading.',
              leaderNote: _cleanNote(message['note']), stopped: true, who: who);
        }
    }
  }

  void _heardLead(String device, Map<String, dynamic> message) {
    final state = FollowState.fromJson(message['state']);
    final since = message['since'];
    if (state == null || since is! num) return;
    final name = (message['name'] as String?)?.trim();
    final who = name == null || name.isEmpty ? 'Someone' : name;

    if (_leading) {
      // Two leaders: the later press wins, and a tie goes to the device
      // that sorts first so both phones reach the same answer.
      final theirs = since.round();
      final theyWin = theirs > _since || (theirs == _since && device.compareTo(line.device) < 0);
      if (!theyWin) return;
      _leading = false;
      _lastSent = null;
      _notes.add('$who is leading now.');
    }

    // The leader this phone lost touch with is back: follow them again, as
    // it was before the signal went.
    final waitedFor = _rejoin;
    if (waitedFor != null && waitedFor.device == device && !_following && !_leading) {
      _rejoin = null;
      if (_now() < _rejoinUntil) {
        _following = true;
        _notes.add('Back with $who.');
      }
    }

    final previous = _leader;
    if (previous == null || previous.device != device) {
      _clock.reset();
      if (_following && previous != null) _notes.add('Now following $who.');
    }
    final receivedAt = _now();
    _clock.heard(sentAt: state.sentAt, receivedAt: receivedAt);
    _leader = SongLeader(
      device: device,
      userId: message['user'] as String? ?? '',
      name: who,
      since: since.round(),
      state: state,
      heardAt: receivedAt,
    );
    if (_following) {
      // Told to presence only when who is followed changes. Saying it again
      // on every heartbeat was a loop on the first two-phone test: each
      // re-announcement reaches the leader as its follower leaving and
      // arriving, the leader answers an arrival at once, and the answer
      // prompts the next re-announcement -- as fast as the network goes,
      // until the server stops carrying the song's messages at all.
      if (previous?.device != device) unawaited(line.markFollowing(device));
      _states.add(state);
    }
    _watchForQuiet();
    // Only when something a screen shows has changed: a heartbeat that
    // says the same thing again should not rebuild the song.
    if (previous == null || previous.device != device || !previous.state.sameDecisions(state)) {
      notifyListeners();
    }
  }

  void _heardDevices(List<SongDevice> devices) {
    if (_closed) return;
    _here = devices;
    // A leader missing from this list is not taken as gone. Phones drop
    // off presence for a second when the signal flickers, and a lesson that
    // stops following every time the teacher walks past the microwave is
    // worse than one that notices a real departure nine seconds late: an
    // 'end' says so at once, and silence says so after [quietAfterMs].
    //
    // Somebody new arrived while this phone leads: tell them now rather than
    // at the next heartbeat. New means never seen on this song -- not merely
    // absent from the last list, which is what a phone that updates its
    // presence looks like for a moment (see _heardLead).
    var arrived = false;
    for (final each in devices) {
      if (_seen.add(each.device)) arrived = true;
    }
    if (_leading && arrived) _lastSent = null;
    notifyListeners();
  }

  void _watchForQuiet() {
    _quiet ??= Timer.periodic(const Duration(seconds: 2), (_) => checkQuiet());
  }

  /// Drops a leader nothing has been heard from in a while. Public so a
  /// test can ask without waiting.
  void checkQuiet() {
    final now = _now();
    final last = _lastQuietCheck;
    _lastQuietCheck = now;
    final leader = _leader;
    if (leader == null) {
      _quiet?.cancel();
      _quiet = null;
      _lastQuietCheck = null;
      return;
    }
    // This check is itself late, so this phone was the one stalled: the
    // leader's messages may be waiting in the queue behind it. Look again
    // at the next check rather than blame the leader for this phone's pause.
    if (last != null && now - last > 5000) return;
    if (now - leader.heardAt > quietAfterMs) _lose('Lost touch with ${leader.name}.');
  }

  void _lose(String said, {String? leaderNote, bool stopped = false, SongLeader? who}) {
    final leader = who ?? _leader;
    if (leader == null) return;
    final wasFollowing = _following;
    final waitedFor = _rejoin?.device == leader.device && _now() < _rejoinUntil;
    if (_leader?.device == leader.device) {
      _leader = null;
      _clock.reset();
      _quiet?.cancel();
      _quiet = null;
      _lastQuietCheck = null;
    }
    if (wasFollowing) {
      _following = false;
      unawaited(line.markFollowing(null));
    }
    if (wasFollowing || (stopped && waitedFor)) {
      if (stopped) {
        _rejoin = null;
        _notes.add(said);
      } else {
        _rejoin = leader;
        _rejoinUntil = _now() + rejoinWithinMs;
        _notes.add('$said Following again if they come back.');
      }
      _ended(byLeader: true, stopped: stopped, said: said, note: leaderNote, leader: leader);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    // Closed first, so leaving says goodbye to the others without telling
    // a screen that is already gone.
    _closed = true;
    stopLeading();
    unfollow();
    _quiet?.cancel();
    unawaited(_messagesSub.cancel());
    unawaited(_devicesSub.cancel());
    unawaited(_states.close());
    unawaited(_notes.close());
    unawaited(_endings.close());
    super.dispose();
  }
}
