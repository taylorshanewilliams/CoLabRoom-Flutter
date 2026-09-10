import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'error_reporter.dart';

/// Who is here right now.
///
/// The other half of availability. A status somebody set lasts a fortnight
/// and answers "is it worth asking at all"; this lasts as long as the app is
/// open and answers "message them now". Taylor asked for both — "i want
/// millions of users" — so this is built to be true at four people and still
/// true at four million.
///
/// **Why a channel per person, rather than one channel for everybody.**
/// Supabase presence delivers every join and leave on a channel to everybody
/// subscribed to it. One global `presence:people` channel would therefore
/// hand every client the comings and goings of every user in the product —
/// fine at four, ruinous at four thousand, and the sort of thing that works
/// perfectly until the week it matters.
///
/// So each person tracks themselves on a channel named after them, and you
/// subscribe to the channels of the people you are actually looking at. The
/// traffic any one client sees is bounded by *its own* friend count, which is
/// a band, not a product. Nobody ever receives an event about a stranger.
///
/// The cost is one subscription per watched person, so [watch] takes a cap.
/// Somebody with four hundred connections gets the first [maxWatched] of them
/// rather than four hundred sockets.
class PeoplePresence {
  PeoplePresence({SupabaseClient? client}) : _clientOverride = client;

  /// One per app. Announcing has to outlive the People screen — presence that
  /// only exists while you are looking at the presence screen would mean two
  /// people could never see each other unless both were staring at the same
  /// list.
  static final PeoplePresence instance = PeoplePresence();

  final SupabaseClient? _clientOverride;
  SupabaseClient get _client => _clientOverride ?? Supabase.instance.client;

  /// How many people are watched at once.
  ///
  /// A band is under ten. This is set well past any real list and well short
  /// of a number of sockets that would matter.
  static const int maxWatched = 60;

  static String channelFor(String userId) => 'presence:user:$userId';

  RealtimeChannel? _mine;
  final Map<String, RealtimeChannel> _watching = <String, RealtimeChannel>{};
  final Set<String> _online = <String>{};
  final _changes = StreamController<Set<String>>.broadcast();

  /// The ids of watched people currently online.
  Stream<Set<String>> get online => _changes.stream;

  /// A snapshot, for a first build before the stream has said anything.
  Set<String> get onlineNow => Set<String>.unmodifiable(_online);

  /// Say that you are here.
  ///
  /// Called once, when somebody is signed in and the app is open — not when
  /// the People screen opens. Presence that only exists while you are looking
  /// at the presence screen would mean two people could never see each other
  /// unless both were staring at the same list.
  Future<void> announce({required String userId}) async {
    if (_mine != null) return;
    try {
      final channel = _client.channel(
        channelFor(userId),
        opts: const RealtimeChannelConfig(self: true),
      );
      _mine = channel;
      channel.subscribe((status, _) async {
        if (status != RealtimeSubscribeStatus.subscribed) return;
        // Nothing about the person in the payload. Anybody subscribed to this
        // channel already knows who it belongs to — it is named after them —
        // and a name in a presence payload is a name handed to whoever joins.
        await channel.track(<String, dynamic>{'at': DateTime.now().toIso8601String()});
      });
    } catch (error) {
      // Presence is a garnish on a list that works without it. It must never
      // be the reason a screen fails to open.
      _mine = null;
      unawaited(ErrorReporter().reportWarning(
        service: 'app', stage: 'presence.announce', message: error.toString()));
    }
  }

  /// Watch these people, and stop watching anybody not in the list.
  ///
  /// Safe to call on every rebuild: channels already open are left alone, so
  /// a list that has not changed costs nothing.
  Future<void> watch(Iterable<String> userIds) async {
    final wanted = userIds.take(maxWatched).toSet();

    for (final id in _watching.keys.toList(growable: false)) {
      if (wanted.contains(id)) continue;
      await _drop(id);
    }

    for (final id in wanted) {
      if (_watching.containsKey(id)) continue;
      try {
        final channel = _client.channel(
          channelFor(id),
          opts: const RealtimeChannelConfig(self: true),
        );
        _watching[id] = channel;
        channel
            .onPresenceSync((_) => _recount(id, channel))
            .onPresenceJoin((_) => _recount(id, channel))
            .onPresenceLeave((_) => _recount(id, channel))
            .subscribe();
        // Subscribed without tracking. Watching somebody must not make it
        // look to them as though you are standing on their channel.
      } catch (error) {
        _watching.remove(id);
        unawaited(ErrorReporter().reportWarning(
          service: 'app', stage: 'presence.watch', message: error.toString()));
      }
    }
  }

  void _recount(String userId, RealtimeChannel channel) {
    var present = false;
    for (final state in channel.presenceState()) {
      if (state.presences.isNotEmpty) {
        present = true;
        break;
      }
    }
    final changed = present ? _online.add(userId) : _online.remove(userId);
    if (changed) _changes.add(Set<String>.unmodifiable(_online));
  }

  Future<void> _drop(String userId) async {
    final channel = _watching.remove(userId);
    _online.remove(userId);
    if (channel == null) return;
    try {
      await _client.removeChannel(channel);
    } catch (_) {
      // Already gone.
    }
  }

  /// Stop watching everybody, keeping your own announcement.
  ///
  /// Called when the People screen closes. You stay visible to others; you
  /// simply stop paying for a socket per friend while looking at something
  /// else.
  Future<void> stopWatching() async {
    for (final id in _watching.keys.toList(growable: false)) {
      await _drop(id);
    }
    if (!_changes.isClosed) _changes.add(const <String>{});
  }

  /// Signing out, or closing the app.
  Future<void> leave() async {
    await stopWatching();
    final channel = _mine;
    _mine = null;
    if (channel == null) return;
    try {
      await channel.untrack();
      await _client.removeChannel(channel);
    } catch (_) {
      // Already gone.
    }
  }

  Future<void> dispose() async {
    await leave();
    await _changes.close();
  }
}
