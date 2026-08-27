import 'dart:typed_data';

enum RoomRole { owner, editor, commenter, viewer }

enum SongStatus { active, completed }

enum ContributionKind { lyric, note, section }

class ContributionDraft {
  const ContributionDraft({required this.body, this.kind = ContributionKind.lyric});

  final String body;
  final ContributionKind kind;
}

class VoiceNote {
  const VoiceNote({
    required this.id,
    required this.projectId,
    required this.contributionId,
    required this.storagePath,
    required this.durationMs,
    required this.byteSize,
    required this.createdAt,
    this.mimeType = 'audio/wav',
  });

  final String id;
  final String projectId;
  final String contributionId;
  final String storagePath;
  final int durationMs;
  final int byteSize;
  final String mimeType;
  final DateTime createdAt;
}

class RoomMember {
  const RoomMember({
    required this.userId,
    required this.displayName,
    required this.role,
    required this.colorValue,
  });

  final String userId;
  final String displayName;
  final RoomRole role;
  final int colorValue;
}

class Contribution {
  const Contribution({
    required this.id,
    required this.projectId,
    required this.authorId,
    required this.authorName,
    required this.body,
    required this.colorValue,
    required this.createdAt,
    this.position = 0,
    this.kind = ContributionKind.lyric,
    this.revision = 1,
    this.voiceNote,
  });

  final String id;
  final String projectId;
  final String authorId;
  final String authorName;
  final String body;
  final int colorValue;
  final DateTime createdAt;
  final double position;
  final ContributionKind kind;
  final int revision;
  final VoiceNote? voiceNote;

  Contribution copyWith({
    String? body,
    double? position,
    int? revision,
    VoiceNote? voiceNote,
    bool clearVoiceNote = false,
  }) {
    return Contribution(
      id: id,
      projectId: projectId,
      authorId: authorId,
      authorName: authorName,
      body: body ?? this.body,
      colorValue: colorValue,
      createdAt: createdAt,
      position: position ?? this.position,
      kind: kind,
      revision: revision ?? this.revision,
      voiceNote: clearVoiceNote ? null : (voiceNote ?? this.voiceNote),
    );
  }
}

class SongProject {
  const SongProject({
    required this.id,
    required this.roomId,
    required this.accountId,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.description = '',
    this.status = SongStatus.active,
    this.contributions = const <Contribution>[],
    this.sortOrder = 0,
    this.coverImagePath,
    this.hasAudioReference = false,
    this.createdBy,
  });

  final String id;
  final String roomId;
  final String accountId;
  final String title;
  final String description;
  final SongStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<Contribution> contributions;
  final double sortOrder;

  /// Storage path (in the `room-files` bucket) of a custom cover image the
  /// Room owner/an editor uploaded for this song's tile, or null to fall
  /// back to the default tile icon.
  final String? coverImagePath;

  /// Whether this song has a reference recording attached (Song Analysis),
  /// surfaced on its tile as a small indicator.
  final bool hasAudioReference;

  /// Who started this song.
  ///
  /// The column has existed since 0001 and had an index on it, and nothing
  /// ever read it. [accountId] looks like it should answer the same question
  /// and cannot: since 0043 it always equals the account that owns the
  /// catalog, so every song in a catalog shares it. That identifies the
  /// catalog, not the writer.
  ///
  /// Null for a song loaded by an older path that does not ask for it, which
  /// the tile treats as "nobody in particular" rather than guessing.
  final String? createdBy;

  SongProject copyWith({
    String? roomId,
    String? title,
    String? description,
    SongStatus? status,
    DateTime? updatedAt,
    List<Contribution>? contributions,
    double? sortOrder,
    Object? coverImagePath = _unset,
    bool? hasAudioReference,
    String? createdBy,
  }) {
    return SongProject(
      id: id,
      roomId: roomId ?? this.roomId,
      accountId: accountId,
      title: title ?? this.title,
      description: description ?? this.description,
      status: status ?? this.status,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      contributions: contributions ?? this.contributions,
      sortOrder: sortOrder ?? this.sortOrder,
      coverImagePath: identical(coverImagePath, _unset) ? this.coverImagePath : coverImagePath as String?,
      hasAudioReference: hasAudioReference ?? this.hasAudioReference,
      createdBy: createdBy ?? this.createdBy,
    );
  }
}

/// Sentinel distinguishing "argument omitted" from "explicitly set to null"
/// in `copyWith` methods that need to support clearing a nullable field.
const Object _unset = Object();

class Setlist {
  const Setlist({
    required this.id,
    required this.ownerId,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.projectIds = const <String>[],
  });

  final String id;
  final String ownerId;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<String> projectIds;

  Setlist copyWith({
    String? name,
    DateTime? updatedAt,
    List<String>? projectIds,
  }) {
    return Setlist(
      id: id,
      ownerId: ownerId,
      name: name ?? this.name,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      projectIds: projectIds ?? this.projectIds,
    );
  }
}

/// A catalog: the container songs live in.
///
/// **Called a Room everywhere in the code and a catalog everywhere a person
/// can see.** The class, the `rooms` table, `room_id` on every child row and
/// every storage path that starts with one all keep the old name, because
/// renaming a table that half the RLS policies read a path segment out of
/// buys nothing and risks a great deal.
///
/// The rename happened because "Room" was doing two incompatible jobs. It is
/// in the product name as the place you work with people, and it was also the
/// label on a box that holds songs — and a box that holds songs is not a
/// room, it is a filing cabinet with a room's name on it. That is what made
/// somebody reach for "move the file to the other folder" and end up with two
/// songs called Ladder Of Life.
///
/// It also stopped scaling: a catalog can be a band, a side project, or just
/// what one person has written, and "Band" is wrong for two of those three.
/// Meanwhile the Studio and the Control Room are rooms that really are rooms.
class MusicRoom {
  const MusicRoom({
    required this.id,
    required this.accountId,
    required this.name,
    required this.icon,
    required this.createdAt,
    required this.updatedAt,
    this.members = const <RoomMember>[],
    this.projects = const <SongProject>[],
    this.sortOrder = 0,
    this.logoPath,
  });

  final String id;
  final String accountId;
  final String name;
  final String icon;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<RoomMember> members;

  /// Who started [project], when that is worth showing.
  ///
  /// Null in a catalog with one member: there the answer is always "you", and
  /// a column of identical faces is noise rather than information. Null too
  /// for a song whose author is not a member any more, or one loaded by a
  /// path that does not ask for created_by — both better drawn as the plain
  /// note than as a guess.
  ///
  /// Lives here so every surface that lists songs agrees. Home, the catalog
  /// and the Songs list each drew their own icon, and a rule copied into
  /// three places is a rule that will differ in two of them.
  RoomMember? authorOf(SongProject project) {
    if (members.length < 2) return null;
    final id = project.createdBy;
    if (id == null) return null;
    for (final member in members) {
      if (member.userId == id) return member;
    }
    return null;
  }
  final List<SongProject> projects;
  final double sortOrder;

  /// Storage path (in the `room-files` bucket) of a custom logo the Room
  /// owner/an editor uploaded for this Room's tile, or null to fall back to
  /// the default [icon] glyph.
  final String? logoPath;

  MusicRoom copyWith({
    String? name,
    String? icon,
    DateTime? updatedAt,
    List<RoomMember>? members,
    List<SongProject>? projects,
    double? sortOrder,
    Object? logoPath = _unset,
  }) {
    return MusicRoom(
      id: id,
      accountId: accountId,
      name: name ?? this.name,
      icon: icon ?? this.icon,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      members: members ?? this.members,
      projects: projects ?? this.projects,
      sortOrder: sortOrder ?? this.sortOrder,
      logoPath: identical(logoPath, _unset) ? this.logoPath : logoPath as String?,
    );
  }
}

class BetaInvite {
  const BetaInvite({
    required this.id,
    required this.roomId,
    required this.roomName,
    required this.inviterName,
    required this.email,
    this.role = RoomRole.editor,
    this.projectId,
    this.projectTitle,
  });

  final String id;
  final String roomId;
  final String roomName;
  final String inviterName;
  final String email;
  final RoomRole role;

  /// When set, this invite grants access to just this one song (see
  /// project_members / accept_project_invitation_by_id) rather than the
  /// whole Room. [projectTitle] is only meaningful alongside this.
  final String? projectId;
  final String? projectTitle;

  bool get isProjectScoped => projectId != null;
}

/// Result of [MusicRepository.createInvite]/[createProjectInvite].
///
/// [matchedAccount] tells the caller whether the invited email already has a
/// CoLabRoom account: if so, they were notified in-app and [code] only
/// exists as a fallback; if not, [code] is the only way they can join, since
/// there's no account yet to attach an in-app notification/invite row to.
class InviteResult {
  const InviteResult({required this.code, required this.matchedAccount});

  final String code;
  final bool matchedAccount;
}

enum NotificationType {
  inviteReceived,
  inviteAccepted,
  inviteDeclined,
  projectUpdate,
  /// An analysis the user started has finished. Exists so nobody has to watch
  /// a progress bar for the minutes a GPU job takes — see migration 0036.
  analysisReady,
}

class AppNotification {
  const AppNotification({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.createdAt,
    this.roomId,
    this.projectId,
    this.invitationId,
    this.actorId,
    this.readAt,
  });

  final String id;
  final NotificationType type;
  final String title;
  final String body;
  final DateTime createdAt;
  final String? roomId;
  final String? projectId;
  final String? invitationId;
  final String? actorId;
  final DateTime? readAt;

  bool get isRead => readAt != null;

  AppNotification copyWith({DateTime? readAt}) {
    return AppNotification(
      id: id,
      type: type,
      title: title,
      body: body,
      createdAt: createdAt,
      roomId: roomId,
      projectId: projectId,
      invitationId: invitationId,
      actorId: actorId,
      readAt: readAt ?? this.readAt,
    );
  }
}

/// Per-user toggles for which notification types generate an in-app
/// notification. A missing row (nobody has changed a default yet) is
/// treated as every field `true`, matching the SQL side's `coalesce(...,
/// true)` defaults in `private.wants_*`.
class NotificationPreferences {
  const NotificationPreferences({
    this.invites = true,
    this.inviteResponses = true,
    this.projectUpdates = true,
  });

  final bool invites;
  final bool inviteResponses;
  final bool projectUpdates;

  NotificationPreferences copyWith({
    bool? invites,
    bool? inviteResponses,
    bool? projectUpdates,
  }) {
    return NotificationPreferences(
      invites: invites ?? this.invites,
      inviteResponses: inviteResponses ?? this.inviteResponses,
      projectUpdates: projectUpdates ?? this.projectUpdates,
    );
  }
}

class FeedbackDraft {
  const FeedbackDraft({
    required this.category,
    required this.message,
    required this.route,
    required this.platform,
    required this.appVersion,
    this.screenshot,
  });

  final String category;
  final String message;
  final String route;
  final String platform;
  final String appVersion;
  /// The picture of what the bug report is describing, if one was attached.
  /// Optional because a screenshot doesn't always exist or apply — a
  /// suggestion, or a bug in something audio-only, has nothing to show.
  final Uint8List? screenshot;
}
