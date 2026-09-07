import 'dart:async';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/activity.dart';
import '../domain/music_models.dart';
import '../domain/name_policy.dart';
import '../domain/song_analysis_models.dart' show SongAnalysisState;
import 'music_repository.dart';
import '../services/error_reporter.dart';

class SupabaseMusicRepository implements MusicRepository {
  SupabaseMusicRepository(this.client) {
    _channel = _openChannel();
  }

  /// Subscribes to everything the workspace shows, so a change made by anyone
  /// in the band appears without a refresh.
  ///
  /// A websocket is the right shape while somebody is looking at the app and
  /// exactly the wrong shape the moment they aren't: a socket keeping its
  /// heartbeat going — and reconnecting, and reconnecting again as the radio
  /// comes and goes — through a night of dozing is a phone that never gets to
  /// sleep. See [pauseLiveUpdates].
  RealtimeChannel _openChannel() {
    return client
        .channel('music-beta-${client.auth.currentUser?.id ?? 'anonymous'}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'rooms',
          callback: (_) => _notifyChanged(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'room_members',
          callback: (_) => _notifyChanged(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'projects',
          callback: (_) => _notifyChanged(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'contributions',
          // The loudest table in the app by a wide margin, and the only one
          // a person writes to continuously. Every keystroke batch that saved
          // a line announced itself back to the phone that had just written
          // it, which then re-read every word of every song in the account —
          // on top of the reload the save itself had already asked for.
          //
          // A change to one song refreshes that song. A change this person
          // made is dropped outright: their own screen is already correct,
          // and the write path updated it.
          callback: _onContributionChanged,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'files',
          callback: (_) => _notifyChanged(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'setlists',
          callback: (_) => _notifyChanged(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'setlist_projects',
          callback: (_) => _notifyChanged(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'invitations',
          callback: (_) => _notifyChanged(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'notifications',
          callback: (_) => _notifyChanged(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'notification_preferences',
          callback: (_) => _notifyChanged(),
        )
        .subscribe();
  }

  final SupabaseClient client;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  final StreamController<String> _projectChanges =
      StreamController<String>.broadcast();
  late RealtimeChannel _channel;
  bool _live = true;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Stream<String> get projectChanges => _projectChanges.stream;

  /// Closes the live connection while the app is in the background.
  ///
  /// Nothing is lost by doing this: [resumeLiveUpdates] reloads, which picks
  /// up everything that happened in the meantime. What is gained is a phone
  /// that can actually idle — this socket was the app's largest reason to
  /// keep waking the radio, and it was doing it to watch for changes nobody
  /// was there to see.
  @override
  void pauseLiveUpdates() {
    if (!_live) return;
    _live = false;
    client.removeChannel(_channel);
  }

  @override
  void resumeLiveUpdates() {
    if (_live) return;
    _live = true;
    _channel = _openChannel();
    // Whatever changed while the socket was closed is caught by the reload
    // the controller runs on resume, not by replaying missed events.
  }

  void _notifyChanged() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _onContributionChanged(PostgresChangePayload payload) {
    final row = payload.newRecord.isNotEmpty ? payload.newRecord : payload.oldRecord;
    final author = row['author_id'] as String?;
    // Mine, and already on screen.
    if (author != null && author == client.auth.currentUser?.id) return;

    final projectId = row['project_id'] as String?;
    if (projectId == null) {
      _notifyChanged();
      return;
    }
    if (!_projectChanges.isClosed) _projectChanges.add(projectId);
  }

  String get _userId {
    final id = client.auth.currentUser?.id;
    if (id == null) throw const AuthException('Sign in to open your songs.');
    return id;
  }

  @override
  Future<List<MusicRoom>> loadRooms() async {
    final rows = await client
        .from('rooms')
        .select(
          'id, account_id, name, icon, created_at, updated_at, sort_order, logo_path, '
          'room_members(user_id, display_name, role, color_value, profiles(avatar_path)), '
          'projects(id, room_id, account_id, created_by, title, description, status, created_at, updated_at, sort_order, cover_image_path, '
          'project_audio_references(project_id, analysis_state), '
          'contributions(id, project_id, author_id, author_name, body, color_value, position, kind, revision, created_at, '
          'files(id, project_id, contribution_id, storage_path, mime_type, byte_size, duration_ms, created_at)))',
        )
        .order('sort_order', ascending: true);

    return (rows as List<dynamic>)
        .map((row) => _room(Map<String, dynamic>.from(row as Map)))
        .toList(growable: false);
  }

  @override
  Future<List<BetaInvite>> loadInvites() async {
    final email = client.auth.currentUser?.email?.trim().toLowerCase();
    if (email == null || email.isEmpty) return const <BetaInvite>[];
    final rows = await client
        .from('invitations')
        .select(
          'id, room_id, project_id, email, role, rooms(name), projects(title), '
          'inviter:profiles!invitations_invited_by_fkey(display_name)',
        )
        .eq('status', 'pending')
        .ilike('email', email)
        .order('created_at', ascending: false);
    return (rows as List<dynamic>).map((value) {
      final row = Map<String, dynamic>.from(value as Map);
      final room = Map<String, dynamic>.from(row['rooms'] as Map);
      final inviter = Map<String, dynamic>.from(row['inviter'] as Map);
      final projectRow = row['projects'] as Map<String, dynamic>?;
      return BetaInvite(
        id: row['id'] as String,
        roomId: row['room_id'] as String,
        roomName: room['name'] as String,
        inviterName: inviter['display_name'] as String? ?? 'A collaborator',
        email: row['email'] as String,
        role: RoomRole.values.byName(row['role'] as String? ?? RoomRole.editor.name),
        projectId: row['project_id'] as String?,
        projectTitle: projectRow?['title'] as String?,
      );
    }).toList(growable: false);
  }

  @override
  Future<List<AppNotification>> loadNotifications() async {
    final rows = await client
        .from('notifications')
        .select()
        .order('created_at', ascending: false)
        .limit(50);
    return (rows as List<dynamic>)
        .map((row) => _notification(Map<String, dynamic>.from(row as Map)))
        .toList(growable: false);
  }

  @override
  Future<NotificationPreferences> loadNotificationPreferences() async {
    final row = await client
        .from('notification_preferences')
        .select()
        .eq('user_id', _userId)
        .maybeSingle();
    if (row == null) return const NotificationPreferences();
    return NotificationPreferences(
      invites: row['invites'] as bool? ?? true,
      inviteResponses: row['invite_responses'] as bool? ?? true,
      projectUpdates: row['project_updates'] as bool? ?? true,
    );
  }

  @override
  Future<void> setNotificationPreferences(NotificationPreferences preferences) async {
    await client.from('notification_preferences').upsert(<String, dynamic>{
      'user_id': _userId,
      'invites': preferences.invites,
      'invite_responses': preferences.inviteResponses,
      'project_updates': preferences.projectUpdates,
    });
  }

  @override
  Future<void> markNotificationRead(AppNotification notification) async {
    await client
        .from('notifications')
        .update(<String, dynamic>{'read_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', notification.id);
  }

  @override
  Future<void> deleteNotification(AppNotification notification) async {
    await client
        .from('notifications')
        .delete()
        .eq('id', notification.id)
        .eq('user_id', _userId);
  }

  @override
  Future<void> deleteReadNotifications() async {
    await client
        .from('notifications')
        .delete()
        .eq('user_id', _userId)
        .not('read_at', 'is', null);
  }

  @override
  Future<void> markAllNotificationsRead() async {
    await client
        .from('notifications')
        .update(<String, dynamic>{'read_at': DateTime.now().toUtc().toIso8601String()})
        .eq('user_id', _userId)
        .isFilter('read_at', null);
  }

  @override
  Future<List<Setlist>> loadSetlists() async {
    final rows = await client
        .from('setlists')
        .select(
          'id, owner_id, name, created_at, updated_at, '
          'setlist_projects(project_id, position)',
        )
        .order('updated_at', ascending: false);
    return (rows as List<dynamic>).map((value) {
      final row = Map<String, dynamic>.from(value as Map);
      final entries = (row['setlist_projects'] as List<dynamic>? ?? const <dynamic>[])
          .map((entry) => Map<String, dynamic>.from(entry as Map))
          .toList(growable: false)
        ..sort((left, right) =>
            (left['position'] as num).compareTo(right['position'] as num));
      return Setlist(
        id: row['id'] as String,
        ownerId: row['owner_id'] as String,
        name: row['name'] as String,
        createdAt: DateTime.parse(row['created_at'] as String),
        updatedAt: DateTime.parse(row['updated_at'] as String),
        projectIds: entries.map((entry) => entry['project_id'] as String).toList(growable: false),
      );
    }).toList(growable: false);
  }

  @override
  Future<MusicRoom> createRoom({required String name, required String icon}) async {
    final cleaned = NamePolicy.clean(name);
    NamePolicy.requireUsable(cleaned, label: 'Room name');
    try {
      final existing = await client
          .from('rooms')
          .select('sort_order')
          .eq('account_id', _userId)
          .order('sort_order', ascending: false)
          .limit(1);
      final maxSort = (existing as List<dynamic>).isEmpty
          ? 0.0
          : ((existing.first as Map)['sort_order'] as num).toDouble();
      final row = await client
          .from('rooms')
          .insert(<String, dynamic>{
            'account_id': _userId,
            'name': cleaned,
            'icon': icon,
            'sort_order': maxSort + 1024,
          })
          .select()
          .single();
      await client.from('room_members').insert(<String, dynamic>{
        'room_id': row['id'],
        'user_id': _userId,
        'display_name': client.auth.currentUser?.userMetadata?['display_name'] ?? 'Member',
        'role': RoomRole.owner.name,
        'color_value': 0xFFFF8A4C,
      });
      return _room(<String, dynamic>{
        ...row,
        'room_members': <dynamic>[],
        'projects': <dynamic>[],
      });
    } on PostgrestException catch (error) {
      throw _friendlyDatabaseError(error, noun: 'room');
    }
  }

  @override
  Future<void> reorderRooms(List<MusicRoom> orderedRooms) async {
    if (orderedRooms.isEmpty) return;
    // Single round trip via RPC (see migration 0010) instead of one UPDATE
    // per room. A naive `upsert` here won't work: Postgres validates NOT
    // NULL columns like `name`/`account_id` on the candidate insert row
    // before it even checks for a conflict, so an upsert payload with only
    // `id`/`sort_order` would fail even though every row already exists.
    await client.rpc<void>(
      'reorder_rooms',
      params: <String, dynamic>{
        'room_ids': orderedRooms.map((room) => room.id).toList(growable: false),
      },
    );
  }

  @override
  Future<MusicRoom> setRoomLogo({required MusicRoom room, required Uint8List bytes}) async {
    final path = '${room.id}/room-logo.png';
    await client.storage.from('room-files').uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(upsert: true, contentType: 'image/png'),
        );
    await client.from('rooms').update(<String, dynamic>{'logo_path': path}).eq('id', room.id);
    return room.copyWith(logoPath: path);
  }

  @override
  Future<String?> loadAvatarPath() async {
    final id = client.auth.currentUser?.id;
    if (id == null) return null;
    final row = await client.from('profiles').select('avatar_path').eq('id', id).maybeSingle();
    return row?['avatar_path'] as String?;
  }

  @override
  Future<String> setAvatar(Uint8List bytes) async {
    // '<user id>/avatar.png' — the first path segment is what the bucket's
    // policies check to decide this is yours to write (migration 0027).
    //
    // A cache-busting suffix rather than a fixed name: the path is stored on
    // the profile and read by other people's devices, and an upsert to the
    // same object leaves everyone else looking at the old picture until
    // something clears a cache nobody controls.
    final path = '$_userId/avatar-${DateTime.now().millisecondsSinceEpoch}.png';
    final previous = await loadAvatarPath();
    await client.storage.from('avatars').uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(upsert: true, contentType: 'image/png'),
        );
    await client.from('profiles').update(<String, dynamic>{'avatar_path': path}).eq('id', _userId);
    if (previous != null && previous != path) {
      // Best effort. An orphaned image costs a few kilobytes; failing the
      // change because the old one wouldn't delete costs the user their new
      // picture.
      try {
        await client.storage.from('avatars').remove(<String>[previous]);
      } catch (error) {
        // The new picture is already saved, so this must not fail the change.
        // Counted because an orphan is not free: storage is the one line on
        // this bill that is paid again every month, on everything ever
        // uploaded, and a cleanup that silently never runs is a cost that
        // only ever grows.
        unawaited(ErrorReporter().reportWarning(
          service: 'app', stage: 'avatar_cleanup', message: error.toString()));
      }
    }
    return path;
  }

  @override
  Future<void> clearAvatar() async {
    final previous = await loadAvatarPath();
    await client.from('profiles').update(<String, dynamic>{'avatar_path': null}).eq('id', _userId);
    if (previous != null) {
      try {
        await client.storage.from('avatars').remove(<String>[previous]);
      } catch (_) {}
    }
  }

  @override
  Future<Uint8List> loadAvatar(String path) {
    return client.storage.from('avatars').download(path);
  }

  @override
  Future<MusicRoom> clearRoomLogo(MusicRoom room) async {
    if (room.logoPath != null) {
      await client.storage.from('room-files').remove(<String>[room.logoPath!]);
    }
    await client.from('rooms').update(<String, dynamic>{'logo_path': null}).eq('id', room.id);
    return room.copyWith(logoPath: null);
  }

  @override
  Future<Uint8List> loadRoomLogo(MusicRoom room) {
    return client.storage.from('room-files').download(room.logoPath!);
  }

  @override
  Future<MusicRoom> renameRoom({required MusicRoom room, required String name}) async {
    final cleaned = NamePolicy.clean(name);
    NamePolicy.requireUsable(cleaned, label: 'Room name');
    try {
      final row = await client
          .from('rooms')
          .update(<String, dynamic>{'name': cleaned})
          .eq('id', room.id)
          .select()
          .single();
      return _room(<String, dynamic>{
        ...row,
        'room_members': room.members.map(_memberJson).toList(growable: false),
        'projects': room.projects.map(_projectJson).toList(growable: false),
      });
    } on PostgrestException catch (error) {
      throw _friendlyDatabaseError(error, noun: 'room');
    }
  }

  @override
  Future<void> deleteRoom(MusicRoom room) async {
    // Members/projects/contributions/files all cascade off `rooms` via
    // `on delete cascade` foreign keys, so one delete is enough.
    await client.from('rooms').delete().eq('id', room.id);
  }

  @override
  Future<SongProject> createSong({required MusicRoom room, required String title}) async {
    final cleaned = NamePolicy.clean(title);
    NamePolicy.requireUsable(cleaned, label: 'Song name');
    try {
      final existing = await client
          .from('projects')
          .select('sort_order')
          .eq('room_id', room.id)
          .order('sort_order', ascending: false)
          .limit(1);
      final maxSort = (existing as List<dynamic>).isEmpty
          ? 0.0
          : ((existing.first as Map)['sort_order'] as num).toDouble();
      final row = await client
          .from('projects')
          .insert(<String, dynamic>{
            'room_id': room.id,
            'account_id': room.accountId,
            'title': cleaned,
            'sort_order': maxSort + 1024,
          })
          .select()
          .single();
      return _project(<String, dynamic>{...row, 'contributions': <dynamic>[]});
    } on PostgrestException catch (error) {
      throw _friendlyDatabaseError(error, noun: 'project');
    }
  }

  @override
  Future<SongProject> renameSong({required SongProject project, required String title}) async {
    final cleaned = NamePolicy.clean(title);
    NamePolicy.requireUsable(cleaned, label: 'Song name');
    try {
      final row = await client
          .from('projects')
          .update(<String, dynamic>{'title': cleaned})
          .eq('id', project.id)
          .select()
          .single();
      return _project(<String, dynamic>{
        ...row,
        'contributions': project.contributions.map(_contributionJson).toList(growable: false),
        'project_audio_references': project.hasAudioReference
            ? <String, dynamic>{'analysis_state': project.analysisState?.name}
            : null,
      });
    } on PostgrestException catch (error) {
      throw _friendlyDatabaseError(error, noun: 'project');
    }
  }

  @override
  Future<SongProject> setSongStatus({required SongProject project, required SongStatus status}) async {
    final row = await client
        .from('projects')
        .update(<String, dynamic>{'status': status.name})
        .eq('id', project.id)
        .select()
        .single();
    return _project(<String, dynamic>{
      ...row,
      'contributions': project.contributions.map(_contributionJson).toList(growable: false),
      'project_audio_references': project.hasAudioReference
          ? <String, dynamic>{'analysis_state': project.analysisState?.name}
          : null,
    });
  }

  @override
  Future<void> reorderRoomProjects(MusicRoom room, List<String> orderedProjectIds) async {
    if (orderedProjectIds.isEmpty) return;
    // Same one-round-trip-RPC approach as reorderRooms (see migration 0012):
    // an upsert would fail the NOT NULL check on `title`/`account_id` for a
    // payload carrying only `id`/`sort_order`.
    await client.rpc<void>(
      'reorder_room_projects',
      params: <String, dynamic>{
        'project_ids': orderedProjectIds,
      },
    );
  }

  @override
  Future<SongProject> setProjectCover({required SongProject project, required Uint8List bytes}) async {
    final path = '${project.roomId}/${project.id}-cover.png';
    await client.storage.from('room-files').uploadBinary(
          path,
          bytes,
          fileOptions: const FileOptions(upsert: true, contentType: 'image/png'),
        );
    await client.from('projects').update(<String, dynamic>{'cover_image_path': path}).eq('id', project.id);
    return project.copyWith(coverImagePath: path);
  }

  @override
  Future<SongProject> clearProjectCover(SongProject project) async {
    if (project.coverImagePath != null) {
      await client.storage.from('room-files').remove(<String>[project.coverImagePath!]);
    }
    await client.from('projects').update(<String, dynamic>{'cover_image_path': null}).eq('id', project.id);
    return project.copyWith(coverImagePath: null);
  }

  @override
  Future<Uint8List> loadProjectCover(SongProject project) {
    return client.storage.from('room-files').download(project.coverImagePath!);
  }

  @override
  Future<void> deleteSong(SongProject project) async {
    // Files/contributions/setlist_projects all cascade off `projects` via
    // `on delete cascade` foreign keys, so one delete is enough.
    await client.from('projects').delete().eq('id', project.id);
  }

  @override
  Future<Contribution> addContribution({
    required SongProject project,
    required String body,
    int colorValue = 0xFFFF8A4C,
    double? position,
  }) async {
    final cleaned = body.trim();
    if (cleaned.isEmpty) throw const NameConflict('Write something before adding it.');
    final user = client.auth.currentUser;
    final row = await client
        .from('contributions')
        .insert(<String, dynamic>{
          'project_id': project.id,
          'author_id': _userId,
          'author_name': user?.userMetadata?['display_name'] ?? 'Member',
          'body': cleaned,
          'color_value': colorValue,
          if (position != null) 'position': position,
        })
        .select()
        .single();
    return _contribution(row);
  }

  @override
  Future<Contribution> updateContribution({
    required Contribution contribution,
    required String body,
  }) async {
    final cleaned = body.trim();
    if (cleaned.isEmpty) throw const NameConflict('A lyric line cannot be empty.');
    final row = await client
        .from('contributions')
        .update(<String, dynamic>{'body': cleaned})
        .eq('id', contribution.id)
        .select()
        .single();
    return _contribution(<String, dynamic>{
      ...Map<String, dynamic>.from(row),
      'files': contribution.voiceNote == null
          ? const <dynamic>[]
          : <Map<String, dynamic>>[_voiceNoteJson(contribution.voiceNote!)],
    });
  }

  @override
  Future<void> deleteContribution(Contribution contribution) async {
    final note = contribution.voiceNote;
    if (note != null) await deleteVoiceNote(note);
    await client.from('contributions').delete().eq('id', contribution.id);
  }

  @override
  Future<List<Contribution>> importContributions({
    required SongProject project,
    required List<ContributionDraft> drafts,
    int colorValue = 0xFFFF8A4C,
  }) async {
    final cleaned = drafts
        .where((draft) => draft.body.trim().isNotEmpty)
        .take(500)
        .toList(growable: false);
    if (cleaned.isEmpty) throw const NameConflict('There are no lyric lines to import.');
    final user = client.auth.currentUser;
    var position = project.contributions.isEmpty
        ? 1024.0
        : project.contributions
                .map((line) => line.position)
                .reduce((left, right) => left > right ? left : right) +
            1024;
    final rows = await client
        .from('contributions')
        .insert(
          cleaned
              .map((draft) {
                    final row = <String, dynamic>{
                      'project_id': project.id,
                      'author_id': _userId,
                      'author_name': user?.userMetadata?['display_name'] ?? 'Member',
                      'body': draft.body.trim(),
                      'color_value': colorValue,
                      'position': position,
                      'kind': draft.kind.name,
                    };
                    position += 1024;
                    return row;
                  })
              .toList(growable: false),
        )
        .select();
    return (rows as List<dynamic>)
        .map((row) => _contribution(Map<String, dynamic>.from(row as Map)))
        .toList(growable: false);
  }

  @override
  Future<VoiceNote> attachVoiceNote({
    required SongProject project,
    required Contribution contribution,
    required Uint8List bytes,
    required int durationMs,
  }) async {
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    final storagePath = '${project.roomId}/${project.id}/voice/${contribution.id}/$timestamp.wav';
    await client.storage.from('room-files').uploadBinary(
          storagePath,
          bytes,
          fileOptions: const FileOptions(contentType: 'audio/wav', upsert: false),
        );
    final previous = contribution.voiceNote;
    try {
      if (previous != null) {
        await client.storage.from('room-files').remove(<String>[previous.storagePath]);
        await client.from('files').delete().eq('id', previous.id);
      }
      final row = await client
          .from('files')
          .insert(<String, dynamic>{
            'project_id': project.id,
            'contribution_id': contribution.id,
            'uploaded_by': _userId,
            'storage_path': storagePath,
            'display_name': 'Voice note.wav',
            'mime_type': 'audio/wav',
            'byte_size': bytes.length,
            'duration_ms': durationMs,
          })
          .select()
          .single();
      return _voiceNote(Map<String, dynamic>.from(row));
    } catch (_) {
      await client.storage.from('room-files').remove(<String>[storagePath]);
      rethrow;
    }
  }

  @override
  Future<Uint8List> loadVoiceNote(VoiceNote note) {
    return client.storage.from('room-files').download(note.storagePath);
  }

  @override
  Future<void> deleteVoiceNote(VoiceNote note) async {
    await client.storage.from('room-files').remove(<String>[note.storagePath]);
    await client.from('files').delete().eq('id', note.id);
  }

  @override
  Future<Setlist> createSetlist(String name) async {
    final cleaned = NamePolicy.clean(name);
    NamePolicy.requireUsable(cleaned, label: 'Setlist name');
    try {
      final row = await client
          .from('setlists')
          .insert(<String, dynamic>{'owner_id': _userId, 'name': cleaned})
          .select()
          .single();
      return Setlist(
        id: row['id'] as String,
        ownerId: row['owner_id'] as String,
        name: row['name'] as String,
        createdAt: DateTime.parse(row['created_at'] as String),
        updatedAt: DateTime.parse(row['updated_at'] as String),
      );
    } on PostgrestException catch (error) {
      throw _friendlyDatabaseError(error, noun: 'setlist');
    }
  }

  @override
  Future<void> addProjectsToSetlist(Setlist setlist, Iterable<String> projectIds) async {
    final existing = setlist.projectIds.toSet();
    var position = setlist.projectIds.length;
    final rows = <Map<String, dynamic>>[];
    for (final projectId in projectIds) {
      if (!existing.add(projectId)) continue;
      rows.add(<String, dynamic>{
        'setlist_id': setlist.id,
        'project_id': projectId,
        'position': position++,
      });
    }
    if (rows.isEmpty) return;
    await client.from('setlist_projects').insert(rows);
  }

  @override
  Future<void> removeProjectFromSetlist(Setlist setlist, String projectId) async {
    await client
        .from('setlist_projects')
        .delete()
        .eq('setlist_id', setlist.id)
        .eq('project_id', projectId);
  }

  @override
  Future<void> reorderSetlistProjects(Setlist setlist, List<String> orderedProjectIds) async {
    if (orderedProjectIds.isEmpty) return;
    // Safe to upsert in one round trip here (unlike rooms): every column on
    // `setlist_projects` besides the two we're setting has a default, so
    // there's no NOT-NULL gap on the insert branch of the upsert.
    await client.from('setlist_projects').upsert(
      <Map<String, dynamic>>[
        for (var index = 0; index < orderedProjectIds.length; index += 1)
          <String, dynamic>{
            'setlist_id': setlist.id,
            'project_id': orderedProjectIds[index],
            'position': index,
          },
      ],
      onConflict: 'setlist_id,project_id',
    );
  }

  @override
  Future<SongProject?> loadProject(String projectId) async {
    // The same shape loadRooms asks for per project, so _project parses it
    // unchanged and a refreshed song cannot differ from a loaded one.
    final row = await client
        .from('projects')
        .select(
          'id, room_id, account_id, created_by, title, description, status, created_at, updated_at, sort_order, cover_image_path, '
          'project_audio_references(project_id, analysis_state), '
          'contributions(id, project_id, author_id, author_name, body, color_value, position, kind, revision, created_at, '
          'files(id, project_id, contribution_id, storage_path, mime_type, byte_size, duration_ms, created_at))',
        )
        .eq('id', projectId)
        .maybeSingle();
    if (row == null) return null;
    return _project(Map<String, dynamic>.from(row));
  }

  @override
  Future<Map<String, int>> loadUnheardTakeCounts() async {
    // One round trip for the whole library rather than a query per song. The
    // counting, the "not my own takes" rule and the room-membership check all
    // live in the function, so this cannot drift from what the badge means.
    final rows = await client.rpc<List<dynamic>>('unheard_take_counts');
    return <String, int>{
      for (final row in rows)
        (row as Map<String, dynamic>)['project_id'] as String:
            (row['unheard'] as num).toInt(),
    };
  }

  @override
  Future<List<ActivityItem>> loadActivity({int limit = 20}) async {
    // One function rather than a query built here. "What counts as activity"
    // is three rules that have to agree — not yours, not dismissed, not on a
    // deleted song — and the first of them was already wrong once when it
    // lived in this file: `actor_id <> me` silently drops the rows where
    // actor_id is null, which is every system event and everyone whose
    // account has been deleted. Written once in SQL, it can only be wrong in
    // one place. RLS still decides which projects are visible at all.
    final rows = await client.rpc<List<dynamic>>(
      'recent_activity',
      params: <String, dynamic>{'max_rows': limit},
    );

    return <ActivityItem>[
      for (final value in rows)
        if (value is Map)
          () {
            final row = Map<String, dynamic>.from(value);
            return ActivityItem(
              id: row['id'] as String,
              projectId: row['project_id'] as String,
              projectTitle: row['project_title'] as String? ?? 'A song',
              kind: ActivityKind.parse(row['kind'] as String?),
              at: DateTime.tryParse(row['created_at'] as String? ?? '')
                      ?.toLocal() ??
                  DateTime.now(),
              actorId: row['actor_id'] as String?,
              actorName: row['actor_name'] as String?,
              actorAvatarPath: row['actor_avatar_path'] as String?,
              body: row['body'] as String? ?? '',
            );
          }(),
    ];
  }

  @override
  Future<void> dismissActivity(String eventId) async {
    await client.from('activity_dismissals').insert(<String, dynamic>{
      'profile_id': _userId,
      'event_id': eventId,
    });
  }

  @override
  Future<void> restoreActivity(String eventId) async {
    await client
        .from('activity_dismissals')
        .delete()
        .eq('profile_id', _userId)
        .eq('event_id', eventId);
  }

  @override
  Future<void> markProjectSeen(String projectId) async {
    await client.rpc<void>(
      'mark_project_seen',
      params: <String, dynamic>{'target_project': projectId},
    );
  }

  @override
  Future<void> moveProjects(Iterable<SongProject> projects, MusicRoom targetRoom) async {
    for (final project in projects) {
      if (project.roomId == targetRoom.id) continue;
      await client
          .from('projects')
          .update(<String, dynamic>{'room_id': targetRoom.id})
          .eq('id', project.id);
    }
  }

  @override
  String get currentUserId => _userId;

  @override
  Future<List<ShowcaseLink>> loadShowcase(String profileId) async {
    // Through the function rather than the table, so a blocked profile's
    // links are gone with the rest of them. A direct select would have been
    // the one surface that survived a block.
    final rows = await client.rpc<dynamic>(
      'showcase_for',
      params: <String, dynamic>{'target_profile': profileId},
    );
    return <ShowcaseLink>[
      for (final row in (rows as List<dynamic>? ?? const <dynamic>[]))
        ShowcaseLink(
          id: (row as Map<String, dynamic>)['id'] as String,
          url: row['url'] as String? ?? '',
          platform: row['platform'] as String? ?? '',
          title: row['title'] as String? ?? '',
        ),
    ];
  }

  @override
  Future<void> addShowcaseLink({required String url, String title = ''}) async {
    await client.from('profile_links').insert(<String, dynamic>{
      'profile_id': _userId,
      'url': url.trim(),
      'title': title.trim(),
      // platform is deliberately absent: the trigger derives it from the
      // host, and a client that could name it could label anything Spotify.
    });
  }

  @override
  Future<void> removeShowcaseLink(String linkId) async {
    await client.from('profile_links').delete().eq('id', linkId);
  }

  @override
  Future<String?> sharedCityWith(String profileId) async {
    final city = await client.rpc<dynamic>(
      'shared_city_with',
      params: <String, dynamic>{'other_profile': profileId},
    );
    final value = city is String ? city.trim() : '';
    return value.isEmpty ? null : value;
  }

  @override
  Future<List<Musician>> findMusicians({
    String? part,
    String? city,
    int limit = 30,
    String? soundsLike,
  }) async {
    final rows = await client.rpc<dynamic>(
      'find_musicians',
      params: <String, dynamic>{
        'in_part': part,
        'in_city': (city != null && city.trim().isNotEmpty) ? city.trim() : null,
        'in_limit': limit,
        'in_sounds_like': (soundsLike != null && soundsLike.trim().isNotEmpty)
            ? soundsLike.trim()
            : null,
      },
    );
    return <Musician>[
      for (final row in (rows as List<dynamic>? ?? const <dynamic>[]))
        _musician(Map<String, dynamic>.from(row as Map)),
    ];
  }

  @override
  Future<void> removeRoomMember({
    required String roomId,
    required String userId,
  }) async {
    await client.rpc<dynamic>(
      'remove_room_member',
      params: <String, dynamic>{'target_room': roomId, 'target_user': userId},
    );
  }

  @override
  Future<void> leaveRoom(String roomId) async {
    await client.rpc<dynamic>(
      'leave_room',
      params: <String, dynamic>{'target_room': roomId},
    );
  }

  @override
  Future<List<InvitableRoom>> roomsICanInviteTo(String profileId) async {
    final rows = await client.rpc<dynamic>(
      'rooms_i_can_invite_to',
      params: <String, dynamic>{'target_person': profileId},
    );
    return <InvitableRoom>[
      for (final row in (rows as List<dynamic>? ?? const <dynamic>[]))
        InvitableRoom(
          id: (row as Map)['id'] as String,
          name: row['name'] as String? ?? 'Room',
          songCount: (row['song_count'] as num?)?.toInt() ?? 0,
          alreadyIn: row['already_in'] as bool? ?? false,
          alreadyInvited: row['already_invited'] as bool? ?? false,
        ),
    ];
  }

  @override
  Future<void> inviteMusicianToRoom({
    required String roomId,
    required String profileId,
    String note = '',
  }) async {
    await client.rpc<dynamic>(
      'invite_musician_to_room',
      params: <String, dynamic>{
        'target_room': roomId,
        'target_person': profileId,
        'in_note': note,
      },
    );
  }

  @override
  Future<List<RoomInviteForMe>> roomInvitesForMe() async {
    final rows = await client.rpc<dynamic>('room_invites_for_me');
    return <RoomInviteForMe>[
      for (final row in (rows as List<dynamic>? ?? const <dynamic>[]))
        RoomInviteForMe(
          id: (row as Map)['id'] as String,
          roomId: row['room_id'] as String,
          roomName: row['room_name'] as String? ?? 'A room',
          invitedByName: row['invited_by_name'] as String? ?? 'Somebody',
          note: row['note'] as String? ?? '',
          createdAt: DateTime.tryParse('${row['created_at']}')?.toLocal() ??
              DateTime.now(),
        ),
    ];
  }

  @override
  Future<void> answerRoomInvite(String inviteId, {required bool accept}) async {
    await client.rpc<dynamic>(
      'answer_room_invite',
      params: <String, dynamic>{'target_invite': inviteId, 'accept': accept},
    );
  }

  @override
  Future<List<OpenMicSong>> openMicSongs({
    String? part,
    int limit = 30,
    bool includeNotAsking = false,
  }) async {
    final rows = await client.rpc<dynamic>(
      'open_mic_songs',
      params: <String, dynamic>{
        'in_part': part,
        'in_limit': limit,
        'include_not_asking': includeNotAsking,
      },
    );
    return <OpenMicSong>[
      for (final row in (rows as List<dynamic>? ?? const <dynamic>[]))
        OpenMicSong(
          id: (row as Map)['id'] as String,
          title: row['title'] as String? ?? 'A song',
          ownerId: row['owner_id'] as String?,
          ownerName: row['owner_name'] as String? ?? 'Somebody',
          putUpAt: DateTime.tryParse('${row['open_mic_at']}')?.toLocal() ??
              DateTime.now(),
          takeCount: (row['take_count'] as num?)?.toInt() ?? 0,
          askingFor: <String>[
            for (final p in (row['asking_for'] as List<dynamic>? ??
                const <dynamic>[]))
              '$p',
          ],
          storagePath: row['storage_path'] as String? ?? '',
          durationMs: (row['duration_ms'] as num?)?.toInt(),
          ownerAvatarPath: row['owner_avatar'] as String?,
        ),
    ];
  }

  @override
  Future<List<OpenMicSong>> songsBy(String profileId) async {
    final rows = await client.rpc<dynamic>(
      'songs_by',
      params: <String, dynamic>{'target_profile': profileId},
    );
    return <OpenMicSong>[
      for (final row in (rows as List<dynamic>? ?? const <dynamic>[]))
        OpenMicSong(
          id: (row as Map)['id'] as String,
          title: row['title'] as String? ?? 'A song',
          ownerId: row['owner_id'] as String?,
          ownerName: row['owner_name'] as String? ?? 'Somebody',
          putUpAt: DateTime.tryParse('${row['open_mic_at']}')?.toLocal() ??
              DateTime.now(),
          takeCount: (row['take_count'] as num?)?.toInt() ?? 0,
          askingFor: <String>[
            for (final a in (row['asking_for'] as List<dynamic>? ??
                const <dynamic>[]))
              '$a',
          ],
          theirParts: <String>[
            for (final a in (row['their_parts'] as List<dynamic>? ??
                const <dynamic>[]))
              '$a',
          ],
          storagePath: row['storage_path'] as String? ?? '',
          durationMs: (row['duration_ms'] as num?)?.toInt(),
          ownerAvatarPath: row['owner_avatar'] as String?,
        ),
    ];
  }

  @override
  Future<List<FeedTrack>> openMicFeed({int limit = 12, String? part}) async {
    final rows = await client.rpc<dynamic>(
      'open_mic_feed',
      params: <String, dynamic>{'in_limit': limit, 'in_part': part},
    );
    return <FeedTrack>[
      for (final row in (rows as List<dynamic>? ?? const <dynamic>[]))
        FeedTrack(
          id: (row as Map)['id'] as String,
          title: row['title'] as String? ?? 'A song',
          ownerId: row['owner_id'] as String?,
          ownerName: row['owner_name'] as String? ?? 'Somebody',
          ownerAvatarPath: row['owner_avatar'] as String?,
          storagePath: row['storage_path'] as String? ?? '',
          putUpAt: DateTime.tryParse('${row['open_mic_at']}')?.toLocal() ??
              DateTime.now(),
          askingFor: <String>[
            for (final a
                in (row['asking_for'] as List<dynamic>? ?? const <dynamic>[]))
              '$a',
          ],
          askNote: row['ask_note'] as String? ?? '',
          musicalKey: row['musical_key'] as String?,
          bpm: (row['bpm'] as num?)?.toDouble(),
          durationMs: (row['duration_ms'] as num?)?.toInt(),
          reason: row['reason'] as String? ?? '',
        ),
    ];
  }

  @override
  Future<OpenMicSong?> openMicSong(String projectId) async {
    final rows = await client.rpc<dynamic>(
      'open_mic_song',
      params: <String, dynamic>{'target_project': projectId},
    );
    final list = rows as List<dynamic>? ?? const <dynamic>[];
    if (list.isEmpty) return null;
    final row = list.first as Map;
    return OpenMicSong(
      id: row['id'] as String,
      title: row['title'] as String? ?? 'A song',
      ownerId: row['owner_id'] as String?,
      ownerName: row['owner_name'] as String? ?? 'Somebody',
      putUpAt:
          DateTime.tryParse('${row['open_mic_at']}')?.toLocal() ?? DateTime.now(),
      askingFor: <String>[
        for (final p
            in (row['asking_for'] as List<dynamic>? ?? const <dynamic>[]))
          '$p',
      ],
      musicalKey: row['musical_key'] as String?,
      bpm: (row['bpm'] as num?)?.toDouble(),
      askNote: row['ask_note'] as String? ?? '',
      storagePath: row['storage_path'] as String? ?? '',
      durationMs: (row['duration_ms'] as num?)?.toInt(),
      ownerAvatarPath: row['owner_avatar'] as String?,
    );
  }

  @override
  Future<SongAudience?> songAudience(String projectId) async {
    final rows = await client.rpc<dynamic>(
      'song_audience',
      params: <String, dynamic>{'target_project': projectId},
    );
    final list = rows as List<dynamic>? ?? const <dynamic>[];
    if (list.isEmpty) return null;
    final row = list.first as Map;
    return SongAudience(
      reach: switch (row['reach'] as String? ?? 'just_you') {
        'anyone' => SongReach.anyone,
        'invited' => SongReach.invited,
        'room' => SongReach.room,
        _ => SongReach.justYou,
      },
      roomName: row['room_name'] as String? ?? '',
      roomIcon: row['room_icon'] as String? ?? '',
      onOpenMic: row['on_open_mic'] as bool? ?? false,
      openMicAt: DateTime.tryParse('${row['open_mic_at']}')?.toLocal(),
      listeners: <SongListener>[
        for (final entry
            in (row['listeners'] as List<dynamic>? ?? const <dynamic>[]))
          SongListener(
            id: (entry as Map)['id'] as String? ?? '',
            name: entry['name'] as String? ?? 'Somebody',
            avatarPath: entry['avatar_path'] as String?,
            songOnly: entry['song_only'] as bool? ?? false,
          ),
      ],
    );
  }

  @override
  Future<void> putOnOpenMic(String projectId) async {
    await client.rpc<dynamic>(
      'put_on_open_mic',
      params: <String, dynamic>{'target_project': projectId},
    );
  }

  @override
  Future<void> takeOffOpenMic(String projectId) async {
    await client.rpc<dynamic>(
      'take_off_open_mic',
      params: <String, dynamic>{'target_project': projectId},
    );
  }

  @override
  Future<MusicRoom> ideasRoom() async {
    // Through the function, not two client round trips. Find-or-create from
    // here would race two simultaneous recordings into two rooms both
    // called Ideas; the function takes an advisory lock and cannot.
    final id = await client.rpc<dynamic>('ideas_catalog');
    final rooms = await loadRooms();
    return rooms.firstWhere(
      (room) => room.id == id,
      orElse: () => throw StateError('The Ideas room could not be opened.'),
    );
  }

  @override
  Future<SongProject> startIdea({String? title}) async {
    final room = await ideasRoom();
    final wanted = (title ?? '').trim();
    return createSong(
      room: room,
      title: wanted.isEmpty ? _ideaName() : wanted,
    );
  }

  /// A name that is not "Untitled".
  ///
  /// Recordings arrive before anybody has decided what the song is, and a
  /// library of things called Untitled is a library nobody can search. The
  /// date and time is at least a fact somebody can recognise, and the app
  /// renames it from what was sung as soon as it knows.
  String _ideaName() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return 'Idea ${two(now.month)}/${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}';
  }

  @override
  Future<void> blockUser(String profileId) async {
    await client.rpc<dynamic>(
      'block_user',
      params: <String, dynamic>{'target_person': profileId},
    );
  }

  @override
  Future<void> unblockUser(String profileId) async {
    await client.rpc<dynamic>(
      'unblock_user',
      params: <String, dynamic>{'target_person': profileId},
    );
  }

  @override
  Future<List<BlockedPerson>> peopleIBlocked() async {
    final rows = await client.rpc<dynamic>('people_i_blocked');
    return <BlockedPerson>[
      for (final row in (rows as List<dynamic>? ?? const <dynamic>[]))
        BlockedPerson(
          id: (row as Map)['id'] as String,
          displayName: row['display_name'] as String? ?? 'Someone',
          blockedAt: DateTime.tryParse('${row['blocked_at']}')?.toLocal() ??
              DateTime.now(),
        ),
    ];
  }

  @override
  Future<void> reportContent({
    required String kind,
    required String reason,
    String detail = '',
    String? profileId,
    String? projectId,
    String? layerId,
    String? linkId,
    String? roomId,
  }) async {
    await client.rpc<dynamic>(
      'report_content',
      params: <String, dynamic>{
        'in_kind': kind,
        'in_reason': reason,
        'in_detail': detail,
        'in_profile': profileId,
        'in_project': projectId,
        'in_layer': layerId,
        'in_link': linkId,
        'in_room': roomId,
      },
    );
  }

  @override
  Future<List<OfferableSong>> songsICanOffer(String profileId) async {
    final rows = await client.rpc<dynamic>(
      'songs_i_can_offer',
      params: <String, dynamic>{'target_person': profileId},
    );
    return <OfferableSong>[
      for (final row in (rows as List<dynamic>? ?? const <dynamic>[]))
        OfferableSong(
          id: (row as Map)['id'] as String,
          title: row['title'] as String? ?? 'Untitled',
          updatedAt:
              DateTime.tryParse('${row['updated_at']}')?.toLocal() ??
                  DateTime.now(),
          alreadyAsked: row['already_asked'] as bool? ?? false,
        ),
    ];
  }

  @override
  Future<void> askMusician({
    required String projectId,
    required String profileId,
    String? part,
    String note = '',
  }) async {
    await client.rpc<dynamic>(
      'ask_musician',
      params: <String, dynamic>{
        'target_project': projectId,
        'target_person': profileId,
        'in_part': part,
        'in_note': note,
      },
    );
  }

  @override
  Future<List<AskForMe>> asksForMe() async {
    final rows = await client.rpc<dynamic>('asks_for_me');
    return <AskForMe>[
      for (final row in (rows as List<dynamic>? ?? const <dynamic>[]))
        AskForMe(
          id: (row as Map)['id'] as String,
          projectId: row['project_id'] as String,
          songTitle: row['song_title'] as String? ?? 'A song',
          askedByName: row['asked_by_name'] as String? ?? 'Somebody',
          part: row['part'] as String?,
          note: row['note'] as String? ?? '',
          createdAt:
              DateTime.tryParse('${row['created_at']}')?.toLocal() ??
                  DateTime.now(),
        ),
    ];
  }

  @override
  Future<void> answerAsk(String askId, {required bool accept}) async {
    await client.rpc<dynamic>(
      'answer_ask',
      params: <String, dynamic>{'target_ask': askId, 'accept': accept},
    );
  }

  @override
  Future<Musician?> loadMusician(String profileId) async {
    final rows = await client.rpc<dynamic>(
      'musician_profile',
      params: <String, dynamic>{'target': profileId},
    );
    final list = rows as List<dynamic>? ?? const <dynamic>[];
    if (list.isEmpty) return null;
    return _musician(Map<String, dynamic>.from(list.first as Map));
  }

  @override
  Future<void> setOpenMicPresence({
    required bool discoverable,
    String? city,
    String? locationVisibility,
    List<String>? plays,
    List<String>? soundsLike,
  }) async {
    await client.rpc<dynamic>(
      'set_open_mic_presence',
      params: <String, dynamic>{
        'in_discoverable': discoverable,
        'in_city': city,
        'in_location_visibility': locationVisibility,
        'in_plays': plays,
        'in_sounds_like': soundsLike,
      },
    );
  }

  Musician _musician(Map<String, dynamic> row) {
    final counts = <String, int>{};
    final parts = row['parts_recorded'];
    if (parts is Map) {
      parts.forEach((key, value) {
        final n = value is num ? value.toInt() : int.tryParse('$value') ?? 0;
        if (n > 0) counts['$key'] = n;
      });
    }
    return Musician(
      id: row['id'] as String,
      displayName: row['display_name'] as String? ?? 'Someone',
      avatarPath: row['avatar_path'] as String?,
      city: row['city'] as String?,
      plays: <String>[
        for (final p in (row['plays'] as List<dynamic>? ?? const <dynamic>[]))
          '$p',
      ],
      partsRecorded: counts,
      songsPlayedOn: (row['songs_played_on'] as num?)?.toInt() ?? 0,
      peopleWorkedWith: (row['people_worked_with'] as num?)?.toInt() ?? 0,
      soundsLike: <String>[
        for (final t
            in (row['sounds_like'] as List<dynamic>? ?? const <dynamic>[]))
          '$t',
      ],
      // Only find_musicians works this out; a profile row has nobody to
      // compare against and leaves it empty.
      sharedSounds: <String>[
        for (final t
            in (row['shared_sounds'] as List<dynamic>? ?? const <dynamic>[]))
          '$t',
      ],
      isDemo: row['is_demo'] as bool? ?? false,
      // Absent from find_musicians rows, and present only on your own.
      discoverable: row['discoverable'] as bool?,
      locationVisibility: row['location_visibility'] as String?,
    );
  }

  @override
  Future<List<ProvenanceEvent>> loadProvenance(String projectId) async {
    final rows = await client.rpc<dynamic>(
      'song_provenance',
      params: <String, dynamic>{'target_project': projectId},
    );
    return <ProvenanceEvent>[
      for (final row in (rows as List<dynamic>? ?? const <dynamic>[]))
        ProvenanceEvent(
          at: DateTime.parse((row as Map<String, dynamic>)['at'] as String)
              .toLocal(),
          event: row['event'] as String? ?? '',
          who: row['who'] as String?,
          whoName: row['who_name'] as String? ?? 'someone',
          detail: row['detail'] as String? ?? '',
        ),
    ];
  }

  @override
  Future<List<SongAsk>> loadAsks(String projectId) async {
    final rows = await client
        .from('project_asks')
        .select('id, project_id, asked_by, part, note, created_at, status')
        .eq('project_id', projectId)
        .eq('status', 'open')
        .order('created_at', ascending: false);
    return <SongAsk>[
      for (final row in rows as List<dynamic>) _ask(row as Map<String, dynamic>),
    ];
  }

  @override
  Future<SongAsk> askFor({
    required String projectId,
    String? part,
    String note = '',
  }) async {
    final cleaned = part?.trim();
    final row = await client
        .from('project_asks')
        .insert(<String, dynamic>{
          'project_id': projectId,
          'asked_by': _userId,
          // Null rather than an empty string: null is what makes this an open
          // ask, and '' would be a specific ask for a part with no name.
          'part': cleaned == null || cleaned.isEmpty ? null : cleaned,
          'note': note.trim(),
        })
        .select('id, project_id, asked_by, part, note, created_at, status')
        .single();
    return _ask(row);
  }

  @override
  Future<void> closeAsk(SongAsk ask) async {
    await client
        .from('project_asks')
        .update(<String, dynamic>{
          'status': 'closed',
          'closed_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', ask.id);
  }

  @override
  Future<List<String>> loadNods(String projectId) async {
    final rows = await client
        .from('project_nods')
        .select('profile_id')
        .eq('project_id', projectId);
    return <String>[
      for (final row in rows as List<dynamic>)
        (row as Map<String, dynamic>)['profile_id'] as String,
    ];
  }

  @override
  Future<void> setNod({required String projectId, required bool heard}) async {
    if (heard) {
      // Upsert rather than insert: tapping it twice quickly should be the same
      // as tapping it once, not a primary key violation shown to a musician.
      await client.from('project_nods').upsert(<String, dynamic>{
        'project_id': projectId,
        'profile_id': _userId,
      });
      return;
    }
    await client
        .from('project_nods')
        .delete()
        .eq('project_id', projectId)
        .eq('profile_id', _userId);
  }

  SongAsk _ask(Map<String, dynamic> row) {
    final part = row['part'] as String?;
    return SongAsk(
      id: row['id'] as String,
      projectId: row['project_id'] as String,
      askedBy: row['asked_by'] as String? ?? '',
      createdAt:
          DateTime.tryParse(row['created_at'] as String? ?? '')?.toLocal() ??
              DateTime.now(),
      part: part,
      note: row['note'] as String? ?? '',
      closed: (row['status'] as String? ?? 'open') != 'open',
    );
  }

  @override
  Future<InviteResult> createInvite({
    required MusicRoom room,
    required String email,
    RoomRole role = RoomRole.editor,
  }) async {
    final cleaned = email.trim().toLowerCase();
    if (!cleaned.contains('@')) throw const NameConflict('Enter a valid email address.');
    final result = await client.rpc<Map<String, dynamic>>(
      'create_room_invitation',
      params: <String, dynamic>{
        'target_room': room.id,
        'invite_email': cleaned,
        'invite_role': role.name,
      },
    );
    return _inviteResult(result);
  }

  @override
  Future<InviteResult> createProjectInvite({
    required SongProject project,
    required String email,
    RoomRole role = RoomRole.editor,
  }) async {
    final cleaned = email.trim().toLowerCase();
    if (!cleaned.contains('@')) throw const NameConflict('Enter a valid email address.');
    final result = await client.rpc<Map<String, dynamic>>(
      'create_project_invitation',
      params: <String, dynamic>{
        'target_project': project.id,
        'invite_email': cleaned,
        'invite_role': role.name,
      },
    );
    return _inviteResult(result);
  }

  InviteResult _inviteResult(Map<String, dynamic> result) {
    return InviteResult(
      code: result['token'] as String,
      matchedAccount: result['matched_account'] as bool? ?? false,
    );
  }

  @override
  Future<void> acceptInvite({String? code, BetaInvite? invite}) async {
    if (invite != null) {
      await client.rpc<void>(
        invite.isProjectScoped ? 'accept_project_invitation_by_id' : 'accept_room_invitation_by_id',
        params: <String, dynamic>{'target_invitation': invite.id},
      );
      return;
    }
    final cleaned = code?.trim();
    if (cleaned == null || cleaned.isEmpty) {
      throw const NameConflict('Enter an invite code.');
    }
    await client.rpc<void>(
      'accept_room_invitation',
      params: <String, dynamic>{'invite_token': cleaned},
    );
  }

  @override
  Future<void> declineInvite(BetaInvite invite) async {
    await client.rpc<void>(
      'decline_room_invitation',
      params: <String, dynamic>{'target_invitation': invite.id},
    );
  }

  @override
  Future<void> setMemberColor({required String roomId, required int colorValue}) async {
    await client.rpc<void>(
      'set_my_room_color',
      params: <String, dynamic>{'target_room': roomId, 'target_color': colorValue},
    );
  }

  @override
  Future<void> submitFeedback(FeedbackDraft feedback) async {
    // Uploaded before the row exists, same order as setAvatar: the row is
    // what makes the screenshot findable, so writing it first would leave a
    // feedback entry pointing at a path that was never actually filled.
    String? screenshotPath;
    final screenshot = feedback.screenshot;
    if (screenshot != null) {
      screenshotPath = '$_userId/${DateTime.now().millisecondsSinceEpoch}.png';
      await client.storage.from('feedback-screenshots').uploadBinary(
            screenshotPath,
            screenshot,
            fileOptions: const FileOptions(contentType: 'image/png'),
          );
    }
    await client.from('feedback').insert(<String, dynamic>{
      'user_id': _userId,
      'category': feedback.category,
      'message': feedback.message,
      'route': feedback.route,
      'platform': feedback.platform,
      'app_version': feedback.appVersion,
      'screenshot_path': screenshotPath,
    });
  }

  Object _friendlyDatabaseError(PostgrestException error, {required String noun}) {
    if (error.code == '23505') {
      return NameConflict('A $noun with that name already exists in your account.');
    }
    return error;
  }

  MusicRoom _room(Map<String, dynamic> row) {
    final members = (row['room_members'] as List<dynamic>? ?? const <dynamic>[])
        .map((value) => _member(Map<String, dynamic>.from(value as Map)))
        .toList(growable: false);
    final projects = (row['projects'] as List<dynamic>? ?? const <dynamic>[])
        .map((value) => _project(Map<String, dynamic>.from(value as Map)))
        .toList(growable: false)
      ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    return MusicRoom(
      id: row['id'] as String,
      accountId: row['account_id'] as String,
      name: row['name'] as String,
      icon: row['icon'] as String? ?? '♪',
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
      members: members,
      projects: projects,
      sortOrder: (row['sort_order'] as num?)?.toDouble() ?? 0,
      logoPath: row['logo_path'] as String?,
    );
  }

  RoomMember _member(Map<String, dynamic> row) {
    // room_members carries the name and colour a person picked for this
    // room, but a profile picture belongs to the person, not to their
    // membership — so it is embedded from profiles through the user_id key.
    final profile = row['profiles'];
    return RoomMember(
      userId: row['user_id'] as String,
      displayName: row['display_name'] as String? ?? 'Member',
      role: RoomRole.values.byName(row['role'] as String? ?? RoomRole.viewer.name),
      colorValue: row['color_value'] as int? ?? 0xFF32D4FF,
      avatarPath: profile is Map ? profile['avatar_path'] as String? : null,
    );
  }

  SongProject _project(Map<String, dynamic> row) {
    final contributions = (row['contributions'] as List<dynamic>? ?? const <dynamic>[])
        .map((value) => _contribution(Map<String, dynamic>.from(value as Map)))
        .toList(growable: false)
      ..sort((left, right) {
        final position = left.position.compareTo(right.position);
        return position == 0 ? left.createdAt.compareTo(right.createdAt) : position;
      });
    return SongProject(
      id: row['id'] as String,
      roomId: row['room_id'] as String,
      accountId: row['account_id'] as String,
      createdBy: row['created_by'] as String?,
      title: row['title'] as String,
      description: row['description'] as String? ?? '',
      status: SongStatus.values.byName(row['status'] as String? ?? SongStatus.active.name),
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
      contributions: contributions,
      sortOrder: (row['sort_order'] as num?)?.toDouble() ?? 0,
      coverImagePath: row['cover_image_path'] as String?,
      // project_audio_references.project_id is the primary key, so this is
      // a one-to-one relation — PostgREST embeds those as a single object
      // (or null), not a list, unlike the one-to-many embeds elsewhere in
      // this query.
      hasAudioReference: row['project_audio_references'] != null,
      analysisState: _analysisState(row['project_audio_references']),
    );
  }

  /// The reference row's state, or null when there is no reference.
  ///
  /// An unrecognised value is read as `uploaded` rather than thrown: the
  /// check constraint can gain a state in a migration that ships before the
  /// app that knows about it, and a song list is not worth crashing over.
  SongAnalysisState? _analysisState(Object? reference) {
    if (reference is! Map) return null;
    final name = reference['analysis_state'] as String?;
    if (name == null) return SongAnalysisState.uploaded;
    return SongAnalysisState.values.firstWhere(
      (state) => state.name == name,
      orElse: () => SongAnalysisState.uploaded,
    );
  }

  Contribution _contribution(Map<String, dynamic> row) {
    final voiceRows = (row['files'] as List<dynamic>? ?? const <dynamic>[])
        .map((value) => Map<String, dynamic>.from(value as Map))
        .where((value) => value['contribution_id'] == row['id'])
        .toList(growable: false)
      ..sort((left, right) =>
          (right['created_at'] as String).compareTo(left['created_at'] as String));
    return Contribution(
      id: row['id'] as String,
      projectId: row['project_id'] as String,
      authorId: row['author_id'] as String,
      authorName: row['author_name'] as String? ?? 'Member',
      body: row['body'] as String,
      colorValue: row['color_value'] as int? ?? 0xFFFF8A4C,
      createdAt: DateTime.parse(row['created_at'] as String),
      position: (row['position'] as num?)?.toDouble() ?? 0,
      kind: ContributionKind.values.byName(
        row['kind'] as String? ?? ContributionKind.lyric.name,
      ),
      revision: row['revision'] as int? ?? 1,
      voiceNote: voiceRows.isEmpty ? null : _voiceNote(voiceRows.first),
    );
  }

  VoiceNote _voiceNote(Map<String, dynamic> row) {
    return VoiceNote(
      id: row['id'] as String,
      projectId: row['project_id'] as String,
      contributionId: row['contribution_id'] as String,
      storagePath: row['storage_path'] as String,
      durationMs: row['duration_ms'] as int? ?? 0,
      byteSize: row['byte_size'] as int? ?? 0,
      mimeType: row['mime_type'] as String? ?? 'audio/wav',
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }

  AppNotification _notification(Map<String, dynamic> row) {
    return AppNotification(
      id: row['id'] as String,
      type: _notificationTypeFromSql(row['type'] as String),
      title: row['title'] as String,
      body: row['body'] as String? ?? '',
      createdAt: DateTime.parse(row['created_at'] as String),
      roomId: row['room_id'] as String?,
      projectId: row['project_id'] as String?,
      invitationId: row['invitation_id'] as String?,
      actorId: row['actor_id'] as String?,
      readAt: row['read_at'] == null ? null : DateTime.parse(row['read_at'] as String),
    );
  }

  NotificationType _notificationTypeFromSql(String value) {
    switch (value) {
      case 'invite_received':
        return NotificationType.inviteReceived;
      case 'invite_accepted':
        return NotificationType.inviteAccepted;
      case 'invite_declined':
        return NotificationType.inviteDeclined;
      case 'project_update':
        return NotificationType.projectUpdate;
      case 'analysis_ready':
        return NotificationType.analysisReady;
    }
    throw ArgumentError('Unknown notification type: $value');
  }

  Map<String, dynamic> _memberJson(RoomMember member) => <String, dynamic>{
        'user_id': member.userId,
        'display_name': member.displayName,
        'role': member.role.name,
        'color_value': member.colorValue,
      };

  Map<String, dynamic> _projectJson(SongProject project) => <String, dynamic>{
        'id': project.id,
        'room_id': project.roomId,
        'account_id': project.accountId,
        'title': project.title,
        'description': project.description,
        'status': project.status.name,
        'created_at': project.createdAt.toIso8601String(),
        'updated_at': project.updatedAt.toIso8601String(),
        'contributions': project.contributions.map(_contributionJson).toList(growable: false),
        'cover_image_path': project.coverImagePath,
        'project_audio_references': project.hasAudioReference
            ? <String, dynamic>{'analysis_state': project.analysisState?.name}
            : null,
      };

  Map<String, dynamic> _contributionJson(Contribution contribution) => <String, dynamic>{
        'id': contribution.id,
        'project_id': contribution.projectId,
        'author_id': contribution.authorId,
        'author_name': contribution.authorName,
        'body': contribution.body,
        'color_value': contribution.colorValue,
        'kind': contribution.kind.name,
        'revision': contribution.revision,
        'position': contribution.position,
        'created_at': contribution.createdAt.toIso8601String(),
        'files': contribution.voiceNote == null
            ? const <dynamic>[]
            : <Map<String, dynamic>>[_voiceNoteJson(contribution.voiceNote!)],
      };

  Map<String, dynamic> _voiceNoteJson(VoiceNote note) => <String, dynamic>{
        'id': note.id,
        'project_id': note.projectId,
        'contribution_id': note.contributionId,
        'storage_path': note.storagePath,
        'mime_type': note.mimeType,
        'byte_size': note.byteSize,
        'duration_ms': note.durationMs,
        'created_at': note.createdAt.toIso8601String(),
      };

  @override
  void dispose() {
    client.removeChannel(_channel);
    _changes.close();
    _projectChanges.close();
  }
}
