import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../app/beta_config.dart';
import '../domain/activity.dart';
import '../domain/calls.dart';
import '../domain/lesson_link.dart';
import '../domain/loop_round.dart';
import '../domain/moment_note.dart';
import '../domain/music_models.dart';
import '../domain/practice_mark.dart';
import '../domain/sealed_take.dart';
import '../domain/sent_take.dart';
import '../domain/song_brief.dart';
import '../domain/song_cycle.dart';
import '../domain/tonight_models.dart';
import '../domain/name_policy.dart';
import '../domain/song_analysis_models.dart' show SongAnalysisState;
import '../domain/sung_in.dart';
import 'music_repository.dart';
import '../services/error_reporter.dart';
import '../services/song_language.dart';

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
          'projects(id, room_id, account_id, created_by, title, description, status, created_at, updated_at, sort_order, cover_image_path, song_origin, key_override, bar_one_downbeat, language, cycle_beats, cycle_accents, '
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
      asks: row['asks'] as bool? ?? true,
      messages: row['messages'] as bool? ?? true,
      calls: row['calls'] as bool? ?? true,
    );
  }

  @override
  Future<void> setNotificationPreferences(NotificationPreferences preferences) async {
    await client.from('notification_preferences').upsert(<String, dynamic>{
      'user_id': _userId,
      'invites': preferences.invites,
      'invite_responses': preferences.inviteResponses,
      'project_updates': preferences.projectUpdates,
      'asks': preferences.asks,
      'messages': preferences.messages,
      'calls': preferences.calls,
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
          'id, owner_id, name, created_at, updated_at, for_day, '
          'setlist_projects(project_id, position, played_key, bpm, count_in, form, ending, note)',
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
        forDay: _dayOrNull(row['for_day']),
        songs: entries
            .map((entry) => SetlistSong(
                  projectId: entry['project_id'] as String,
                  key: entry['played_key'] as String?,
                  bpm: (entry['bpm'] as num?)?.toDouble(),
                  countIn: entry['count_in'] as String?,
                  form: entry['form'] as String?,
                  ending: entry['ending'] as String?,
                  note: entry['note'] as String?,
                ))
            .toList(growable: false),
      );
    }).toList(growable: false);
  }

  /// A `date` column as a day on this phone's calendar.
  ///
  /// Parsed rather than passed through `DateTime.parse` alone, because a
  /// bare "2026-10-04" parses as local midnight and anything that later
  /// converts it would move the day. The set is for the fourth wherever the
  /// phone is (0164).
  static DateTime? _dayOrNull(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    final parsed = DateTime.tryParse(value.trim());
    if (parsed == null) return null;
    return DateTime(parsed.year, parsed.month, parsed.day);
  }

  /// The day a `date` column is given, with no time and no zone on it.
  static String _dayText(DateTime day) => '${day.year.toString().padLeft(4, '0')}'
      '-${day.month.toString().padLeft(2, '0')}'
      '-${day.day.toString().padLeft(2, '0')}';

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
    // A room logo is seen by everybody in the room, which is a smaller
    // audience than an avatar and the same problem.
    await checkPicture(
      bucket: 'room-files',
      path: path,
      kind: 'room_logo',
      subject: room.id,
    );
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

    // Looked at before anybody else sees it. Awaited rather than fired off,
    // so a picture that gets refused is already gone by the time this
    // returns and the screen never draws it — which is the whole difference
    // between catching it and catching up with it.
    await checkPicture(
      bucket: 'avatars',
      path: path,
      kind: 'profile',
      subject: _userId,
    );

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
  Future<bool> discardIfUntouched(String projectId) async {
    final gone = await client.rpc<dynamic>(
      'discard_if_untouched',
      params: <String, dynamic>{'target_project': projectId},
    );
    return gone == true;
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
  Future<Contribution> moveContribution({
    required Contribution contribution,
    required double position,
  }) async {
    // Selected back so a row that is gone, or that this account may not
    // move, fails here rather than reporting a move that never happened.
    await client
        .from('contributions')
        .update(<String, dynamic>{'position': position})
        .eq('id', contribution.id)
        .select('id')
        .single();
    return contribution.copyWith(position: position);
  }

  @override
  Future<void> cutLine(Contribution line) async {
    // Through the function, not an update: 0006 limits direct updates to
    // body and position, and the row's voice note is deliberately left where
    // it is. Refused for somebody who cannot edit the song, and a no-op for a
    // line somebody else already cut.
    await client.rpc<void>(
      'cut_line',
      params: <String, dynamic>{'target_line': line.id},
    );
  }

  @override
  Future<List<Contribution>> linesYouCut(SongProject project) async {
    // The function answers for the signed-in person alone; the read policy
    // hides every cut line, so this is the only way one is ever read.
    final rows = await client.rpc<List<dynamic>>(
      'lines_you_cut',
      params: <String, dynamic>{'target_project': project.id},
    );
    return rows
        .map((row) => _contribution(Map<String, dynamic>.from(row as Map)))
        .toList(growable: false);
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
  Future<void> renameSetlist(Setlist setlist, String name) async {
    final cleaned = NamePolicy.clean(name);
    NamePolicy.requireUsable(cleaned, label: 'Set name');
    try {
      await client.from('setlists').update(<String, dynamic>{'name': cleaned}).eq('id', setlist.id);
    } on PostgrestException catch (error) {
      throw _friendlyDatabaseError(error, noun: 'setlist');
    }
  }

  @override
  Future<void> deleteSetlist(Setlist setlist) async {
    // The songs stay: setlist_projects rows go with the set (on delete
    // cascade), the projects they point at do not.
    await client.from('setlists').delete().eq('id', setlist.id);
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
  Future<void> saveSetlistSong(Setlist setlist, SetlistSong song) async {
    final cleaned = song.cleaned();
    // Written through 0005's update policy rather than a function: the row is
    // the set owner's and nobody else's, which is a rule the table already
    // has. An update the policy refuses affects no row and raises nothing,
    // so the row is asked for back, and none coming back is the refusal.
    //
    // The same silence answers the owner when the song has left the set
    // (removed on another device) or sits in a room they can no longer read
    // (0005's read policy asks for membership, and the update's where goes
    // through it). Which of the two it was is told by whose set it is.
    final rows = await client
        .from('setlist_projects')
        .update(<String, dynamic>{
          'played_key': cleaned.key,
          'bpm': cleaned.bpm,
          'count_in': cleaned.countIn,
          'form': cleaned.form,
          'ending': cleaned.ending,
          'note': cleaned.note,
        })
        .eq('setlist_id', setlist.id)
        .eq('project_id', song.projectId)
        .select('project_id');
    if ((rows as List<dynamic>).isEmpty) {
      throw StateError(
        setlist.ownerId == client.auth.currentUser?.id
            ? MusicRepository.songNotInSet
            : MusicRepository.notYourSet,
      );
    }
  }

  @override
  Future<void> setSetlistDay(Setlist setlist, DateTime? day) async {
    // Through 0005's update policy, the way 0157's six columns are written
    // and for the same reason: the row is the set owner's, which is a rule
    // the table already has. An update the policy refuses affects no row and
    // raises nothing, so the row is asked for back and none coming back is
    // the refusal.
    final rows = await client
        .from('setlists')
        .update(<String, dynamic>{
          'for_day': day == null ? null : _dayText(day),
        })
        .eq('id', setlist.id)
        .select('id');
    if ((rows as List<dynamic>).isEmpty) {
      throw StateError(MusicRepository.notYourSet);
    }
  }

  @override
  Future<List<Setlist>> setsForTheDay() async {
    // One row per song, ordered by the running order in the function (0164).
    // Nothing is written by asking: there is no receipt for a leader to read.
    final rows = await client.rpc<List<dynamic>>('sets_for_the_day');
    final sets = <String, Setlist>{};
    for (final value in rows) {
      final row = Map<String, dynamic>.from(value as Map);
      final id = row['set_id'] as String;
      final held = sets[id] ??
          Setlist(
            id: id,
            ownerId: row['owner_id'] as String,
            name: row['set_name'] as String,
            createdAt: DateTime.parse(row['created_at'] as String),
            updatedAt: DateTime.parse(row['updated_at'] as String),
            forDay: _dayOrNull(row['for_day']),
          );
      sets[id] = held.copyWith(
        songs: <SetlistSong>[
          ...held.songs,
          SetlistSong(
            projectId: row['project_id'] as String,
            // The key this occasion does the song in, and nothing else the
            // set says: the tempo, the count-in, the form, the ending and the
            // note belong to the set's own screen, which is the owner's.
            key: row['played_key'] as String?,
          ),
        ],
      );
    }
    return sets.values.toList(growable: false);
  }

  @override
  Future<SongProject?> loadProject(String projectId) async {
    // The same shape loadRooms asks for per project, so _project parses it
    // unchanged and a refreshed song cannot differ from a loaded one.
    final row = await client
        .from('projects')
        .select(
          'id, room_id, account_id, created_by, title, description, status, created_at, updated_at, sort_order, cover_image_path, song_origin, key_override, bar_one_downbeat, language, cycle_beats, cycle_accents, '
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
              audioPath: row['audio_path'] as String?,
              audioMs: (row['audio_ms'] as num?)?.toInt(),
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
    List<String>? parts,
    String? city,
    int limit = 30,
    String? soundsLike,
  }) async {
    final rows = await client.rpc<dynamic>(
      'find_musicians',
      params: <String, dynamic>{
        'in_parts': (parts == null || parts.isEmpty) ? null : parts,
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
  Future<List<FoundPerson>> searchPeople(String query) async {
    if (query.trim().isEmpty) return const <FoundPerson>[];
    final rows = await client.rpc<dynamic>(
      'search_people',
      params: <String, dynamic>{'q': query.trim()},
    );
    return <FoundPerson>[
      for (final row in (rows as List<dynamic>? ?? const <dynamic>[]))
        FoundPerson(
          personId: (row as Map)['person_id'] as String,
          displayName: (row['display_name'] as String?) ?? 'Someone',
          avatarPath: row['avatar_path'] as String?,
          plays: <String>[
            for (final part
                in (row['plays'] as List<dynamic>? ?? const <dynamic>[]))
              part.toString(),
          ],
          city: row['city'] as String?,
          already: standingFrom(row['already'] as String?),
        ),
    ];
  }

  @override
  Future<List<SuggestedPerson>> peopleToTell(String projectId) async {
    final rows = await client.rpc<dynamic>(
      'people_to_tell',
      params: <String, dynamic>{'in_project': projectId},
    );
    return <SuggestedPerson>[
      for (final row in (rows as List<dynamic>? ?? const <dynamic>[]))
        SuggestedPerson(
          personId: (row as Map)['person_id'] as String,
          displayName: (row['display_name'] as String?) ?? 'Someone',
          avatarPath: row['avatar_path'] as String?,
          because: (row['because'] as String?) ?? '',
        ),
    ];
  }

  @override
  Future<int> tellAboutSong(
    String projectId, {
    String? note,
    List<String>? personIds,
  }) async {
    final told = await client.rpc<dynamic>(
      'tell_about_song',
      params: <String, dynamic>{
        'in_project': projectId,
        'in_note': note,
        'in_targets':
            (personIds == null || personIds.isEmpty) ? null : personIds,
      },
    );
    return (told as int?) ?? 0;
  }

  @override
  Future<List<Connection>> listConnections() async {
    final rows = await client.rpc<dynamic>('my_connections');
    return <Connection>[
      for (final row in (rows as List<dynamic>? ?? const <dynamic>[]))
        _connection(Map<String, dynamic>.from(row as Map)),
    ];
  }

  Connection _connection(Map<String, dynamic> row) => Connection(
        personId: row['person_id'] as String,
        displayName: (row['display_name'] as String?) ?? 'Someone',
        avatarPath: row['avatar_path'] as String?,
        plays: <String>[
          for (final part in (row['plays'] as List<dynamic>? ?? const <dynamic>[]))
            part.toString(),
        ],
        accepted: row['state'] == 'accepted',
        incoming: row['direction'] == 'incoming',
        availability: availabilityFrom(row['availability'] as String?),
        availabilityNote: row['availability_note'] as String?,
        availabilityUntil: row['availability_until'] == null
            ? null
            : DateTime.parse(row['availability_until'] as String).toLocal(),
        since: row['since'] == null
            ? null
            : DateTime.parse(row['since'] as String).toLocal(),
      );

  @override
  Future<bool> requestConnection(String personId) async {
    final state = await client.rpc<dynamic>(
      'request_connection',
      params: <String, dynamic>{'other_id': personId},
    );
    return state == 'accepted';
  }

  @override
  Future<void> respondToConnection(String personId, {required bool accept}) async {
    await client.rpc<dynamic>(
      'respond_to_connection',
      params: <String, dynamic>{'other_id': personId, 'accept': accept},
    );
  }

  @override
  Future<void> removeConnection(String personId) async {
    await client.rpc<dynamic>(
      'remove_connection',
      params: <String, dynamic>{'other_id': personId},
    );
  }

  @override
  Future<List<SuggestedPerson>> peopleYouMightAdd() async {
    final rows = await client.rpc<dynamic>('people_you_might_add');
    return <SuggestedPerson>[
      for (final row in (rows as List<dynamic>? ?? const <dynamic>[]))
        SuggestedPerson(
          personId: (row as Map)['person_id'] as String,
          displayName: (row['display_name'] as String?) ?? 'Someone',
          avatarPath: row['avatar_path'] as String?,
          because: (row['because'] as String?) ?? '',
          canMessage: row['can_message'] as bool? ?? false,
        ),
    ];
  }

  @override
  Future<void> setAvailability(
    Availability state, {
    String? note,
    DateTime? until,
  }) async {
    await client.rpc<dynamic>(
      'set_availability',
      params: <String, dynamic>{
        'new_state': state.name,
        'note': note,
        'until': until?.toUtc().toIso8601String(),
      },
    );
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
          // Absent until 0156 is applied, and empty is what it means anyway.
          askSungIn: row['ask_sung_in'] as String? ?? '',
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
      heard: (row['heard'] as num?)?.toInt() ?? 0,
      heardByMe: row['heard_by_me'] as bool? ?? false,
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
      onShowcase: row['on_showcase'] as bool? ?? false,
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
      answers: <PersonsAnswer>[
        for (final entry
            in (row['answers'] as List<dynamic>? ?? const <dynamic>[]))
          PersonsAnswer(
            id: (entry as Map)['id'] as String? ?? '',
            name: entry['name'] as String? ?? 'Somebody',
            answer: PartAnswer.fromWireName(entry['answer'] as String?),
          ),
      ],
      myAnswer: row['my_answer'] == null
          ? null
          : PartAnswer.fromWireName(row['my_answer'] as String?),
    );
  }

  @override
  Future<void> putOnOpenMic(String projectId) async {
    // Returns the moment it went up, or null while it waits on somebody's
    // answer (0155). Neither is read here: the workspace re-reads the
    // audience afterwards, which says both and names who is still to answer.
    await client.rpc<dynamic>(
      'put_on_open_mic',
      params: <String, dynamic>{'target_project': projectId},
    );
  }

  @override
  Future<List<PartQuestion>> partQuestionsForMe() async {
    final rows = await client.rpc<dynamic>('part_questions_for_me');
    return <PartQuestion>[
      for (final row in (rows as List<dynamic>? ?? const <dynamic>[]))
        PartQuestion(
          projectId: (row as Map)['project_id'] as String,
          songTitle: row['song_title'] as String? ?? 'A song',
          askedById: row['asked_by'] as String?,
          askedByName: row['asked_by_name'] as String?,
          parts: <String>[
            for (final part
                in (row['parts'] as List<dynamic>? ?? const <dynamic>[]))
              '$part',
          ],
          askedAt: DateTime.tryParse('${row['asked_at']}')?.toLocal() ??
              DateTime.now(),
        ),
    ];
  }

  @override
  Future<void> answerForMyPart(String projectId, {required bool yes}) async {
    await client.rpc<dynamic>(
      'answer_for_my_part',
      params: <String, dynamic>{'target_project': projectId, 'in_yes': yes},
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
  Future<void> setSongOrigin(String projectId, SongOrigin origin) async {
    await client.rpc<dynamic>(
      'set_song_origin',
      params: <String, dynamic>{
        'target_project': projectId,
        'in_origin': origin.wireName,
      },
    );
  }

  @override
  Future<void> setSongKey(String projectId, String? key) async {
    final said = key?.trim();
    await client.rpc<dynamic>(
      'set_song_key',
      params: <String, dynamic>{
        'target_project': projectId,
        // Null clears it, which is how "Use the detected key" is spelled.
        'in_key': said == null || said.isEmpty ? null : said,
      },
    );
  }

  @override
  Future<void> setBarOne(String projectId, int? downbeat) async {
    await client.rpc<dynamic>(
      'set_bar_one',
      params: <String, dynamic>{
        'target_project': projectId,
        // Null clears it, which is how "Use the detected bars" is spelled.
        'in_downbeat': downbeat == null || downbeat < 1 ? null : downbeat,
      },
    );
  }

  @override
  Future<void> setSongLanguage(String projectId, String? language) async {
    await client.rpc<dynamic>(
      'set_song_language',
      params: <String, dynamic>{
        'target_project': projectId,
        // Sent in the one spelling 0163's check takes, so a tag typed in
        // upper case is the same tag as the same one from the list. Null
        // takes the answer away, which is a real answer and not a missing
        // argument.
        'in_language': languageTagTyped(language),
      },
    );
  }

  @override
  Future<void> setSongCycle(String projectId, SongCycle? cycle) async {
    await client.rpc<dynamic>(
      'set_song_cycle',
      params: <String, dynamic>{
        'target_project': projectId,
        // Null clears it, which is how "Use the detected bars" is spelled
        // here too. The stresses go over whether or not there are any: an
        // empty list is a cycle somebody has said nothing inside, and the
        // function normalises both ends.
        'in_beats': cycle?.beats,
        'in_accents': cycle?.accents ?? const <int>[],
      },
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
    if (wanted.isNotEmpty) return createSong(room: room, title: wanted);
    // Two taps inside one second, or a clock that repeats itself, must not
    // put "already exists" on the Record button -- which it did, once, on
    // 7 September 2026. The second try keeps the auto-named shape that
    // idea_naming recognises, so it is still renamed from what was sung.
    final name = _ideaName();
    try {
      return await createSong(room: room, title: name);
    } on NameConflict {
      return createSong(
        room: room,
        title: '$name ${DateTime.now().millisecond}',
      );
    }
  }

  /// A name that is not "Untitled".
  ///
  /// Recordings arrive before anybody has decided what the song is, and a
  /// library of things called Untitled is a library nobody can search. The
  /// date and time is at least a fact somebody can recognise, and the app
  /// renames it from what was sung as soon as it knows -- see
  /// `betterNameFor` in idea_naming.dart, applied when the sheet lands.
  ///
  /// Seconds, because the minute alone collided: the title index is per
  /// account, and one person recording twice in a minute is the normal
  /// case, not the edge.
  String _ideaName() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return 'Idea ${two(now.month)}/${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
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
          partsOnIt: <String>[
            for (final part in (row['parts_on_it'] as List<dynamic>? ??
                const <dynamic>[]))
              '$part',
          ],
        ),
    ];
  }

  @override
  Future<void> askMusician({
    required String projectId,
    required String profileId,
    String? part,
    String note = '',
    AskTerms terms = AskTerms.play,
    String sungIn = '',
  }) async {
    await client.rpc<dynamic>(
      'ask_musician',
      params: <String, dynamic>{
        'target_project': projectId,
        'target_person': profileId,
        'in_part': part,
        'in_note': note,
        'in_terms': terms.wireName,
        // Cut to the column here as the server cuts it there, so the two
        // ways an ask is made agree about how long the line can be.
        'in_sung_in': sungInLine(sungIn),
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
          askedById: row['asked_by'] as String?,
          part: row['part'] as String?,
          note: row['note'] as String? ?? '',
          sungIn: row['sung_in'] as String? ?? '',
          createdAt:
              DateTime.tryParse('${row['created_at']}')?.toLocal() ??
                  DateTime.now(),
          storagePath: row['storage_path'] as String?,
          durationMs: (row['duration_ms'] as num?)?.toInt(),
          musicalKey: row['musical_key'] as String?,
          bpm: (row['bpm'] as num?)?.toDouble(),
          partsOnIt: <String>[
            for (final part in (row['parts_on_it'] as List<dynamic>? ??
                const <dynamic>[]))
              '$part',
          ],
          hasSongSheet: row['has_song_sheet'] as bool? ?? false,
          terms: AskTerms.fromWireName(row['terms'] as String?),
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
  Future<List<Noticed>> thingsWeNoticed() async {
    final rows = await client.rpc<dynamic>('things_we_noticed');
    return <Noticed>[
      for (final row in (rows as List<dynamic>? ?? const <dynamic>[]))
        Noticed(
          kind: switch ((row as Map)['kind'] as String? ?? '') {
            'plays' => NoticedKind.plays,
            'discoverable' => NoticedKind.discoverable,
            _ => NoticedKind.soundsLike,
          },
          subject: row['subject'] as String? ?? '',
          detail: row['detail'] as String? ?? '',
          amount: (row['amount'] as num?)?.toInt() ?? 0,
        ),
    ];
  }

  @override
  Future<void> checkPicture({
    required String bucket,
    required String path,
    required String kind,
    required String subject,
  }) async {
    try {
      await client.functions.invoke(
        'check-picture',
        body: <String, dynamic>{
          'bucket': bucket,
          'path': path,
          'kind': kind,
          'subject': subject,
        },
      );
    } catch (error) {
      // Swallowed on purpose. The picture is already uploaded and pointed
      // at; a moderation call that could not be made is a gap the report
      // path covers, and throwing here would tell somebody their picture
      // failed when it did not.
      unawaited(ErrorReporter().reportWarning(
        service: 'app',
        stage: 'check_picture',
        message: error.toString(),
      ));
    }
  }

  @override
  Future<({String roomId, String projectId})> startSomethingWith(
    String profileId, {
    String note = '',
  }) async {
    final rows = await client.rpc<dynamic>(
      'start_something_with',
      params: <String, dynamic>{
        'target_profile': profileId,
        'in_note': note,
      },
    );
    final list = rows as List<dynamic>? ?? const <dynamic>[];
    if (list.isEmpty) {
      throw StateError('That room could not be started.');
    }
    final row = list.first as Map;
    return (
      roomId: row['made_room'] as String,
      projectId: row['made_song'] as String,
    );
  }

  @override
  Future<void> recordPlay(String projectId) async {
    try {
      await client.rpc<dynamic>(
        'record_play',
        params: <String, dynamic>{'target_project': projectId},
      );
    } catch (_) {
      // Swallowed. A count that could not be written is a count; a listen
      // that threw in the middle of somebody's music is a bug they can hear.
    }
  }

  @override
  Future<List<OpenMicStatus>> myOpenMic() async {
    final rows = await client.rpc<dynamic>('my_open_mic');
    return <OpenMicStatus>[
      for (final row in (rows as List<dynamic>? ?? const <dynamic>[]))
        OpenMicStatus(
          id: (row as Map)['id'] as String,
          title: row['title'] as String? ?? 'A song',
          putUpAt: DateTime.tryParse('${row['open_mic_at']}')?.toLocal() ??
              DateTime.now(),
          listeners: (row['listeners'] as num?)?.toInt() ?? 0,
          listenersThisWeek:
              (row['listeners_this_week'] as num?)?.toInt() ?? 0,
          offers: (row['offers'] as num?)?.toInt() ?? 0,
          askingFor: <String>[
            for (final a
                in (row['asking_for'] as List<dynamic>? ?? const <dynamic>[]))
              '$a',
          ],
          storagePath: row['storage_path'] as String? ?? '',
          heard: (row['heard'] as num?)?.toInt() ?? 0,
        ),
    ];
  }

  @override
  Future<List<HelpRequest>> myHelpRequests() async {
    final rows = await client.rpc<dynamic>('my_help_requests');
    return <HelpRequest>[
      for (final row in (rows as List<dynamic>? ?? const <dynamic>[]))
        HelpRequest(
          id: (row as Map)['id'] as String,
          question: row['question'] as String? ?? '',
          status: row['status'] as String? ?? 'open',
          askedAt: DateTime.tryParse('${row['created_at']}')?.toLocal() ??
              DateTime.now(),
          notes: row['notes'] as String? ?? '',
          answeredAt: DateTime.tryParse('${row['answered_at']}')?.toLocal(),
        ),
    ];
  }

  @override
  Future<MyPlan> myPlan() async {
    final rows = await client.rpc<dynamic>('my_plan');
    final list = rows as List<dynamic>? ?? const <dynamic>[];
    if (list.isEmpty) {
      // No row is a signed-out or half-created account, not a member.
      return const MyPlan(member: false, sheetsThisMonth: 0, sheetsAllowed: 0);
    }
    final row = list.first as Map;
    return MyPlan(
      member: row['can_separate'] as bool? ?? false,
      sheetsThisMonth: (row['sheets_this_month'] as num?)?.toInt() ?? 0,
      sheetsAllowed: (row['sheets_allowed'] as num?)?.toInt(),
    );
  }

  @override
  Future<List<ShowcaseSong>> showcase({int limit = 24}) async {
    final rows = await client.rpc<dynamic>(
      'showcase',
      params: <String, dynamic>{'in_limit': limit},
    );
    return <ShowcaseSong>[
      for (final row in (rows as List<dynamic>? ?? const <dynamic>[]))
        ShowcaseSong(
          id: (row as Map)['id'] as String,
          title: row['title'] as String? ?? 'A song',
          ownerId: row['owner_id'] as String?,
          ownerName: row['owner_name'] as String? ?? 'Somebody',
          ownerAvatarPath: row['owner_avatar'] as String?,
          shownAt: DateTime.tryParse('${row['showcased_at']}')?.toLocal() ??
              DateTime.now(),
          storagePath: row['storage_path'] as String? ?? '',
          durationMs: (row['duration_ms'] as num?)?.toInt(),
          musicalKey: row['musical_key'] as String?,
          players: <SongListener>[
            for (final p
                in (row['players'] as List<dynamic>? ?? const <dynamic>[]))
              SongListener(
                id: (p as Map)['id'] as String? ?? '',
                name: p['name'] as String? ?? 'Somebody',
              ),
          ],
          madeHere: row['made_here'] as bool? ?? false,
          metHere: row['met_here'] as bool? ?? false,
        ),
    ];
  }

  @override
  Future<void> finishSong(String projectId) => client.rpc<void>(
        'finish_song',
        params: <String, dynamic>{'target_project': projectId},
      );

  @override
  Future<void> showSong(String projectId) => client.rpc<void>(
        'show_song',
        params: <String, dynamic>{'target_project': projectId},
      );

  @override
  Future<void> unshowSong(String projectId) => client.rpc<void>(
        'unshow_song',
        params: <String, dynamic>{'target_project': projectId},
      );

  @override
  Future<void> claimPart(String part) async {
    await client.rpc<dynamic>(
      'claim_part',
      params: <String, dynamic>{'in_part': part},
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
  @override
  Future<void> setBio(String bio) async {
    await client.rpc<dynamic>(
      'set_bio',
      params: <String, dynamic>{'in_bio': bio},
    );
  }

  @override
  Future<void> setOpenMicPresence({
    required bool discoverable,
    String? city,
    String? locationVisibility,
    List<String>? plays,
    List<String>? soundsLike,
    List<String>? singsIn,
  }) async {
    await client.rpc<dynamic>(
      'set_open_mic_presence',
      params: <String, dynamic>{
        'in_discoverable': discoverable,
        'in_city': city,
        'in_location_visibility': locationVisibility,
        'in_plays': plays,
        'in_sounds_like': soundsLike,
        // Null leaves what is stored alone, as it does for the two above.
        // The server folds and caps it (0156), so this sends what was typed.
        'in_sings_in': singsIn,
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
      bio: row['bio'] as String?,
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
      // From musician_profile only (0156). find_musicians does not carry it:
      // the people list is not ordered by it, so it has nothing to explain.
      singsIn: <String>[
        for (final t
            in (row['sings_in'] as List<dynamic>? ?? const <dynamic>[]))
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
      heardSongId: row['heard_song'] as String?,
      heardTitle: row['heard_title'] as String?,
      heardPath: row['heard_path'] as String? ?? '',
      heardDurationMs: (row['heard_duration'] as num?)?.toInt(),
      matchedParts: <String>[
        for (final p
            in (row['matched_parts'] as List<dynamic>? ?? const <dynamic>[]))
          '$p',
      ],
      // Absent from find_musicians rows, and present only on your own.
      discoverable: row['discoverable'] as bool?,
      locationVisibility: row['location_visibility'] as String?,
      // From musician_profile only (0107): the span of what the analyser
      // heard them sing, and how many recordings that is. Null and zero for
      // anybody who has not said they sing, and on every find_musicians row.
      vocalLowMidi: (row['vocal_low_midi'] as num?)?.toInt(),
      vocalHighMidi: (row['vocal_high_midi'] as num?)?.toInt(),
      vocalRangeSongs: (row['vocal_range_songs'] as num?)?.toInt() ?? 0,
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
        // No count of what has been said back: a chip that said "· 2" was a
        // tally of somebody's sentences, and the app does not keep those
        // (Every Musician, Same Song, 17 September 2026).
        .select(
            'id, project_id, asked_by, part, note, sung_in, terms, created_at, status, opinions_opened_at')
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
    AskTerms terms = AskTerms.play,
    String sungIn = '',
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
          // Written once. 0145 refuses an update of this column, so the row
          // that comes back is the last word on what answering meant.
          'terms': terms.wireName,
          // The asker's words, as typed (0156). Never filled in from a
          // profile or a recording: declared, never inferred. This is a
          // plain insert with a check on the column, and the check counts
          // code points where the field counted written characters, so a
          // Hindi line the field accepted could be refused here and take
          // the whole ask with it. `sungInLine` cuts to the column instead.
          'sung_in': sungInLine(sungIn),
        })
        .select(
            'id, project_id, asked_by, part, note, sung_in, terms, created_at, status')
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
  Future<void> setNod({
    required String projectId,
    required bool heard,
    String? note,
  }) async {
    if (heard) {
      // Upsert rather than insert: tapping it twice quickly should be the same
      // as tapping it once, not a primary key violation shown to a musician.
      await client.from('project_nods').upsert(<String, dynamic>{
        'project_id': projectId,
        'profile_id': _userId,
        'note': note == null || note.trim().isEmpty ? null : note.trim(),
      });
      return;
    }
    await client
        .from('project_nods')
        .delete()
        .eq('project_id', projectId)
        .eq('profile_id', _userId);
  }

  @override
  Future<String?> nodNote(String projectId) async {
    final row = await client
        .from('project_nods')
        .select('note')
        .eq('project_id', projectId)
        .eq('profile_id', _userId)
        .maybeSingle();
    return row?['note'] as String?;
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
      sungIn: row['sung_in'] as String? ?? '',
      closed: (row['status'] as String? ?? 'open') != 'open',
      // A time, read as a yes or no: the app never shows when.
      opinionsOpened: row['opinions_opened_at'] != null,
      terms: AskTerms.fromWireName(row['terms'] as String?),
    );
  }

  @override
  Future<void> openOpinions(String askId) async {
    // The table's own trigger (0154) refuses anybody but the asker and keeps
    // the first time if this is a second tap. Selected back so an ask that
    // is gone, or that this account cannot see, fails here rather than
    // reporting a decision that was never written: the sheet hides the
    // control once this returns, and it must not hide it over nothing.
    await client
        .from('project_asks')
        .update(<String, dynamic>{
          'opinions_opened_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', askId)
        .select('opinions_opened_at')
        .single();
  }

  static const String _replyColumns =
      'id, ask_id, author_id, body, kind, created_at, '
      'author:profiles!ask_replies_author_id_fkey(display_name)';

  @override
  Future<List<AskReply>> loadAskReplies(String askId) async {
    final rows = await client
        .from('ask_replies')
        .select(_replyColumns)
        .eq('ask_id', askId)
        .order('created_at', ascending: true);
    return <AskReply>[
      for (final row in rows as List<dynamic>)
        _reply(row as Map<String, dynamic>),
    ];
  }

  @override
  Future<AskReply> replyToAsk({
    required String askId,
    required String body,
    ReplyDoor? door,
  }) async {
    final row = await client
        .from('ask_replies')
        .insert(<String, dynamic>{
          'ask_id': askId,
          'author_id': _userId,
          'body': body.trim(),
          // Left out for a plain line rather than sent as null: a plain
          // line has no door, and the column's own default says so.
          if (door != null) 'kind': door.wireName,
        })
        .select(_replyColumns)
        .single();
    return _reply(row);
  }

  @override
  Future<void> deleteAskReply(AskReply reply) async {
    await client.from('ask_replies').delete().eq('id', reply.id);
  }

  AskReply _reply(Map<String, dynamic> row) {
    final author = row['author'];
    return AskReply(
      id: row['id'] as String,
      askId: row['ask_id'] as String,
      authorId: row['author_id'] as String? ?? '',
      authorName: author is Map
          ? (author['display_name'] as String? ?? 'Somebody')
          : 'Somebody',
      body: row['body'] as String? ?? '',
      createdAt:
          DateTime.tryParse(row['created_at'] as String? ?? '')?.toLocal() ??
              DateTime.now(),
      door: ReplyDoor.fromWireName(row['kind'] as String?),
    );
  }

  static const String _messageColumns =
      'id, pair_low, pair_high, author_id, body, created_at, '
      'author:profiles!direct_messages_author_id_fkey(display_name)';

  /// The thread's key: the two ids in order, whichever of you is asking.
  /// Lower-cased hex sorts the same way Postgres sorts a uuid.
  ({String low, String high}) _pairWith(String personId) {
    final me = _userId.toLowerCase();
    final them = personId.toLowerCase();
    return me.compareTo(them) < 0 ? (low: me, high: them) : (low: them, high: me);
  }

  @override
  Future<bool> canMessage(String personId) async {
    final result = await client.rpc<dynamic>(
      'may_tell',
      params: <String, dynamic>{'other_id': personId},
    );
    return result == true;
  }

  @override
  Future<List<DirectMessage>> loadMessagesWith(String personId) async {
    final pair = _pairWith(personId);
    final rows = await client
        .from('direct_messages')
        .select(_messageColumns)
        .eq('pair_low', pair.low)
        .eq('pair_high', pair.high)
        .order('created_at', ascending: true);
    return <DirectMessage>[
      for (final row in rows as List<dynamic>)
        _message(row as Map<String, dynamic>, personId),
    ];
  }

  @override
  Future<DirectMessage> sendMessageTo(
      {required String personId, required String body}) async {
    final pair = _pairWith(personId);
    final row = await client
        .from('direct_messages')
        .insert(<String, dynamic>{
          'pair_low': pair.low,
          'pair_high': pair.high,
          'author_id': _userId,
          'body': body.trim(),
        })
        .select(_messageColumns)
        .single();
    return _message(row, personId);
  }

  @override
  Future<void> deleteMessage(DirectMessage message) async {
    await client.from('direct_messages').delete().eq('id', message.id);
  }

  @override
  Future<List<ThreadSummary>> myThreads() async {
    final rows = await client.rpc<dynamic>('my_threads');
    return <ThreadSummary>[
      for (final value in (rows as List<dynamic>? ?? const <dynamic>[]))
        _thread(Map<String, dynamic>.from(value as Map)),
    ];
  }

  ThreadSummary _thread(Map<String, dynamic> row) {
    final at = row['last_at'] as String?;
    return ThreadSummary(
      kind: row['kind'] == 'room' ? ThreadKind.room : ThreadKind.person,
      targetId: row['target'] as String,
      name: row['name'] as String? ?? 'Somebody',
      icon: row['icon'] as String?,
      avatarPath: row['avatar_path'] as String?,
      memberCount: (row['member_count'] as num?)?.toInt() ?? 2,
      lastBody: row['last_body'] as String?,
      lastAuthorId: row['last_author_id'] as String?,
      lastAuthorName: row['last_author_name'] as String?,
      lastAt: at == null ? null : DateTime.parse(at).toLocal(),
      unread: (row['unread'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<void> markThreadRead(
      {required ThreadKind kind, required String targetId}) async {
    await client.rpc<void>('mark_thread_read', params: <String, dynamic>{
      'thread_kind': kind.name,
      'thread_target': targetId,
    });
  }

  static const String _roomMessageColumns =
      'id, room_id, author_id, body, created_at, '
      'author:profiles!room_messages_author_id_fkey(display_name)';

  RoomMessage _roomMessage(Map<String, dynamic> row) {
    final author = row['author'] as Map<String, dynamic>?;
    return RoomMessage(
      id: row['id'] as String,
      roomId: row['room_id'] as String,
      authorId: row['author_id'] as String,
      authorName: author?['display_name'] as String? ?? 'Somebody',
      body: row['body'] as String,
      createdAt: DateTime.parse(row['created_at'] as String).toLocal(),
    );
  }

  @override
  Future<List<RoomMessage>> loadRoomMessages(String roomId) async {
    final rows = await client
        .from('room_messages')
        .select(_roomMessageColumns)
        .eq('room_id', roomId)
        .order('created_at', ascending: true);
    return <RoomMessage>[
      for (final row in rows as List<dynamic>)
        _roomMessage(row as Map<String, dynamic>),
    ];
  }

  @override
  Future<RoomMessage> sendRoomMessage(
      {required String roomId, required String body}) async {
    final row = await client
        .from('room_messages')
        .insert(<String, dynamic>{
          'room_id': roomId,
          'author_id': _userId,
          'body': body.trim(),
        })
        .select(_roomMessageColumns)
        .single();
    return _roomMessage(row);
  }

  @override
  Future<void> deleteRoomMessage(RoomMessage message) async {
    await client.from('room_messages').delete().eq('id', message.id);
  }

  @override
  Future<Tonight> tonight() async {
    final rows = await client.rpc<dynamic>('tonight');
    final list = rows as List<dynamic>? ?? const <dynamic>[];
    if (list.isEmpty) return const Tonight();
    final row = Map<String, dynamic>.from(list.first as Map);
    final promptId = row['prompt_id'];
    final prompt = promptId == null
        ? null
        : TonightPrompt(
            id: (promptId as num).toInt(),
            kind: row['kind'] as String? ?? 'first_line',
            title: row['title'] as String? ?? '',
            body: row['body'] as String? ?? '',
            cta: row['cta'] as String? ?? 'Open',
          );
    final songId = row['song_id'] as String?;
    final song = songId == null
        ? null
        : TonightSong(
            projectId: songId,
            title: row['song_title'] as String? ?? 'A song',
            key: row['song_key'] as String? ?? '',
            chords: <String>[
              for (final c in (row['song_chords'] as List<dynamic>? ?? const <dynamic>[]))
                c as String,
            ],
          );
    return Tonight(prompt: prompt, song: song);
  }

  @override
  Future<List<ReleaseNote>> releaseNotes() async {
    final rows = await client.rpc<dynamic>('release_notes');
    return <ReleaseNote>[
      for (final value in (rows as List<dynamic>? ?? const <dynamic>[]))
        ReleaseNote(
          sha: (value as Map)['sha'] as String,
          title: value['title'] as String? ?? '',
          body: value['body'] as String? ?? '',
          mergedAt: DateTime.parse(value['merged_at'] as String).toLocal(),
        ),
    ];
  }

  @override
  Future<List<StandingWant>> myWants() async {
    final rows = await client.rpc<dynamic>('my_wants');
    return <StandingWant>[
      for (final row in (rows as List<dynamic>? ?? const <dynamic>[]))
        _want(row as Map<String, dynamic>),
    ];
  }

  @override
  Future<StandingWant> leaveWant({
    required String part,
    required String label,
    String? note,
  }) async {
    final id = await client.rpc<dynamic>(
      'leave_want',
      params: <String, dynamic>{
        'in_part': part.trim().toLowerCase(),
        'in_label': label,
        'in_note': note == null || note.trim().isEmpty ? null : note.trim(),
      },
    );
    final wants = await myWants();
    return wants.firstWhere(
      (want) => want.id == '$id',
      orElse: () => StandingWant(
        id: '$id',
        part: part.trim().toLowerCase(),
        label: label,
        note: note,
        expiresAt: DateTime.now().add(const Duration(days: 30)),
      ),
    );
  }

  @override
  Future<void> dropWant(String id) async {
    await client.rpc<dynamic>('drop_want', params: <String, dynamic>{'target': id});
  }

  @override
  Future<List<LessonLink>> myLessonLinks() async {
    final rows = await client.rpc<dynamic>('my_lesson_links');
    final list = rows as List<dynamic>? ?? const <dynamic>[];
    return list.map((each) {
      final row = each as Map<String, dynamic>;
      return LessonLink(
        id: row['id'] as String,
        code: row['code'] as String,
        title: row['title'] as String? ?? 'Lessons',
        createdAt: DateTime.tryParse('${row['created_at']}')?.toLocal() ?? DateTime.now(),
        students: (row['students'] as num?)?.toInt() ?? 0,
        classRoomId: row['class_room_id'] as String?,
        classRoomName: row['class_room_name'] as String?,
      );
    }).toList(growable: false);
  }

  @override
  Future<LessonLink> openLessonLink(String title, {bool asClass = false}) async {
    final String code;
    try {
      code = '${await client.rpc<dynamic>('open_lesson_link', params: <String, dynamic>{
        'in_title': title.trim(),
        'in_class': asClass,
      })}';
    } on PostgrestException catch (error) {
      if (error.hint == lessonBirthMonthHint) throw const LessonNeedsABirthMonth();
      rethrow;
    }
    // Read back by its code rather than as "the" link: there are several
    // now (0148), and the newest is not always the last in the list.
    for (final link in await myLessonLinks()) {
      if (link.code == code) return link;
    }
    throw StateError('The lesson link was made but could not be read back.');
  }

  @override
  Future<void> setLessonLinkClass(String linkId, {required bool asClass}) async {
    try {
      await client.rpc<dynamic>('set_lesson_link_class', params: <String, dynamic>{
        'in_link': linkId,
        'in_class': asClass,
      });
    } on PostgrestException catch (error) {
      if (error.hint == lessonBirthMonthHint) throw const LessonNeedsABirthMonth();
      rethrow;
    }
  }

  @override
  Future<void> closeLessonLink(String linkId) async {
    await client.rpc<dynamic>('close_lesson_link', params: <String, dynamic>{'in_link': linkId});
  }

  @override
  Future<String> joinLessonLink(String code) async {
    try {
      final room = await client.rpc<dynamic>('join_lesson_link', params: <String, dynamic>{'in_code': code});
      return '$room';
    } on PostgrestException catch (error) {
      // 0139: lesson links are for people 18 and over, and this account has
      // never said when it was born. Every other refusal already carries a
      // sentence written for whoever is holding the phone.
      if (error.hint == lessonBirthMonthHint) throw const LessonNeedsABirthMonth();
      rethrow;
    }
  }

  @override
  Future<bool> isLessonRoom(String roomId) async {
    // Nothing is selected but the key, because nothing else is needed here:
    // the teacher is the room's owner and the app already knows the members.
    //
    // The read is safe on its own terms. lesson_rooms_read_either (0129)
    // shows a row to the student it belongs to and to the teacher whose link
    // made it, so a third account asking about the same room gets nothing
    // back rather than a hint that the lesson exists.
    final rows = await client
        .from('lesson_rooms')
        .select('room_id')
        .eq('room_id', roomId)
        .limit(1);
    return (rows as List<dynamic>).isNotEmpty;
  }

  @override
  Future<List<String>> lessonRoomsTaught() async {
    // lesson_rooms shows a row to its student and to the teacher whose link
    // made it (0129). The inner join on lesson_links, which is read-own,
    // keeps only the rooms this person is the teacher of; the filter says
    // the same thing again in case a link ever becomes readable to more
    // people than its teacher.
    final rows = await client
        .from('lesson_rooms')
        .select('room_id, lesson_links!inner(teacher_id)')
        .eq('lesson_links.teacher_id', currentUserId);
    return (rows as List<dynamic>)
        .map((each) => (each as Map<String, dynamic>)['room_id'] as String)
        .toList(growable: false);
  }

  @override
  Future<List<String>> sendSongToStudents({
    required String projectId,
    required List<String> roomIds,
  }) async {
    // Two halves (0149). The server makes each copy and says which
    // recording should follow it; Storage copies that object, server-side,
    // into the copy's own folder; and the server puts the files row and the
    // analysis on the copy. SQL cannot write storage, which is why the app
    // is in the middle, and a copy gets an object of its own rather than a
    // pointer at the teacher's because a files row owns the object it
    // names: the delete policy and removeReference both act on it.
    final rows = await client.rpc<dynamic>('send_song_to_students', params: <String, dynamic>{
      'in_project': projectId,
      'in_rooms': roomIds,
    });
    final sent = <String>[];
    for (final each in rows as List<dynamic>? ?? const <dynamic>[]) {
      final row = each as Map<String, dynamic>;
      final room = row['to_room'] as String;
      final copy = row['song_copy'] as String;
      final recording = row['recording'] as String?;
      // Counted only when the copy is new. A copy handed back so that its
      // recording can be finished is a song the student has had since it
      // was sent, and "Sent to 2 students" a week later would be about
      // that week rather than this tap.
      if (row['fresh'] as bool? ?? false) sent.add(room);
      if (recording == null) continue;
      // Named as attachReference names one, reference_<microseconds>, so
      // the stem folder the analysis worker derives from it is the copy's
      // own. A copy that fails here leaves the song without its recording
      // and the copy on the list a resend hands back, so the teacher can
      // finish it by sending again; a fresh copy is still counted, because
      // the song did arrive.
      final name = recording.split('/').last;
      final dot = name.lastIndexOf('.');
      final ext = dot == -1 ? '' : name.substring(dot);
      final destination =
          '$room/$copy/analysis/reference_${DateTime.now().microsecondsSinceEpoch}$ext';
      try {
        await client.storage.from('room-files').copy(recording, destination);
        final attached = await client.rpc<dynamic>('attach_sent_recording', params: <String, dynamic>{
          'in_copy': copy,
          'in_storage_path': destination,
        });
        if (attached != true) {
          // The copy got a recording of its own between the two halves --
          // the student put one on it -- so the object just copied is the
          // one nobody plays. It cannot be removed from here: no files row
          // names it, and the delete policy (0013) deletes by files row.
          // Reported with its path so it is at least visible; a policy for
          // deleting orphans is more RLS than a race this narrow deserves.
          unawaited(ErrorReporter().reportWarning(
            service: 'app',
            stage: 'sent_recording_unused',
            message: destination,
            projectId: copy,
          ));
        }
      } catch (error) {
        unawaited(ErrorReporter().reportWarning(
          service: 'app',
          stage: 'sent_recording',
          message: error.toString(),
          projectId: copy,
        ));
      }
    }
    return sent;
  }

  @override
  Future<List<String>> briefStudents({
    required String projectId,
    required List<String> roomIds,
    required BriefToSend brief,
  }) async {
    if (roomIds.isEmpty) return const <String>[];
    // The copies, found by where they came from (0149). Asked for rather
    // than remembered from the send, because a send hands back only the
    // copies it made just now, and the second week of the same piece is a
    // brief for copies the students have had all along. The teacher owns
    // these rooms, so the read policy shows them the rows.
    final copies = await client
        .from('projects')
        .select('id')
        .eq('copied_from', projectId)
        .inFilter('room_id', roomIds)
        .isFilter('deleted_at', null);
    final songs = <String>[
      for (final each in copies as List<dynamic>) (each as Map<String, dynamic>)['id'] as String,
    ];
    if (songs.isEmpty) return const <String>[];
    // One call for all of them, so that a refusal briefs nobody rather than
    // half a studio. The server decides who may: the teacher of each lesson,
    // still owning its room (0150).
    final took = await client.rpc<dynamic>('set_song_briefs', params: <String, dynamic>{
      'in_projects': songs,
      'in_passage': brief.passage,
      'in_rate': brief.rate,
      'in_start_ms': brief.startMs,
      'in_end_ms': brief.endMs,
      'in_listening_for': brief.listeningFor,
      'in_due_words': brief.dueWords,
    });
    return <String>[for (final each in took as List<dynamic>? ?? const <dynamic>[]) '$each'];
  }

  @override
  Future<List<SongBrief>> mySongBriefs() async {
    // No filter on who: the read policy shows a brief to the two people it
    // is between and to nobody else (0150), and a second copy of that rule
    // here is one more place for the two to disagree.
    final rows = await client
        .from('song_briefs')
        .select('id, project_id, teacher_id, student_id, teacher_name, passage, '
            'start_ms, end_ms, rate, listening_for, due_words, set_at')
        .order('set_at', ascending: false)
        // One brief a song, so this counts copies rather than weeks: a
        // studio of nine students with a few pieces each on the go is the
        // teacher's whole side of it, and a student's side is one a lesson.
        // Past this the oldest stops drawing its line on its song, which is
        // the mildest way for a read to run out.
        .limit(200);
    return <SongBrief>[
      for (final each in rows as List<dynamic>) _songBrief(Map<String, dynamic>.from(each as Map)),
    ];
  }

  SongBrief _songBrief(Map<String, dynamic> row) {
    final start = row['start_ms'];
    final end = row['end_ms'];
    final loop = start is num && end is num && end > start;
    final due = (row['due_words'] as String? ?? '').trim();
    return SongBrief(
      id: row['id'] as String,
      projectId: row['project_id'] as String,
      teacherId: row['teacher_id'] as String,
      studentId: row['student_id'] as String,
      teacherName: row['teacher_name'] as String? ?? 'Your teacher',
      passage: row['passage'] as String? ?? 'The whole song',
      startMs: loop ? start.round() : null,
      endMs: loop ? end.round() : null,
      rate: (row['rate'] as num?)?.toDouble() ?? 1,
      listeningFor: <String>[
        for (final phrase in row['listening_for'] as List<dynamic>? ?? const <dynamic>[])
          if ('$phrase'.trim().isNotEmpty) '$phrase'.trim(),
      ],
      dueWords: due.isEmpty ? null : due,
      setAt: DateTime.tryParse('${row['set_at']}')?.toLocal() ?? DateTime.now(),
    );
  }

  @override
  Future<List<SentTake>> takesSentToMe() async {
    // No filter and no argument. The function is the permission (0151): it
    // reads the caller's own lessons and nothing else, so there is nothing
    // for a phone to ask honestly and nothing here to disagree with it.
    //
    // The order is the server's and is kept as it arrives: oldest first, so
    // what came in last is last. Anything sorting this list again would be
    // sorting by a column that deliberately does not come back.
    final rows = await client.rpc<dynamic>('takes_sent_to_me');
    return <SentTake>[
      for (final each in rows as List<dynamic>? ?? const <dynamic>[])
        _sentTake(Map<String, dynamic>.from(each as Map)),
    ];
  }

  SentTake _sentTake(Map<String, dynamic> row) => SentTake(
        takeId: row['take_id'] as String,
        projectId: row['project_id'] as String,
        songTitle: (row['song_title'] as String? ?? '').trim().isEmpty
            ? 'Untitled'
            : (row['song_title'] as String).trim(),
        studentId: row['student_id'] as String,
        studentName: (row['student_name'] as String? ?? '').trim().isEmpty
            ? 'A student'
            : (row['student_name'] as String).trim(),
        storagePath: row['storage_path'] as String? ?? '',
        // Where the take sits on the song, so a note pinned while listening
        // is filed at the bar it was heard at rather than at the same number
        // of seconds into the song (0045, 0141).
        startMs: (row['start_ms'] as num?)?.round() ?? 0,
        offsetMs: (row['offset_ms'] as num?)?.round() ?? 0,
      );

  @override
  Future<String> myMeetingCode() async => '${await client.rpc<dynamic>('my_meeting_code')}';

  @override
  Future<String> changeMyMeetingCode() async => '${await client.rpc<dynamic>('change_my_meeting_code')}';

  @override
  Future<CallStanding> myCallStanding() async =>
      callStandingFrom('${await client.rpc<dynamic>('my_call_standing')}');

  @override
  Future<CallStanding> setMyBirthMonth({required int year, required int month}) async {
    final standing = await client.rpc<dynamic>(
      'set_my_birth_month',
      params: <String, dynamic>{'in_year': year, 'in_month': month},
    );
    return callStandingFrom('$standing');
  }

  @override
  Future<CallTicket> callTicket({required String roomId, required String device}) async {
    try {
      final response = await client.functions.invoke(
        'call-token',
        body: <String, dynamic>{'room_id': roomId, 'device': device},
      );
      final data = response.data;
      if (data is! Map || data['token'] == null) {
        throw const CallRefused('The call could not start just now.');
      }
      return CallTicket(
        url: data['url'] as String,
        token: data['token'] as String,
        room: data['room'] as String? ?? '',
        identity: data['identity'] as String? ?? '',
      );
    } on FunctionException catch (error) {
      final details = error.details;
      final said = details is Map ? details['error'] as String? : null;
      if (details is Map && details['reason'] == 'birth_month_needed') {
        throw CallRefused(said ?? 'Your birth month first.', birthMonthNeeded: true);
      }
      throw CallRefused(said ?? 'The call could not start just now.');
    }
  }

  @override
  Future<void> hearMeInCall({required String roomId, required String device}) async {
    await client.rpc<dynamic>(
      'hear_me_in_call',
      params: <String, dynamic>{'in_room': roomId, 'in_device': device},
    );
  }

  @override
  Future<void> leaveCall({required String roomId, required String device}) async {
    await client.rpc<dynamic>(
      'leave_call',
      params: <String, dynamic>{'in_room': roomId, 'in_device': device},
    );
  }

  @override
  Future<List<InCallPerson>> roomCall(String roomId) async {
    final rows = await client.rpc<dynamic>('room_call', params: <String, dynamic>{'in_room': roomId});
    return <InCallPerson>[
      for (final row in (rows as List<dynamic>? ?? const <dynamic>[]))
        InCallPerson(
          userId: (row as Map)['user_id'] as String,
          displayName: row['display_name'] as String? ?? 'Somebody',
        ),
    ];
  }

  @override
  Future<MetPerson> personWithMeetingCode(String code) async {
    final rows = await client.rpc<dynamic>(
      'person_with_meeting_code',
      params: <String, dynamic>{'in_code': code},
    );
    final row = (rows as List<dynamic>).single as Map<String, dynamic>;
    return MetPerson(
      personId: row['person_id'] as String,
      displayName: (row['display_name'] as String?) ?? 'Someone',
      avatarPath: row['avatar_path'] as String?,
      plays: <String>[
        for (final part in (row['plays'] as List<dynamic>? ?? const <dynamic>[])) part.toString(),
      ],
      standing: standingFrom(row['state'] as String?),
      askedYou: row['direction'] == 'incoming',
    );
  }

  @override
  Future<List<PracticeMark>> myPracticeMarks() async {
    final rows = await client.rpc<dynamic>('my_practice_marks');
    return <PracticeMark>[
      for (final row in (rows as List<dynamic>? ?? const <dynamic>[]))
        _practiceMark(row as Map<String, dynamic>),
    ];
  }

  @override
  Future<void> keepPracticeMark(PracticeMark mark) async {
    await client.rpc<dynamic>('keep_practice_mark', params: <String, dynamic>{
      'in_id': mark.id,
      'in_project': mark.projectId,
      'in_led_by': mark.ledBy,
      'in_led_by_name': mark.ledByName,
      'in_note': mark.note,
      'in_parts': <Map<String, dynamic>>[for (final part in mark.parts) part.toJson()],
    });
  }

  @override
  Future<void> leavePracticeForStudent({
    required String projectId,
    required String studentId,
    required String label,
    required double rate,
    int? startMs,
    int? endMs,
    String? note,
  }) async {
    // Nothing is read back afterwards, and there is nothing to read: the
    // mark belongs to the student from the moment it is written (0128), and
    // the id the function returns is of no use to the teacher who sent it.
    await client.rpc<dynamic>('leave_practice_mark', params: <String, dynamic>{
      'in_project': projectId,
      'in_student': studentId,
      'in_label': label,
      'in_rate': rate,
      'in_start_ms': startMs,
      'in_end_ms': endMs,
      'in_note': note,
    });
  }

  PracticeMark _practiceMark(Map<String, dynamic> row) => PracticeMark(
        id: row['id'] as String,
        projectId: row['project_id'] as String,
        ledBy: row['led_by'] as String?,
        ledByName: row['led_by_name'] as String? ?? 'Someone',
        note: row['note'] as String?,
        parts: <PracticePart>[
          for (final entry in (row['parts'] as List<dynamic>? ?? const <dynamic>[]))
            if (PracticePart.fromJson(entry) case final part?) part,
        ],
        updatedAt: DateTime.tryParse('${row['updated_at']}')?.toLocal() ?? DateTime.now(),
      );

  static const String _momentNoteColumns =
      'id, project_id, layer_id, on_shared_take, at_ms, end_ms, body, '
      'voice_path, author_id, created_at, '
      'author:profiles!moment_notes_author_id_fkey(display_name)';

  @override
  Future<List<MomentNote>> loadMomentNotes(String projectId) async {
    // No filter on deleted_at: the read policy already hides a note somebody
    // took back, and a second copy of that rule here is one more place for
    // the two to disagree.
    final rows = await client
        .from('moment_notes')
        .select(_momentNoteColumns)
        .eq('project_id', projectId)
        .order('at_ms', ascending: true);
    return <MomentNote>[
      for (final row in rows as List<dynamic>)
        _momentNote(Map<String, dynamic>.from(row as Map)),
    ];
  }

  @override
  Future<MomentNote> addMomentNote({
    required String projectId,
    required int atMs,
    required String body,
    String? layerId,
    int? endMs,
  }) async {
    final row = await client
        .from('moment_notes')
        .insert(<String, dynamic>{
          'project_id': projectId,
          'layer_id': layerId,
          'at_ms': atMs < 0 ? 0 : atMs,
          if (endMs != null) 'end_ms': endMs,
          'body': body.trim(),
          'author_id': _userId,
        })
        .select(_momentNoteColumns)
        .single();
    return _momentNote(row);
  }

  @override
  Future<MomentNote> addSpokenMomentNote({
    required String roomId,
    required String projectId,
    required int atMs,
    required Uint8List bytes,
    String? layerId,
  }) async {
    // A random name rather than the clock. For somebody in the room who
    // cannot read the note, the row is the gate and this id is the lock
    // (0152): the room-files path policy admits every room member to every
    // object under the room, so the name is the one thing between them and
    // a note on somebody else's draft.
    final storagePath = '$roomId/$projectId/moments/${_randomId()}.wav';
    // The bytes first, the way a take and a line voice note go up. Nothing
    // is caught here: a failed upload throws to the screen, which says so.
    await client.storage.from('room-files').uploadBinary(
          storagePath,
          bytes,
          fileOptions: const FileOptions(contentType: 'audio/wav', upsert: false),
        );
    try {
      final row = await client
          .from('moment_notes')
          .insert(<String, dynamic>{
            'project_id': projectId,
            'layer_id': layerId,
            'at_ms': atMs < 0 ? 0 : atMs,
            'voice_path': storagePath,
            'author_id': _userId,
          })
          .select(_momentNoteColumns)
          .single();
      return _momentNote(row);
    } catch (error) {
      // Bytes with no row would be an object nobody can reach and nothing
      // knows about. The original error is the one worth surfacing, so a
      // failed tidy-up does not replace it.
      try {
        await client.storage.from('room-files').remove(<String>[storagePath]);
      } catch (_) {}
      rethrow;
    }
  }

  static String _randomId() {
    final random = math.Random.secure();
    return List<String>.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  @override
  Future<Uint8List> loadSpokenNote(MomentNote note) {
    final path = note.voicePath;
    if (path == null) throw StateError('That note was typed, not spoken.');
    return client.storage.from('room-files').download(path);
  }

  @override
  Future<void> deleteMomentNote(MomentNote note) async {
    // The object first, while the row is still live: the storage delete
    // policy finds the row through moment_notes_read, which hides a stamped
    // row from everybody. Best-effort, because the row is what makes the
    // audio reachable (moment_note_audio_read) -- an object left behind
    // costs storage and is heard by nobody, whereas a note left behind
    // because storage was slow would be the failure that matters.
    final path = note.voicePath;
    if (path != null) {
      try {
        await client.storage.from('room-files').remove(<String>[path]);
      } catch (_) {}
    }
    // A function rather than a delete: the row is kept and stamped, so the
    // words can never come back and nothing has to guess whether a missing
    // note was deleted or never existed.
    await client.rpc<void>(
      'delete_moment_note',
      params: <String, dynamic>{'target_note': note.id},
    );
  }

  @override
  Future<DateTime> sealTake(String layerId, {required DateTime until}) async {
    // The function answers with the day the take opens, which is [until]
    // unless it was sealed already -- then it is the day it already had.
    final opens = await client.rpc<dynamic>('seal_take', params: <String, dynamic>{
      'target_layer': layerId,
      'open_on': until.toUtc().toIso8601String(),
    });
    return DateTime.tryParse('$opens')?.toLocal() ?? until;
  }

  @override
  Future<List<SealedTake>> sealedTakesDue() async {
    final rows = await client.rpc<dynamic>('sealed_takes_due');
    final now = DateTime.now();
    return <SealedTake>[
      for (final row in (rows as List<dynamic>? ?? const <dynamic>[]))
        _sealedTake(Map<String, dynamic>.from(row as Map), now),
    ];
  }

  @override
  Future<void> unsealTake(String layerId) async {
    await client.rpc<void>(
      'unseal_take',
      params: <String, dynamic>{'target_layer': layerId},
    );
  }

  SealedTake _sealedTake(Map<String, dynamic> row, DateTime now) => SealedTake(
        id: row['layer_id'] as String,
        projectId: row['project_id'] as String,
        songTitle: row['song_title'] as String? ?? 'a song',
        storagePath: row['storage_path'] as String? ?? '',
        label: row['label'] as String? ?? '',
        part: row['part'] as String? ?? 'other',
        durationMs: (row['duration_ms'] as num?)?.toInt() ?? 0,
        // A day that will not parse still has a card: "Earlier today" is a
        // poorer sentence than "A year ago", and no sentence is poorer still.
        sealedAt: DateTime.tryParse('${row['sealed_at']}')?.toLocal() ?? now,
        opensAt: DateTime.tryParse('${row['sealed_until']}')?.toLocal() ?? now,
      );

  // Take turns on the loop (0159). Every one of these is a function on the
  // server: whose turn it is, who may sit in a round and what a skip tells
  // anybody are rules, and rules kept in the app are rules a second client
  // does not have.

  @override
  Future<List<LoopRound>> loadLoopRounds(String projectId) async {
    final rows = await client.rpc<dynamic>(
      'loop_rounds_for',
      params: <String, dynamic>{'target_project': projectId},
    );
    return <LoopRound>[
      for (final row in (rows as List<dynamic>? ?? const <dynamic>[]))
        LoopRound.fromRow(
          Map<String, dynamic>.from(row as Map),
          projectId: projectId,
        ),
    ];
  }

  @override
  Future<String> startLoopRound({
    required String projectId,
    required int startMs,
    required int endMs,
    List<String> order = const <String>[],
  }) async {
    final id = await client.rpc<dynamic>(
      'start_loop_round',
      params: <String, dynamic>{
        'target_project': projectId,
        'in_start_ms': startMs,
        'in_end_ms': endMs,
        'in_order': order,
      },
    );
    return '$id';
  }

  @override
  Future<void> joinLoopRound(String roundId) async {
    await client.rpc<dynamic>(
      'join_loop_round',
      params: <String, dynamic>{'target_round': roundId},
    );
  }

  @override
  Future<void> skipMyTurn(String roundId) async {
    await client.rpc<dynamic>(
      'skip_my_turn',
      params: <String, dynamic>{'target_round': roundId},
    );
  }

  @override
  Future<void> handInMyTurn({
    required String roundId,
    required String layerId,
  }) async {
    await client.rpc<dynamic>(
      'hand_in_my_turn',
      params: <String, dynamic>{
        'target_round': roundId,
        'target_layer': layerId,
      },
    );
  }

  @override
  Future<void> endLoopRound(String roundId) async {
    await client.rpc<dynamic>(
      'end_loop_round',
      params: <String, dynamic>{'target_round': roundId},
    );
  }

  MomentNote _momentNote(Map<String, dynamic> row) {
    final author = row['author'];
    return MomentNote(
      id: row['id'] as String,
      projectId: row['project_id'] as String,
      layerId: row['layer_id'] as String?,
      // Written by the trigger, not by us. Absent only if an older client
      // ever reads a row from before 0141, and "the room can see it" is the
      // reading that makes somebody careful rather than careless.
      onSharedTake: row['on_shared_take'] as bool? ?? true,
      atMs: (row['at_ms'] as num?)?.toInt() ?? 0,
      endMs: (row['end_ms'] as num?)?.toInt(),
      // Null for a spoken note (0152), which has a voice instead.
      body: row['body'] as String? ?? '',
      voicePath: row['voice_path'] as String?,
      authorId: row['author_id'] as String? ?? '',
      authorName:
          author is Map ? author['display_name'] as String? : null,
      createdAt:
          DateTime.tryParse('${row['created_at']}')?.toLocal() ?? DateTime.now(),
    );
  }

  @override
  Future<List<WantAround>> wantsAround() async {
    final rows = await client.rpc<dynamic>('wants_around');
    return <WantAround>[
      for (final row in (rows as List<dynamic>? ?? const <dynamic>[]))
        WantAround(
          part: (row as Map)['part'] as String? ?? '',
          label: row['label'] as String? ?? '',
          people: (row['people'] as num?)?.toInt() ?? 0,
        ),
    ];
  }

  @override
  Future<SongAnswer> askTheSong({
    required String projectId,
    required String question,
  }) async {
    final response = await client.functions.invoke(
      'ask-the-song',
      body: <String, dynamic>{'projectId': projectId, 'question': question},
    );
    final data = response.data;
    if (data is! Map) {
      throw StateError('The app could not think about that just now.');
    }
    final map = Map<String, dynamic>.from(data);
    if (map['error'] != null) throw StateError(map['error'].toString());
    final ask = map['ask'];
    return SongAnswer(
      answer: map['answer'] as String? ?? '',
      askPart: ask is Map ? ask['part'] as String? : null,
      askLabel: ask is Map
          ? (ask['label'] as String? ?? 'Or ask somebody in the room')
          : 'Or ask somebody in the room',
      model: map['model'] as String? ?? 'unknown',
    );
  }

  StandingWant _want(Map<String, dynamic> row) => StandingWant(
        id: row['id'] as String,
        part: row['part'] as String? ?? '',
        label: row['label'] as String? ?? '',
        note: row['note'] as String?,
        expiresAt: DateTime.tryParse('${row['expires_at']}')?.toLocal() ??
            DateTime.now(),
        matched: (row['matched'] as num?)?.toInt() ?? 0,
      );

  DirectMessage _message(Map<String, dynamic> row, String personId) {
    final author = row['author'];
    return DirectMessage(
      id: row['id'] as String,
      personId: personId,
      authorId: row['author_id'] as String? ?? '',
      authorName: author is Map
          ? (author['display_name'] as String? ?? 'Somebody')
          : 'Somebody',
      body: row['body'] as String? ?? '',
      createdAt:
          DateTime.tryParse(row['created_at'] as String? ?? '')?.toLocal() ??
              DateTime.now(),
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
  }) =>
      createProjectInviteFor(
          projectId: project.id, email: email, role: role);

  @override
  Future<InviteResult> createProjectInviteFor({
    required String projectId,
    required String email,
    RoomRole role = RoomRole.editor,
  }) async {
    final cleaned = email.trim().toLowerCase();
    if (!cleaned.contains('@')) throw const NameConflict('Enter a valid email address.');
    final result = await client.rpc<Map<String, dynamic>>(
      'create_project_invitation',
      params: <String, dynamic>{
        'target_project': projectId,
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
  Future<void> askForHelp({
    required String question,
    String? matchedAnswer,
    String? route,
  }) async {
    await client.rpc<dynamic>(
      'ask_for_help',
      params: <String, dynamic>{
        'in_question': question,
        'in_matched_answer': matchedAnswer,
        'in_route': route,
        'in_platform': defaultTargetPlatform.name,
        'in_app_version': BetaConfig.appVersion,
      },
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
      // An unrecognised answer reads as null — nobody asked — rather than
      // throwing: 0142's check constraint can gain a value in a migration
      // that ships before the app that knows about it.
      songOrigin: SongOrigin.fromWireName(row['song_origin'] as String?),
      keyOverride: row['key_override'] as String?,
      // Counted from one, and anything else is read as nobody having said:
      // 0161's check refuses it, and a song list is not worth throwing over.
      barOneDownbeat: switch (row['bar_one_downbeat']) {
        final num said when said >= 1 => said.toInt(),
        _ => null,
      },
      // Read through the same parse the app writes with, so a tag stored by
      // a build that spelled it differently still lays the song out.
      // Anything that is not a tag reads as nobody having said, which is how
      // every other answer on this row treats something it cannot read.
      language: languageTagTyped(row['language'] as String?),
      // Tidied rather than trusted, the way the bar 1 above is. A stress on a
      // beat a shortened cycle no longer has is a stale answer and not a
      // broken song, so SongCycle drops it (0162).
      cycle: SongCycle.of(
        (row['cycle_beats'] as num?)?.toInt(),
        <int>[
          for (final beat
              in row['cycle_accents'] as List<dynamic>? ?? const <dynamic>[])
            if (beat is num) beat.toInt(),
        ],
      ),
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
      type: notificationTypeFromSql(row['type'] as String? ?? ''),
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
        'song_origin': project.songOrigin?.wireName,
        'key_override': project.keyOverride,
        'bar_one_downbeat': project.barOneDownbeat,
        'language': project.language,
        'cycle_beats': project.cycle?.beats,
        'cycle_accents': project.cycle?.accents,
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
