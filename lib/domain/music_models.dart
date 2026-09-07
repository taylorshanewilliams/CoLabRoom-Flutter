import 'dart:typed_data';

import 'song_analysis_models.dart' show SongAnalysisState;

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
    this.avatarPath,
  });

  final String userId;
  final String displayName;
  final RoomRole role;
  final int colorValue;

  /// Storage path (in the `avatars` bucket) of this person's profile
  /// picture, or null when they have not set one.
  ///
  /// It comes from `profiles`, not from the membership: the same person in
  /// three catalogs has one face and three colours.
  final String? avatarPath;
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
    this.analysisState,
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

  /// How far that recording has got through analysis, or null when there is
  /// no recording at all.
  ///
  /// It rides along with [hasAudioReference] because it comes from the same
  /// embedded row and costs nothing extra to ask for. The Control Room reads
  /// it to sort songs into the two piles that room is actually about — one
  /// waiting for a song sheet, one that already has one — instead of listing
  /// the whole account and letting the reader work it out.
  final SongAnalysisState? analysisState;

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
    SongAnalysisState? analysisState,
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
      analysisState: analysisState ?? this.analysisState,
      createdBy: createdBy ?? this.createdBy,
    );
  }
}

/// Sentinel distinguishing "argument omitted" from "explicitly set to null"
/// in `copyWith` methods that need to support clearing a nullable field.
const Object _unset = Object();

/// Something a song is asking for.
///
/// Two shapes, one object, and the difference is whether [part] is null.
///
/// A null part is an **open ask** — "I don't know what this needs, what do you
/// hear?" — which is the honest state of most unfinished songs and the shape
/// that costs the person posting it no decision at all. A named part is a
/// **specific ask** — "this needs a bridge" — for when you know exactly what
/// you want and only need somebody who can play it.
///
/// They are one class because everything downstream treats them identically:
/// the same audience, the same answering flow, the same closing. A product
/// that only carried the specific one would be a gig board.
/// Somebody you have blocked, so the setting can be undone.
///
/// Nobody wants a switch they can turn on and never find again — and a block
/// list you cannot read is one people are afraid to use in the first place.
class BlockedPerson {
  const BlockedPerson({
    required this.id,
    required this.displayName,
    required this.blockedAt,
  });

  final String id;
  final String displayName;
  final DateTime blockedAt;
}

/// Why something was reported. The short list exists so a queue can be
/// sorted; free-text-only reports are ones nobody can triage.
///
/// `copyright` is here deliberately: it is the first step of a takedown, and
/// it needs somewhere to arrive other than an inbox.
enum ReportReason { copyright, abuse, harassment, spam, sexual, violence, other }

extension ReportReasonWords on ReportReason {
  String get id => name;

  /// Said the way somebody reporting would say it, not the way a policy
  /// document would.
  String get label {
    switch (this) {
      case ReportReason.copyright:
        return 'It uses music that is not theirs';
      case ReportReason.abuse:
        return 'Abusive or hateful';
      case ReportReason.harassment:
        return 'They are harassing somebody';
      case ReportReason.spam:
        return 'Spam or a scam';
      case ReportReason.sexual:
        return 'Sexual content';
      case ReportReason.violence:
        return 'Violence or a threat';
      case ReportReason.other:
        return 'Something else';
    }
  }
}

/// One song, as the listening feed needs it.
///
/// Deliberately not [OpenMicSong]. A card in a list needs a title and a
/// reason to tap; a track that is about to play needs the audio, its length,
/// and the face of whoever made it — and it needs all of that in the page
/// that fetched it, because the next track is loading while the current one
/// plays and there is no time for another round trip.
class FeedTrack {
  const FeedTrack({
    required this.id,
    required this.title,
    required this.ownerName,
    required this.storagePath,
    required this.putUpAt,
    this.ownerId,
    this.ownerAvatarPath,
    this.askingFor = const <String>[],
    this.askNote = '',
    this.musicalKey,
    this.bpm,
    this.durationMs,
  });

  final String id;
  final String title;
  final String? ownerId;
  final String ownerName;
  final String? ownerAvatarPath;
  final DateTime putUpAt;

  /// Where the audio is. Turned into a signed URL by StreamingAudio, in a
  /// batch with the rest of the page.
  final String storagePath;

  final List<String> askingFor;
  final String askNote;
  final String? musicalKey;
  final double? bpm;
  final int? durationMs;

  bool get isAsking => askingFor.isNotEmpty || askNote.trim().isNotEmpty;

  /// What this song wants, in the words it should be shown in. The line that
  /// makes this app's feed different from every other one: not what the song
  /// *is*, but what it is missing.
  String get wants {
    if (askingFor.isNotEmpty) return 'Needs ${askingFor.join(", ")}';
    if (askNote.trim().isNotEmpty) return 'Asking for help';
    return '';
  }
}

/// A song somebody put on the Open Mic.
///
/// The other half of Open Mic. It has been a list of people since it shipped;
/// this is the thing a person can actually be asked to play on.
class OpenMicSong {
  const OpenMicSong({
    required this.id,
    required this.title,
    required this.ownerName,
    required this.putUpAt,
    this.ownerId,
    this.takeCount = 0,
    this.askingFor = const <String>[],
    this.musicalKey,
    this.bpm,
    this.askNote = '',
    this.theirParts = const <String>[],
  });

  final String id;
  final String title;
  final String? ownerId;
  final String ownerName;
  final DateTime putUpAt;

  /// Shared takes only. A private draft is not part of what a stranger hears.
  final int takeCount;

  /// The parts this song has open asks for — the one thing that decides
  /// whether somebody taps.
  final List<String> askingFor;

  final String? musicalKey;
  final double? bpm;

  /// What the person who put it up said, if they said anything.
  final String askNote;

  /// On a profile: what *that* person played on it. Empty when the song
  /// is theirs. A profile listing a song without saying they played the
  /// bass on it would be claiming somebody else's song.
  final List<String> theirParts;

  bool get isAsking => askingFor.isNotEmpty || askNote.trim().isNotEmpty;
}

/// A catalog you own, as an option in the "invite them" picker.
class InvitableRoom {
  const InvitableRoom({
    required this.id,
    required this.name,
    required this.songCount,
    this.alreadyIn = false,
    this.alreadyInvited = false,
  });

  final String id;
  final String name;
  final int songCount;
  final bool alreadyIn;
  final bool alreadyInvited;

  /// Why this row cannot be picked, or null when it can. Shown rather than
  /// hidden: a catalog missing from the list is somebody wondering where it
  /// went.
  String? get blockedBecause {
    if (alreadyIn) return 'already in';
    if (alreadyInvited) return 'already invited';
    return null;
  }
}

/// Somebody inviting you into a catalog of theirs.
class RoomInviteForMe {
  const RoomInviteForMe({
    required this.id,
    required this.roomId,
    required this.roomName,
    required this.invitedByName,
    required this.createdAt,
    this.note = '',
  });

  final String id;
  final String roomId;
  final String roomName;
  final String invitedByName;
  final String note;
  final DateTime createdAt;

  String get headline => '$invitedByName invited you to $roomName';
}

/// A song of yours, as an option in the "ask them to play on…" picker.
class OfferableSong {
  const OfferableSong({
    required this.id,
    required this.title,
    required this.updatedAt,
    this.alreadyAsked = false,
  });

  final String id;
  final String title;
  final DateTime updatedAt;

  /// This person already has an open ask about this song. Shown rather than
  /// hidden — "you asked them this yesterday" is more useful than a song
  /// quietly missing from the list.
  final bool alreadyAsked;
}

/// Somebody asking you, specifically, to play on something.
///
/// Carries the song's title without carrying the song: until it is accepted,
/// the title and the note are the only things about that project the person
/// asked is allowed to see. Deciding does not require access, and access is
/// what accepting is for.
class AskForMe {
  const AskForMe({
    required this.id,
    required this.projectId,
    required this.songTitle,
    required this.askedByName,
    required this.createdAt,
    this.part,
    this.note = '',
  });

  final String id;
  final String projectId;
  final String songTitle;
  final String askedByName;
  final String? part;
  final String note;
  final DateTime createdAt;

  String get headline => part == null
      ? '$askedByName asked you to play on $songTitle'
      : '$askedByName asked you to play $part on $songTitle';
}

class SongAsk {
  const SongAsk({
    required this.id,
    required this.projectId,
    required this.askedBy,
    required this.createdAt,
    this.part,
    this.note = '',
    this.closed = false,
  });

  final String id;
  final String projectId;

  /// Null for an open ask. Free text otherwise, so a band can name a part the
  /// app has never heard of.
  final String? part;

  /// What they'd say about it out loud. Often empty, and that is fine.
  final String note;

  final String askedBy;
  final DateTime createdAt;
  final bool closed;

  /// Whether this ask names what it wants.
  bool get isSpecific => part != null && part!.trim().isNotEmpty;

  /// What to put on a chip, in the words somebody would actually use.
  String get label => isSpecific ? 'needs ${part!.trim()}' : 'open to ideas';
}

/// One dated thing that happened to a song.
///
/// The unit of the provenance record. Deliberately flat and deliberately
/// plain: this gets printed, read by somebody who is upset, and possibly
/// shown to a lawyer, and all three of those want a dated line rather than a
/// structure.
class ProvenanceEvent {
  const ProvenanceEvent({
    required this.at,
    required this.event,
    required this.whoName,
    required this.detail,
    this.who,
  });

  final DateTime at;

  /// What happened, in the server's words: 'song created', 'lyric written',
  /// 'take recorded'. Not translated on the client — the record should read
  /// the same to everybody who is ever shown it.
  final String event;

  final String? who;
  final String whoName;
  final String detail;
}

/// A piece of work somebody made somewhere else.
///
/// Shown and never counted. Anybody can paste a link to anything, so these
/// say what a person sounds like rather than what they have done here — the
/// same line the profile draws between a declaration and a recording.
class ShowcaseLink {
  const ShowcaseLink({
    required this.id,
    required this.url,
    required this.platform,
    this.title = '',
  });

  final String id;
  final String url;

  /// Derived from the host by the server, never sent by the client — which is
  /// what stops a link to anywhere being labelled Spotify.
  final String platform;

  final String title;

  String get displayTitle => title.trim().isEmpty ? platform : title.trim();
}

/// Somebody you might work with.
///
/// Carries the two kinds of truth separately and refuses to average them.
/// [plays] is what they said — how they get found for work they want, and
/// aspiration is welcome in it. [partsRecorded] is what they have actually
/// done, counted from takes the room kept, declared by nobody.
class Musician {
  const Musician({
    required this.id,
    required this.displayName,
    required this.plays,
    required this.partsRecorded,
    required this.songsPlayedOn,
    required this.peopleWorkedWith,
    this.avatarPath,
    this.city,
    this.discoverable,
    this.locationVisibility,
  });

  final String id;
  final String displayName;
  final String? avatarPath;

  /// Only ever present when its owner chose to publish it. A city they shared
  /// with collaborators only never arrives here, even for somebody entitled
  /// to see it.
  final String? city;

  final List<String> plays;

  /// Part name to how many shared takes of it they have recorded.
  final Map<String, int> partsRecorded;

  final int songsPlayedOn;
  final int peopleWorkedWith;

  /// Whether this person appears in Open Mic, and who may see their city.
  ///
  /// Both are null for everybody except you. Somebody else's settings are
  /// their business, and a client that could read them could assemble the
  /// list of people who chose not to be listed.
  final bool? discoverable;
  final String? locationVisibility;

  /// Whether there is a record behind the claim.
  bool get hasRecord => songsPlayedOn > 0;

  /// The parts they have played most, most first.
  List<MapEntry<String, int>> get topParts {
    final entries = partsRecorded.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.take(4).toList(growable: false);
  }
}

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
