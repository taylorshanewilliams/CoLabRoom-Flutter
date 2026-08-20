import 'dart:async';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/music_models.dart';
import '../domain/name_policy.dart';
import 'music_repository.dart';

class SupabaseMusicRepository implements MusicRepository {
  SupabaseMusicRepository(this.client) {
    _channel = client
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
          callback: (_) => _notifyChanged(),
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
        .subscribe();
  }

  final SupabaseClient client;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  late final RealtimeChannel _channel;

  @override
  Stream<void> get changes => _changes.stream;

  void _notifyChanged() {
    if (!_changes.isClosed) _changes.add(null);
  }

  String get _userId {
    final id = client.auth.currentUser?.id;
    if (id == null) throw const AuthException('Sign in to use the beta workspace.');
    return id;
  }

  @override
  Future<List<MusicRoom>> loadRooms() async {
    final rows = await client
        .from('rooms')
        .select(
          'id, account_id, name, icon, created_at, updated_at, sort_order, logo_path, '
          'room_members(user_id, display_name, role, color_value), '
          'projects(id, room_id, account_id, title, description, status, created_at, updated_at, sort_order, cover_image_path, '
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
      throw _friendlyDatabaseError(error, noun: 'Room');
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
      throw _friendlyDatabaseError(error, noun: 'Room');
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
    NamePolicy.requireUsable(cleaned, label: 'Project name');
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
    NamePolicy.requireUsable(cleaned, label: 'Project name');
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
      });
    } on PostgrestException catch (error) {
      throw _friendlyDatabaseError(error, noun: 'project');
    }
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
  Future<String> createInvite({
    required MusicRoom room,
    required String email,
    RoomRole role = RoomRole.editor,
  }) async {
    final cleaned = email.trim().toLowerCase();
    if (!cleaned.contains('@')) throw const NameConflict('Enter a valid email address.');
    final result = await client.rpc<String>(
      'create_room_invitation',
      params: <String, dynamic>{
        'target_room': room.id,
        'invite_email': cleaned,
        'invite_role': role.name,
      },
    );
    return result;
  }

  @override
  Future<String> createProjectInvite({
    required SongProject project,
    required String email,
    RoomRole role = RoomRole.editor,
  }) async {
    final cleaned = email.trim().toLowerCase();
    if (!cleaned.contains('@')) throw const NameConflict('Enter a valid email address.');
    final result = await client.rpc<String>(
      'create_project_invitation',
      params: <String, dynamic>{
        'target_project': project.id,
        'invite_email': cleaned,
        'invite_role': role.name,
      },
    );
    return result;
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
    await client.from('feedback').insert(<String, dynamic>{
      'user_id': _userId,
      'category': feedback.category,
      'message': feedback.message,
      'route': feedback.route,
      'platform': feedback.platform,
      'app_version': feedback.appVersion,
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
    return RoomMember(
      userId: row['user_id'] as String,
      displayName: row['display_name'] as String? ?? 'Member',
      role: RoomRole.values.byName(row['role'] as String? ?? RoomRole.viewer.name),
      colorValue: row['color_value'] as int? ?? 0xFF32D4FF,
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
      title: row['title'] as String,
      description: row['description'] as String? ?? '',
      status: SongStatus.values.byName(row['status'] as String? ?? SongStatus.active.name),
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
      contributions: contributions,
      sortOrder: (row['sort_order'] as num?)?.toDouble() ?? 0,
      coverImagePath: row['cover_image_path'] as String?,
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
  }
}
