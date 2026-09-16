import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

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

  /// The leader's wall clock, in milliseconds since the epoch.
  final int sentAt;

  bool get looping => loopStartMs != null && loopEndMs != null && loopEndMs! > loopStartMs!;

  /// Everything but the moving parts: a change here is a decision somebody
  /// made, and is sent at once.
  bool sameDecisions(FollowState other) =>
      sheet == other.sheet &&
      synced == other.synced &&
      playing == other.playing &&
      rate == other.rate &&
      loopStartMs == other.loopStartMs &&
      loopEndMs == other.loopEndMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'sheet': sheet,
        'synced': synced,
        'playing': playing,
        'at': positionMs,
        'rate': rate,
        'sent': sentAt,
        if (looping) 'loop': <int>[loopStartMs!, loopEndMs!],
        if (lineKey != null) 'line': lineKey,
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

  /// Nothing heard from a leader for this long means they are gone, even
  /// if the connection has not said so yet.
  static const int quietAfterMs = 9000;

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

  /// Where the leader's song is right now, or null with nobody leading.
  int? targetMs() {
    final leader = _leader;
    if (leader == null) return null;
    return followTargetMs(leader.state, _clock.leaderNow(_now()));
  }

  void lead() {
    if (_closed || _leading) return;
    if (_following) {
      _following = false;
      unawaited(line.markFollowing(null));
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

  void stopLeading() {
    if (!_leading) return;
    _leading = false;
    _lastSent = null;
    unawaited(_send(<String, dynamic>{'kind': 'end', 'device': line.device}));
    if (!_closed) notifyListeners();
  }

  /// Follows whoever is leading, and hands the screen their latest state.
  void follow() {
    final leader = _leader;
    if (_closed || leader == null) return;
    if (_leading) stopLeading();
    _following = true;
    unawaited(line.markFollowing(leader.device));
    notifyListeners();
    _states.add(leader.state);
  }

  void unfollow() {
    if (!_following) return;
    _following = false;
    unawaited(line.markFollowing(null));
    if (!_closed) notifyListeners();
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
        if (_leader?.device == device) _lose('${_leader!.name} stopped leading.');
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
    final leader = _leader;
    if (leader == null) {
      _quiet?.cancel();
      _quiet = null;
      return;
    }
    if (_now() - leader.heardAt > quietAfterMs) _lose('Lost touch with ${leader.name}.');
  }

  void _lose(String note) {
    final wasFollowing = _following;
    _leader = null;
    _clock.reset();
    _quiet?.cancel();
    _quiet = null;
    if (wasFollowing) {
      _following = false;
      unawaited(line.markFollowing(null));
      _notes.add(note);
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
    super.dispose();
  }
}
