import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

/// One entry in a song's stream — someone talking, or the app reporting.
class ProjectEvent {
  const ProjectEvent({
    required this.id,
    required this.kind,
    required this.body,
    required this.createdAt,
    this.actorId,
    this.actorName,
  });

  final String id;

  /// 'message' when a person said it. Anything else the app did.
  final String kind;
  final String body;
  final DateTime createdAt;
  final String? actorId;
  final String? actorName;

  bool get isMessage => kind == 'message';

  /// The app's line, written as a sentence about the person who caused it.
  /// Kept here rather than in the database so the wording can change without
  /// rewriting history — the row records what happened, not how to say it.
  String get systemText {
    final who = actorName ?? 'Someone';
    return switch (kind) {
      'edited' => '$who is working on the lyrics',
      'analyzed' => '$who analyzed the recording',
      'recording' => '$who added a recording',
      'joined' => '$who joined this song',
      _ => body.isEmpty ? '$who did something' : '$who $body',
    };
  }

  factory ProjectEvent.fromRow(Map<String, dynamic> row) {
    final author = row['author'];
    return ProjectEvent(
      id: row['id'] as String,
      kind: row['kind'] as String? ?? 'message',
      body: row['body'] as String? ?? '',
      createdAt: DateTime.parse(row['created_at'] as String).toLocal(),
      actorId: row['actor_id'] as String?,
      actorName: author is Map ? author['display_name'] as String? : null,
    );
  }
}

/// Someone who currently has this song open.
class CoworkPresence {
  const CoworkPresence({required this.userId, required this.displayName});

  final String userId;
  final String displayName;
}

/// The shared workspace around one song: the stream, and who else is here.
///
/// Presence is deliberately scoped to a song rather than to the app. It costs
/// a live connection, and the app already learned what an always-on socket
/// does to a phone in a pocket — so this one is opened when somebody opens
/// the song and closed when they leave. Which is also the only window in
/// which "Jess is here" means anything.
class CoworkService {
  CoworkService({SupabaseClient? client}) : _clientOverride = client;

  final SupabaseClient? _clientOverride;
  SupabaseClient get client => _clientOverride ?? Supabase.instance.client;

  RealtimeChannel? _channel;
  final _events = StreamController<List<ProjectEvent>>.broadcast();
  final _presence = StreamController<List<CoworkPresence>>.broadcast();

  Stream<List<ProjectEvent>> get events => _events.stream;
  Stream<List<CoworkPresence>> get presence => _presence.stream;

  /// Most recent first from the database, reversed so the newest sits at the
  /// bottom where a conversation belongs.
  Future<List<ProjectEvent>> loadEvents(String projectId, {int limit = 80}) async {
    final rows = await client
        .from('project_events')
        .select('id, kind, body, created_at, actor_id, author:profiles!project_events_actor_id_fkey(display_name)')
        .eq('project_id', projectId)
        .order('created_at', ascending: false)
        .limit(limit);
    return (rows as List<dynamic>)
        .map((row) => ProjectEvent.fromRow(Map<String, dynamic>.from(row as Map)))
        .toList(growable: false)
        .reversed
        .toList(growable: false);
  }

  Future<void> send(String projectId, String body) async {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return;
    await client.from('project_events').insert(<String, dynamic>{
      'project_id': projectId,
      'actor_id': client.auth.currentUser!.id,
      'kind': 'message',
      'body': trimmed.length > 2000 ? trimmed.substring(0, 2000) : trimmed,
    });
  }

  Future<void> deleteMessage(String eventId) async {
    await client.from('project_events').delete().eq('id', eventId);
  }

  /// Opens the live connection for one song: new events as they land, and the
  /// list of who is currently looking at it.
  ///
  /// Safe to call twice — joining a song you are already in leaves the
  /// existing channel alone rather than stacking a second one, which is how
  /// duplicate messages and phantom presence entries happen.
  Future<void> join({
    required String projectId,
    required String displayName,
  }) async {
    if (_channel != null) return;
    final userId = client.auth.currentUser?.id;
    if (userId == null) return;

    final channel = client.channel(
      'song:$projectId',
      opts: const RealtimeChannelConfig(self: true),
    );
    _channel = channel;

    channel
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'project_events',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'project_id',
            value: projectId,
          ),
          // Re-reading rather than patching the local list from the payload:
          // the payload has no author name, and a stream where half the lines
          // say "Someone" until you reopen it is worse than one extra query.
          callback: (_) => unawaited(_refresh(projectId)),
        )
        .onPresenceSync((_) => _emitPresence(channel))
        .onPresenceJoin((_) => _emitPresence(channel))
        .onPresenceLeave((_) => _emitPresence(channel))
        .subscribe((status, _) async {
      if (status != RealtimeSubscribeStatus.subscribed) return;
      await channel.track(<String, dynamic>{
        'user_id': userId,
        'display_name': displayName,
      });
    });

    await _refresh(projectId);
  }

  Future<void> _refresh(String projectId) async {
    try {
      _events.add(await loadEvents(projectId));
    } catch (_) {
      // A stream that fails to refresh keeps showing what it last had, which
      // is better than emptying itself because one query timed out.
    }
  }

  void _emitPresence(RealtimeChannel channel) {
    final seen = <String, CoworkPresence>{};
    for (final state in channel.presenceState()) {
      for (final entry in state.presences) {
        final payload = entry.payload;
        final id = payload['user_id'] as String?;
        if (id == null) continue;
        // Keyed by user rather than by connection: one person with the song
        // open on a phone and a tablet is one person in the room.
        seen[id] = CoworkPresence(
          userId: id,
          displayName: payload['display_name'] as String? ?? 'Someone',
        );
      }
    }
    _presence.add(seen.values.toList(growable: false));
  }

  /// Closes the live connection. Called when the song closes — see the note
  /// on this class about why presence is scoped this narrowly.
  Future<void> leave() async {
    final channel = _channel;
    _channel = null;
    if (channel == null) return;
    try {
      await channel.untrack();
    } catch (_) {
      // Leaving a channel that is already gone is not a failure.
    }
    await client.removeChannel(channel);
  }

  Future<void> dispose() async {
    await leave();
    await _events.close();
    await _presence.close();
  }
}
