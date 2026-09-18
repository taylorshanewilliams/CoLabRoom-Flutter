import 'dart:typed_data';

import 'song_analysis_models.dart' show SongAnalysisState, midiNoteLabel;

enum RoomRole { owner, editor, commenter, viewer }

enum SongStatus { active, completed }

/// Whose song this is.
///
/// Every Musician, Same Song, 17 September 2026 calls this one of the two
/// gates: almost everything the plan wants for schools, worship teams and
/// cover bands is safe on a song the room wrote and is not safe on a song
/// somebody else wrote, and without an answer the app has to treat every
/// song as if it were the second kind.
///
/// Null — no value at all — is the honest fourth state and means nobody has
/// been asked yet, which is true of every song until its audience moves
/// beyond "Only you". A default of [ours] would be a claim the app made on
/// somebody's behalf.
///
/// No legal claim is made or recorded. These are three plain answers to a
/// plain question, used to decide what this app does with a song's words and
/// where it will let the song go.
enum SongOrigin {
  ours('ours'),
  publicDomain('public_domain'),
  cover('cover');

  const SongOrigin(this.wireName);

  /// What `projects.song_origin` holds. Spelled out rather than taken from
  /// [name], because `publicDomain` and `public_domain` are not the same
  /// string and a silent mismatch here would read as "never asked".
  final String wireName;

  static SongOrigin? fromWireName(String? value) => switch (value) {
        'ours' => SongOrigin.ours,
        'public_domain' => SongOrigin.publicDomain,
        'cover' => SongOrigin.cover,
        // Including null, which is the state the question exists to leave.
        _ => null,
      };
}

/// What answering an ask means.
///
/// Every Musician, Same Song, 17 September 2026: co-writing fights are two
/// honest memories of a session nobody wrote down. One person remembers a
/// favour, the other remembers a co-write, and neither is lying — the
/// disagreement was made when the ask was sent, because the ask never said
/// what answering it meant.
///
/// [play] is the default and shows nothing anywhere. Nearly every ask in this
/// app is somebody wanting bass under a chorus, and small print on all of
/// those would make the normal case read like a contract. [write] is the one
/// that has to be said out loud, because it is the one that changes what the
/// person answering walks away with.
enum AskTerms {
  play('play'),
  write('write');

  const AskTerms(this.wireName);

  /// What `project_asks.terms` holds.
  final String wireName;

  /// Anything the app does not recognise is playing, which is what every ask
  /// made before the column existed was.
  static AskTerms fromWireName(String? value) =>
      value == 'write' ? AskTerms.write : AskTerms.play;

  /// The one line, in one place, so the asker, the room and the person asked
  /// are all reading the same sentence. Null for [play], which says nothing.
  String? get notice => this == AskTerms.write
      ? "Writing on it: if your part is used, you're a writer."
      : null;
}

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
  /// three rooms has one face and three colours.
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
    this.songOrigin,
    this.keyOverride,
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
  /// room, so every song in a room shares it. That identifies the
  /// room, not the writer.
  ///
  /// Null for a song loaded by an older path that does not ask for it, which
  /// the tile treats as "nobody in particular" rather than guessing.
  final String? createdBy;

  /// Whose song it is, or null because nobody has been asked yet.
  ///
  /// Asked once, the first time the song's audience moves beyond "Only you",
  /// and answerable again from the song's menu. What it decides: a cover
  /// reaches neither public surface — not the Open Mic and not the showcase
  /// — and a cover's text exports carry the structure without the words.
  final SongOrigin? songOrigin;

  /// The key the band says this song is in, or null because the detected one
  /// is right — or because nobody has looked.
  ///
  /// A shared fact and not a reading. Key detection knows major and minor
  /// only, so a Mixolydian song or one that opens on its IV gets named by the
  /// wrong chord, and everything drawn from the key is then wrong with it:
  /// the scale, the capo chart, the spelling of every chord, and the numbers
  /// most of all (Every Musician, Same Song, 17 September 2026). A person's
  /// transpose and capo are theirs; where the 1 is belongs to the song.
  ///
  /// Read through [songKey], never on its own, so nothing can accidentally
  /// draw half a sheet from the detected key and half from this.
  final String? keyOverride;

  /// The key this song is in: what the band said, or what the analysis found.
  ///
  /// [detected] is the analysis's answer — `SongReference.musicalKey` — which
  /// the override stands in front of everywhere a key is read. Null when
  /// neither exists, which is a real outcome on plenty of recordings and
  /// simply means fewer answers.
  String? songKey(String? detected) {
    final said = keyOverride?.trim();
    if (said != null && said.isNotEmpty) return said;
    final found = detected?.trim();
    return found == null || found.isEmpty ? null : found;
  }

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
    SongOrigin? songOrigin,
    Object? keyOverride = _unset,
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
      // No clearing sentinel: an answer can be changed but never unasked.
      songOrigin: songOrigin ?? this.songOrigin,
      // This one does clear. "Use the detected key" is a real answer, and it
      // has to be able to put the song back the way the analysis left it.
      keyOverride: identical(keyOverride, _unset)
          ? this.keyOverride
          : keyOverride as String?,
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
    this.reason = '',
  });

  final String id;
  final String title;
  final String? ownerId;
  final String ownerName;
  final String? ownerAvatarPath;
  final DateTime putUpAt;

  /// Why the feed put this in front of you, in its own words — "Needs a
  /// bass", "You have played together", "Nothing like what you play".
  ///
  /// Shown on the card. An ordering that quietly decides for somebody is one
  /// they can neither trust nor argue with, and the wildcards in particular
  /// read as noise until the screen admits that is what they are.
  final String reason;

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
    this.storagePath = '',
    this.durationMs,
    this.ownerAvatarPath,
    this.heard = 0,
    this.heardByMe = false,
  });

  final String id;
  final String title;
  final String? ownerId;
  final String ownerName;
  final String? ownerAvatarPath;
  final DateTime putUpAt;

  /// People who chose to say they heard it -- a nod, not a play -- and
  /// whether you are one of them.
  final int heard;
  final bool heardByMe;

  /// Where the audio is, or empty when this song has none.
  ///
  /// The reference recording, or failing that the earliest take the room has
  /// heard — decided in one place by private.song_audio, never here. Empty
  /// is a real answer and means the row draws without a play button rather
  /// than with one that does nothing.
  final String storagePath;

  final int? durationMs;

  bool get canPlay => storagePath.isNotEmpty;

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

/// A room you own, as an option in the "invite them" picker.
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
  /// hidden: a room missing from the list is somebody wondering where it
  /// went.
  String? get blockedBecause {
    if (alreadyIn) return 'already in';
    if (alreadyInvited) return 'already invited';
    return null;
  }
}

/// Somebody inviting you into a room of theirs.
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
    this.partsOnIt = const <String>[],
  });

  final String id;
  final String title;
  final DateTime updatedAt;

  /// This person already has an open ask about this song. Shown rather than
  /// hidden — "you asked them this yesterday" is more useful than a song
  /// quietly missing from the list.
  final bool alreadyAsked;

  /// What has been played on it, from shared takes.
  ///
  /// Deliberately not "what it is missing". The app cannot know what a song
  /// needs — need is a musical judgement and the list of things somebody
  /// might want is unbounded. It knows what is on it, and the one step from
  /// there is taken where it can be seen.
  final List<String> partsOnIt;
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
    this.askedById,
    this.part,
    this.note = '',
    this.storagePath,
    this.durationMs,
    this.musicalKey,
    this.bpm,
    this.partsOnIt = const <String>[],
    this.hasSongSheet = false,
    this.terms = AskTerms.play,
  });

  final String id;
  final String projectId;
  final String songTitle;
  final String askedByName;

  /// Who asked.
  ///
  /// Returned by asks_for_me since 0061 and never mapped, which left the
  /// inbox card unable to do anything *about* the person — including the two
  /// things a card showing a stranger's song has to offer.
  final String? askedById;
  final String? part;
  final String note;
  final DateTime createdAt;

  /// The brief.
  ///
  /// An ask used to arrive as a title, a name, a part and a sentence — so the
  /// only honest answer was "let me go and look", and the number of people
  /// who go and look is the number of collaborations this app can have.
  ///
  /// All of it already existed. The app worked out the key, the tempo and the
  /// length when it made the song sheet, and it knows what has been played on
  /// it; the ask was simply never told to carry any of it.
  final String? storagePath;
  final int? durationMs;
  final String? musicalKey;
  final double? bpm;
  final List<String> partsOnIt;
  final bool hasSongSheet;

  /// What answering it means. Settled when the ask was sent, and carried here
  /// so the person deciding reads it before they record rather than after
  /// somebody has used what they played.
  final AskTerms terms;

  String get headline => part == null
      ? '$askedByName asked you to play on $songTitle'
      : '$askedByName asked you to play $part on $songTitle';

  /// What the song is, in the order somebody deciding would want it.
  ///
  /// Null when the app knows nothing, so the card can leave the line out
  /// rather than print an empty row of separators.
  String? get brief {
    final facts = <String>[
      if (durationMs != null && durationMs! > 0) _clock(durationMs!),
      if ((musicalKey ?? '').trim().isNotEmpty) 'in ${musicalKey!.trim()}',
      if (bpm != null && bpm! > 0) '${bpm!.round()} bpm',
      if (hasSongSheet) 'chords and words worked out',
    ];
    return facts.isEmpty ? null : facts.join(' · ');
  }

  static String _clock(int ms) {
    final seconds = (ms / 1000).round();
    final minutes = seconds ~/ 60;
    return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
  }
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
    this.opinionsOpened = false,
    this.terms = AskTerms.play,
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

  /// Whether the person who asked has said they are ready to read opinions.
  ///
  /// Until they have, every opinion on this ask is held from them (Every
  /// Musician, Same Song, 17 September 2026). Once they have, opinions
  /// arrive normally. Nothing here says whether any are waiting: that would
  /// be the badge this slice must not draw. The ask used to carry a count of
  /// what had been said back; it does not any more, because a reply is a
  /// sentence and a sentence is not a tally.
  final bool opinionsOpened;

  /// What answering it means, chosen when the ask was made and fixed there.
  final AskTerms terms;

  /// Whether this ask names what it wants.
  bool get isSpecific => part != null && part!.trim().isNotEmpty;

  /// What to put on a chip, in the words somebody would actually use.
  String get label => isSpecific ? 'needs ${part!.trim()}' : 'open to ideas';

  /// The ask in one line, for the top of its thread.
  String get headline =>
      isSpecific ? 'Asking for ${part!.trim()}' : 'Asking what this needs';

  SongAsk copyWith({bool? closed, bool? opinionsOpened}) => SongAsk(
        id: id,
        projectId: projectId,
        askedBy: askedBy,
        createdAt: createdAt,
        part: part,
        note: note,
        closed: closed ?? this.closed,
        opinionsOpened: opinionsOpened ?? this.opinionsOpened,
        // Not a parameter. Terms are settled when the ask is sent and the
        // database refuses to change them, so nothing in the app should be
        // able to hand back a copy that says something else.
        terms: terms,
      );
}

/// The three ways to answer a song somebody asked you about.
///
/// Every Musician, Same Song, 17 September 2026: feedback without scores.
/// The person answering picks a door before they write, and the door shapes
/// what gets written. [stayed] and [question] arrive the way replies always
/// have. [opinion] is held until the person who asked says they are ready,
/// and is read by them and by its writer, never by the room. There is no
/// number anywhere in this: no rating, no count, no mark that a reply helped.
enum ReplyDoor {
  stayed('stayed', 'What stayed with me', 'What stayed with you?'),
  question('question', 'A question', 'What do you want to know?'),
  opinion('opinion', 'An opinion', 'What do you think?');

  const ReplyDoor(this.wireName, this.label, this.hint);

  /// What `ask_replies.kind` holds.
  final String wireName;

  /// The door's name, on the button and above the line it produced.
  final String label;

  /// What the box says before anything is typed through this door.
  final String hint;

  /// Null for a plain line: every reply from before the doors existed, and
  /// the asker answering back in their own thread.
  static ReplyDoor? fromWireName(String? value) {
    for (final door in values) {
      if (door.wireName == value) return door;
    }
    return null;
  }

  /// The one thing the writer has to know before they send. Null for the
  /// two doors that arrive normally.
  String? get notice => this == ReplyDoor.opinion
      ? "They'll read this when they're ready."
      : null;
}

/// One thing somebody said back on an ask.
///
/// Words only. No reactions, no edits, no replies to replies: the point is
/// that a request can be talked about at all, and the cheapest shape of
/// that is a line with a name on it.
class AskReply {
  const AskReply({
    required this.id,
    required this.askId,
    required this.authorId,
    required this.authorName,
    required this.body,
    required this.createdAt,
    this.door,
  });

  final String id;
  final String askId;
  final String authorId;
  final String authorName;
  final String body;
  final DateTime createdAt;

  /// Which door this came through, or null for a plain line.
  final ReplyDoor? door;
}

/// One line between you and one other person.
///
/// [personId] is the other one, whichever of you wrote it: a thread is a
/// pair, and the app only ever opens it from one side.
class DirectMessage {
  const DirectMessage({
    required this.id,
    required this.personId,
    required this.authorId,
    required this.authorName,
    required this.body,
    required this.createdAt,
  });

  final String id;
  final String personId;
  final String authorId;
  final String authorName;
  final String body;
  final DateTime createdAt;
}

/// What kind of thread: a room the band talks in, or one other person.
enum ThreadKind { room, person }

/// One line on the Messages screen: a thread you are in, what was last
/// said in it, and how much of it you have not seen.
///
/// A room is a thread the moment you are a member of it, said or not;
/// a person is a thread once either of you has written. [lastAt] is
/// null for a room nobody has spoken in yet.
class ThreadSummary {
  const ThreadSummary({
    required this.kind,
    required this.targetId,
    required this.name,
    this.icon,
    this.avatarPath,
    this.memberCount = 2,
    this.lastBody,
    this.lastAuthorId,
    this.lastAuthorName,
    this.lastAt,
    this.unread = 0,
  });

  final ThreadKind kind;

  /// The room, or the other person.
  final String targetId;
  final String name;

  /// The room's icon; null for a person.
  final String? icon;

  /// The person's picture; null for a room.
  final String? avatarPath;
  final int memberCount;
  final String? lastBody;
  final String? lastAuthorId;
  final String? lastAuthorName;
  final DateTime? lastAt;

  /// Lines from other people since you last opened it.
  final int unread;

  ThreadSummary copyWith({int? unread}) => ThreadSummary(
        kind: kind,
        targetId: targetId,
        name: name,
        icon: icon,
        avatarPath: avatarPath,
        memberCount: memberCount,
        lastBody: lastBody,
        lastAuthorId: lastAuthorId,
        lastAuthorName: lastAuthorName,
        lastAt: lastAt,
        unread: unread ?? this.unread,
      );
}

/// A line said in a room, to everybody in it.
class RoomMessage {
  const RoomMessage({
    required this.id,
    required this.roomId,
    required this.authorId,
    required this.authorName,
    required this.body,
    required this.createdAt,
  });

  final String id;
  final String roomId;
  final String authorId;
  final String authorName;
  final String body;
  final DateTime createdAt;
}

/// A note you left: you would like to meet somebody who plays [part].
///
/// The shallowest ask there is, with nothing attached. Lasts a month, then
/// it is gone; [matched] is how many people it has already found you.
class StandingWant {
  const StandingWant({
    required this.id,
    required this.part,
    required this.label,
    required this.expiresAt,
    this.note,
    this.matched = 0,
  });

  final String id;

  /// The stored word, as in `plays`.
  final String part;

  /// The person: "a singer".
  final String label;
  final String? note;
  final DateTime expiresAt;
  final int matched;
}

/// What the app said about a song, and the way to a person under it.
///
/// [askPart] is the part the question was about that the song does not
/// have, or null when the useful next ask is the open one ("what does this
/// need?"). [askLabel] is the seam's own words, already decided.
class SongAnswer {
  const SongAnswer({
    required this.answer,
    required this.askLabel,
    required this.model,
    this.askPart,
  });

  final String answer;
  final String? askPart;
  final String askLabel;

  /// Which model answered, so a quality difference can be traced.
  final String model;
}

/// Who is looking for what you play, as a count. Never names: a want is
/// not a listing.
class WantAround {
  const WantAround({
    required this.part,
    required this.label,
    required this.people,
  });

  final String part;
  final String label;
  final int people;
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
/// How reachable somebody has said they are.
///
/// Set on purpose and lasting for days, which is the timescale a band works
/// on. A live presence dot answers "message them now"; this answers "is it
/// worth asking at all", and it is the half that still says something when
/// nobody happens to be online.
enum Availability { unset, open, busy, away }

Availability availabilityFrom(String? raw) => switch (raw) {
      'open' => Availability.open,
      'busy' => Availability.busy,
      'away' => Availability.away,
      _ => Availability.unset,
    };

/// Somebody you know, and which way round the knowing currently is.
class Connection {
  const Connection({
    required this.personId,
    required this.displayName,
    required this.accepted,
    required this.incoming,
    this.avatarPath,
    this.plays = const <String>[],
    this.availability = Availability.unset,
    this.availabilityNote,
    this.availabilityUntil,
    this.since,
  });

  final String personId;
  final String displayName;
  final String? avatarPath;
  final List<String> plays;

  /// False while somebody has been asked and has not answered.
  final bool accepted;

  /// True when they asked you. Only meaningful while [accepted] is false:
  /// a pair that has agreed is symmetric, but a pending one is either
  /// something you are waiting on or something waiting on you, and those
  /// are different rows with different buttons.
  final bool incoming;

  final Availability availability;
  final String? availabilityNote;
  final DateTime? availabilityUntil;
  final DateTime? since;

  /// What to say about how reachable they are, or null when they have not
  /// said. Never invents a status: "unset" means unknown, not "away".
  String? get availabilityLine {
    if (availability == Availability.unset) return null;
    final note = availabilityNote;
    final head = switch (availability) {
      Availability.open => 'Up for playing',
      Availability.busy => 'Heads down',
      Availability.away => 'Away',
      Availability.unset => '',
    };
    return note == null || note.isEmpty ? head : '$head - $note';
  }
}

/// Somebody found by name, and where the two of you already stand.
class FoundPerson {
  const FoundPerson({
    required this.personId,
    required this.displayName,
    this.avatarPath,
    this.plays = const <String>[],
    this.city,
    this.already = ConnectionStanding.none,
  });

  final String personId;
  final String displayName;
  final String? avatarPath;
  final List<String> plays;

  /// Shown only by somebody who chose to show it.
  final String? city;

  /// What the button should say. Decided by the server rather than by the
  /// client guessing from a list it may not have loaded.
  final ConnectionStanding already;
}

/// Where two people stand: strangers, asked, or connected.
enum ConnectionStanding { none, pending, accepted }

ConnectionStanding standingFrom(String? raw) => switch (raw) {
      'pending' => ConnectionStanding.pending,
      'accepted' => ConnectionStanding.accepted,
      _ => ConnectionStanding.none,
    };

/// Whose meeting code this is (0130): enough to recognise the person in
/// front of you, and where the two of you already stand. Opening a code adds
/// nobody.
class MetPerson {
  const MetPerson({
    required this.personId,
    required this.displayName,
    this.avatarPath,
    this.plays = const <String>[],
    this.standing = ConnectionStanding.none,
    this.askedYou = false,
  });

  final String personId;
  final String displayName;
  final String? avatarPath;
  final List<String> plays;
  final ConnectionStanding standing;

  /// They already asked you -- they scanned your code first -- so adding
  /// them back connects you on the spot.
  final bool askedYou;
}

/// Somebody the app can say a true sentence about, who is not connected yet.
class SuggestedPerson {
  const SuggestedPerson({
    required this.personId,
    required this.displayName,
    required this.because,
    this.avatarPath,
    this.canMessage = false,
  });

  final String personId;
  final String displayName;
  final String? avatarPath;

  /// Why they are here, in words. A fact rather than a score: this app does
  /// not have enough people to guess with, and would not be forgiven for
  /// guessing wrong about who somebody plays with.
  final String because;

  /// Whether a message to them would go: in a room together (0102's
  /// may_tell). Somebody who only played on a song with you is not, yet.
  final bool canMessage;
}

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
    this.bio,
    this.discoverable,
    this.locationVisibility,
    this.soundsLike = const <String>[],
    this.sharedSounds = const <String>[],
    this.isDemo = false,
    this.matchedParts = const <String>[],
    this.heardSongId,
    this.heardTitle,
    this.heardPath = '',
    this.heardDurationMs,
    this.vocalLowMidi,
    this.vocalHighMidi,
    this.vocalRangeSongs = 0,
  });

  final String id;
  final String displayName;
  final String? avatarPath;

  /// What somebody says about themselves, in their own words.
  ///
  /// The only field on a profile that is neither counted by the app nor
  /// picked from a list. Everything else here is a number the app worked out
  /// or a chip somebody tapped; this is the sentence a person would actually
  /// lead with — twenty years of playing, only writes at night, looking for a
  /// band rather than a session. Null is the normal case and not a gap to
  /// apologise for.
  final String? bio;

  /// What they say their music sounds like, in their own words.
  ///
  /// The field that makes "like-minded" mean anything. An instrument does not
  /// distinguish a metal player from a jazz one, and until this existed the
  /// app was matching people on instrument and postcode alone.
  ///
  /// Self-declared, and that is the point: nobody earns a genre, so this can
  /// order a list without ever ranking a person.
  final List<String> soundsLike;

  /// The tags you and they both wrote down. Empty when nothing overlaps, or
  /// when this came from somewhere that does not compute it.
  final List<String> sharedSounds;

  /// Which of the things you asked for this person actually does.
  ///
  /// Empty when nothing was asked. Shown on the card so somebody near the top
  /// of a list can be seen to have earned it, rather than leaving the reader
  /// to work out why the order is the order.
  final List<String> matchedParts;

  /// Something of theirs you can play without leaving the list.
  ///
  /// Deciding whether to work with somebody is done by ear in about ten
  /// seconds, and their card carried everything except the sound. Empty when
  /// they have nothing on the Open Mic.
  final String? heardSongId;
  final String? heardTitle;
  final String heardPath;
  final int? heardDurationMs;

  bool get canBeHeard => heardPath.isNotEmpty;

  /// Seeded for testing, never a person.
  ///
  /// Drawn wherever this account appears. The whole point of having a crowd
  /// to test against is that the machinery gets exercised; the point of
  /// saying so is that nobody — a real user, or a reviewer — is ever left
  /// thinking an invented account is somebody they could work with.
  final bool isDemo;

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

  /// The lowest and highest notes the analyser has heard this person sing,
  /// as MIDI numbers, across the recordings they uploaded — and how many
  /// recordings that is.
  ///
  /// Counted on the server, and only for somebody who says they sing: a
  /// producer who uploads the band's demos does not inherit the singer's
  /// range. Null (and zero) otherwise, and always null on a row from
  /// find_musicians, which does not carry it — a range is a thing to read on
  /// somebody's page, not a column to rank a list by.
  final int? vocalLowMidi;
  final int? vocalHighMidi;
  final int vocalRangeSongs;

  /// "E3 – A4", or null when nothing was counted.
  String? get vocalRangeLabel {
    final low = vocalLowMidi;
    final high = vocalHighMidi;
    if (low == null || high == null) return null;
    return low == high
        ? midiNoteLabel(low)
        : '${midiNoteLabel(low)} – ${midiNoteLabel(high)}';
  }

  /// Whether there is a record behind the claim.
  bool get hasRecord => songsPlayedOn > 0;

  /// The parts they have played most, most first.
  List<MapEntry<String, int>> get topParts {
    final entries = partsRecorded.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.take(4).toList(growable: false);
  }
}

/// One song's place in a set, and what the band does with it there.
///
/// Every Musician, Same Song, 17 September 2026: a set stored titles and an
/// order, and a gigging band needs what to do with each song. Every field
/// here is null until the band says otherwise, and null means "what the song
/// says": the song's own key, the analysis's tempo, one bar of its metre, its
/// sections. See `setSongFacts`, which is where the fallbacks are worked out,
/// so a screen and a printed page cannot disagree about them.
///
/// The key is the set's answer for this occasion. It stands in front of the
/// song's own key ([SongProject.songKey]) on the set and nowhere else: a band
/// that does a song down a tone on Saturday has not changed what key the
/// song is in.
class SetlistSong {
  const SetlistSong({
    required this.projectId,
    this.key,
    this.bpm,
    this.countIn,
    this.form,
    this.ending,
    this.note,
  });

  final String projectId;

  /// The key this set does the song in, in the shape the analyser writes one
  /// ("Bb", "F# minor"), or null for the song's own.
  final String? key;

  /// The tempo this set does the song at, or null for the analysis's.
  final double? bpm;

  /// Who counts it and how, in the band's words, or null for one bar of the
  /// song's own metre.
  final String? countIn;

  /// The shape of the song as this set plays it, or null for its sections.
  final String? form;

  /// How it ends: cold, ritard, tag the chorus. Null says nothing.
  final String? ending;

  /// One line for the stand-in: "straight into the next one".
  final String? note;

  /// Whether the band has said anything about this song here at all.
  bool get isBlank =>
      key == null &&
      bpm == null &&
      countIn == null &&
      form == null &&
      ending == null &&
      note == null;

  /// The same shape 0144 accepts for a song's key and 0157 for a set's: a
  /// root, an optional accidental, optionally which of the two modes.
  static final RegExp keyShape = RegExp(r'^[A-G][#b]?( (major|minor))?$');

  /// What the fields may hold, applied once here so the two repositories
  /// cannot drift: text is trimmed and blank text becomes null (an empty
  /// field means "use what the song says", and 0157 refuses an empty
  /// string); a key has to be one the app can read; a tempo has to be one
  /// the app can count at; nothing is longer than its column.
  ///
  /// Throws [ArgumentError] with a sentence a person can be shown.
  SetlistSong cleaned() {
    String? text(String? value, int limit, String what) {
      final trimmed = value?.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (trimmed == null || trimmed.isEmpty) return null;
      if (trimmed.length > limit) {
        throw ArgumentError('$what has to be $limit characters or fewer.');
      }
      return trimmed;
    }

    final saidKey = key?.trim();
    if (saidKey != null && saidKey.isNotEmpty && !keyShape.hasMatch(saidKey)) {
      throw ArgumentError('That is not a key this app can read.');
    }
    final tempo = bpm;
    if (tempo != null && (tempo < 40 || tempo > 240)) {
      throw ArgumentError('A tempo has to be between 40 and 240.');
    }
    return SetlistSong(
      projectId: projectId,
      key: saidKey == null || saidKey.isEmpty ? null : saidKey,
      bpm: tempo,
      countIn: text(countIn, 80, 'The count-in'),
      form: text(form, 200, 'The form'),
      ending: text(ending, 80, 'The ending'),
      note: text(note, 200, 'The note'),
    );
  }

  /// Every field clears, because "use what the song says" is a real answer
  /// for each of them.
  SetlistSong copyWith({
    Object? key = _unset,
    Object? bpm = _unset,
    Object? countIn = _unset,
    Object? form = _unset,
    Object? ending = _unset,
    Object? note = _unset,
  }) {
    return SetlistSong(
      projectId: projectId,
      key: identical(key, _unset) ? this.key : key as String?,
      bpm: identical(bpm, _unset) ? this.bpm : bpm as double?,
      countIn: identical(countIn, _unset) ? this.countIn : countIn as String?,
      form: identical(form, _unset) ? this.form : form as String?,
      ending: identical(ending, _unset) ? this.ending : ending as String?,
      note: identical(note, _unset) ? this.note : note as String?,
    );
  }
}

class Setlist {
  const Setlist({
    required this.id,
    required this.ownerId,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.songs = const <SetlistSong>[],
  });

  final String id;
  final String ownerId;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// The songs in the order they are played, each with what the band does
  /// with it here.
  final List<SetlistSong> songs;

  /// The order alone, which is all a set used to be and all most callers
  /// want.
  List<String> get projectIds =>
      songs.map((song) => song.projectId).toList(growable: false);

  /// What this set says about one of its songs, or null when the song is not
  /// in it.
  SetlistSong? songFor(String projectId) {
    for (final song in songs) {
      if (song.projectId == projectId) return song;
    }
    return null;
  }

  /// The same set with [projectIds] as its order, keeping what the band has
  /// said about each song that stays and starting fresh for one that is new.
  Setlist withOrder(Iterable<String> projectIds, {DateTime? updatedAt}) {
    return copyWith(
      updatedAt: updatedAt,
      songs: <SetlistSong>[
        for (final projectId in projectIds)
          songFor(projectId) ?? SetlistSong(projectId: projectId),
      ],
    );
  }

  Setlist copyWith({
    String? name,
    DateTime? updatedAt,
    List<SetlistSong>? songs,
  }) {
    return Setlist(
      id: id,
      ownerId: ownerId,
      name: name ?? this.name,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      songs: songs ?? this.songs,
    );
  }
}

/// A room: the container songs live in.
///
/// **Called a Room everywhere in the code and a room everywhere a person
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
/// It also stopped scaling: a room can be a band, a side project, or just
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
  /// Null in a room with one member: there the answer is always "you", and
  /// a column of identical faces is noise rather than information. Null too
  /// for a song whose author is not a member any more, or one loaded by a
  /// path that does not ask for created_by — both better drawn as the plain
  /// note than as a guess.
  ///
  /// Lives here so every surface that lists songs agrees. Home, the room
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

  /// Whether [userId] can say what a song in here is — its key (0144) —
  /// rather than only look at it: the owner and the editors, the same two
  /// roles set_song_key lets through.
  ///
  /// False for anybody not in [members], including an empty id, because the
  /// server refuses them too and a control that is always refused is worse
  /// than no control.
  bool canEditSongs(String userId) {
    if (userId.isEmpty) return false;
    for (final member in members) {
      if (member.userId == userId) {
        return member.role == RoomRole.owner || member.role == RoomRole.editor;
      }
    }
    return false;
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
  /// Somebody asked for a part on a song, or asked this person for one —
  /// migrations 0048 and 0049. The server had been writing these for three
  /// weeks before the app learned the word, and the first one anybody
  /// received took their whole workspace down at load (14 Sep 2026).
  songAsk,
  /// Somebody you are connected to, or in a room with, said something to
  /// you and only you -- migration 0112. The sender is the actor, so the
  /// inbox can open the thread.
  directMessage,
  /// Somebody who plays what you left a note about has turned up on the
  /// Open Mic -- migration 0115. The newcomer is the actor, so the inbox
  /// can open their page.
  wantMatched,
  /// Somebody asked to add you -- usually by scanning your code (0130) --
  /// migration 0132. The asker is the actor.
  connectionRequest,
  /// Somebody you asked added you back, migration 0132. They are the actor.
  connectionAccepted,
  /// Somebody started a call in a room you are in, migration 0134. The room
  /// rides on the notification, so the card opens it -- where Join is.
  callStarted,
  /// Somebody left a note at a moment of a recording of yours, migration
  /// 0141. The song rides on the notification, so the card opens its takes
  /// at the note.
  momentNote,
  /// A type this build has not met. Shown with the title and body the
  /// server wrote, opens nothing, and — the point — never refuses to load
  /// the app. Every type is unknown to some build in the field.
  unfamiliar,
}

/// The server's name for a notification type, as the app's own.
///
/// Never throws. The parser used to, and one row of a type the build did
/// not know made the load of every notification fail together, which the
/// app reports as "we could not open the workspace" — for a notification.
NotificationType notificationTypeFromSql(String value) => switch (value) {
      'invite_received' => NotificationType.inviteReceived,
      'invite_accepted' => NotificationType.inviteAccepted,
      'invite_declined' => NotificationType.inviteDeclined,
      'project_update' => NotificationType.projectUpdate,
      'analysis_ready' => NotificationType.analysisReady,
      'song_ask' => NotificationType.songAsk,
      'direct_message' => NotificationType.directMessage,
      'want_matched' => NotificationType.wantMatched,
      'connection_request' => NotificationType.connectionRequest,
      'connection_accepted' => NotificationType.connectionAccepted,
      'call_started' => NotificationType.callStarted,
      'moment_note' => NotificationType.momentNote,
      _ => NotificationType.unfamiliar,
    };

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
    this.asks = true,
    this.messages = true,
    this.calls = true,
  });

  final bool invites;
  final bool inviteResponses;
  final bool projectUpdates;

  /// Being asked to play on somebody's song.
  ///
  /// The only kind of other people's activity that had no switch, and the one
  /// most likely to arrive often if this app works — the whole design points
  /// at more people asking each other for help.
  final bool asks;

  /// Somebody messaging you, or saying something in one of your rooms. The
  /// message is in Messages either way; this is about being told (0136).
  final bool messages;

  /// Somebody starting a call in one of your rooms (0136).
  final bool calls;

  NotificationPreferences copyWith({
    bool? invites,
    bool? inviteResponses,
    bool? projectUpdates,
    bool? asks,
    bool? messages,
    bool? calls,
  }) {
    return NotificationPreferences(
      invites: invites ?? this.invites,
      inviteResponses: inviteResponses ?? this.inviteResponses,
      projectUpdates: projectUpdates ?? this.projectUpdates,
      asks: asks ?? this.asks,
      messages: messages ?? this.messages,
      calls: calls ?? this.calls,
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

/// Who can hear a song, as one answer.
///
/// A song's audience is decided by four unrelated mechanisms — which room it
/// is in, who was invited to this one song, whether it is on the Open Mic,
/// and which takes have been shared. Nothing in the app ever put those
/// together, so nobody could look at a song and know who could hear it.
///
/// This is the four spaces as a single value: alone, with your band, with
/// somebody you asked, in front of everybody.
class SongAudience {
  const SongAudience({
    required this.reach,
    required this.listeners,
    required this.onOpenMic,
    this.onShowcase = false,
    this.roomName = '',
    this.roomIcon = '',
    this.openMicAt,
  });

  /// The widest thing that is true, never a stored column: memberships change
  /// and a cached answer would go quietly wrong.
  final SongReach reach;

  /// Everybody who can hear it apart from you. Named rather than counted,
  /// because "who" is the question people actually ask.
  final List<SongListener> listeners;

  final bool onOpenMic;

  /// Shown as finished work. Separate from being on the Open Mic — one is
  /// asking for help, the other is saying it is done.
  final bool onShowcase;

  final String roomName;
  final String roomIcon;
  final DateTime? openMicAt;

  /// What to say on the control itself, in as few words as it can be said.
  String get label => switch (reach) {
        SongReach.justYou => 'Only you',
        SongReach.room => roomName.isEmpty ? 'Your room' : roomName,
        SongReach.invited => 'You and ${listeners.length}',
        SongReach.anyone => 'Anyone',
      };

  /// The line under it, which is the part that makes somebody feel safe.
  String get detail => switch (reach) {
        SongReach.justYou => 'Nobody else can hear this yet',
        SongReach.room =>
          '${listeners.length} ${listeners.length == 1 ? 'person' : 'people'} '
              'can hear it',
        SongReach.invited => 'The people you asked can hear it',
        SongReach.anyone => 'On the Open Mic — anybody signed in can listen',
      };
}

enum SongReach { justYou, room, invited, anyone }

/// Somebody who can hear a song.
class SongListener {
  const SongListener({
    required this.id,
    required this.name,
    this.avatarPath,
    this.songOnly = false,
  });

  final String id;
  final String name;
  final String? avatarPath;

  /// True when they were invited to this one song rather than the whole room
  /// — the difference between "in the band" and "helping with this".
  final bool songOnly;
}


/// Something the app worked out about you, offered rather than asked.
///
/// Setting up a profile is a form: tick your instruments, tick your genres,
/// type your city. It reads as a survey because it is one — and most of it is
/// already known. By the time anybody opens that sheet they have recorded
/// takes, and every take carries a part.
///
/// So the app says what it saw. "You have recorded bass on four songs — add
/// it?" is a different feeling from an empty checkbox, and one tap rather
/// than a form.
class Noticed {
  const Noticed({
    required this.kind,
    required this.subject,
    required this.detail,
    required this.amount,
  });

  /// What sort of thing this is: a part they play, a setting working against
  /// them, or a field worth filling.
  final NoticedKind kind;

  /// The part, for [NoticedKind.plays]. Empty otherwise.
  final String subject;

  /// The sentence to show, written by the database because it is the only
  /// thing that knows the count.
  final String detail;

  /// How much of it there is — four songs, two takes. Used to order, so the
  /// strongest evidence is offered first.
  final int amount;
}

enum NoticedKind {
  /// A part they have recorded and never claimed.
  plays,

  /// Their songs are on the Open Mic and they are not findable.
  discoverable,

  /// They have shared music and never said what it sounds like.
  soundsLike,
}


/// One of your songs out on the Open Mic, and what has come back.
///
/// A song went up and nothing ever came back — no count, no signal, no
/// reason to look again. Putting something up felt like dropping it down a
/// well, and the second time was harder than the first.
class OpenMicStatus {
  const OpenMicStatus({
    required this.id,
    required this.title,
    required this.putUpAt,
    this.listeners = 0,
    this.listenersThisWeek = 0,
    this.offers = 0,
    this.askingFor = const <String>[],
    this.storagePath = '',
    this.heard = 0,
  });

  final String id;
  final String title;
  final DateTime putUpAt;

  /// People, not plays. Somebody who played it eleven times on Tuesday is
  /// one person who heard it.
  final int listeners;
  final int listenersThisWeek;

  /// People who chose to say so, which is a different thing from a play.
  final int heard;

  /// Somebody putting their hand up, which is the thing that actually
  /// matters — a listen is interest and an offer is a person.
  final int offers;

  final List<String> askingFor;
  final String storagePath;
}


/// What this account is allowed to do.
///
/// One answer the client and the Edge Function both ask for, so a paywall
/// the client believes in and the server does not cannot happen.
class MyPlan {
  const MyPlan({
    required this.member,
    required this.sheetsThisMonth,
    this.sheetsAllowed,
  });

  final bool member;
  final int sheetsThisMonth;

  /// Null means no ceiling.
  final int? sheetsAllowed;

  int? get sheetsLeft =>
      sheetsAllowed == null ? null : (sheetsAllowed! - sheetsThisMonth).clamp(0, 9999);

  bool get outOfSheets => sheetsLeft != null && sheetsLeft! <= 0;
}


/// A finished song somebody chose to show.
///
/// The Open Mic is where raw ideas ask for help; this is where finished work
/// is played. Hearing what somebody finished is the better introduction — a
/// raw idea says what they are working on, a finished song says what they
/// are capable of.
class ShowcaseSong {
  const ShowcaseSong({
    required this.id,
    required this.title,
    required this.ownerName,
    required this.shownAt,
    this.ownerId,
    this.ownerAvatarPath,
    this.storagePath = '',
    this.durationMs,
    this.musicalKey,
    this.players = const <SongListener>[],
    this.madeHere = false,
    this.metHere = false,
  });

  final String id;
  final String title;
  final String? ownerId;
  final String ownerName;
  final String? ownerAvatarPath;
  final DateTime shownAt;
  final String storagePath;
  final int? durationMs;
  final String? musicalKey;

  /// Everybody with a shared take on it who is not the owner.
  final List<SongListener> players;

  /// More than one person played on it, here.
  final bool madeHere;

  /// Somebody got onto it through an ask or a per-song invitation — two
  /// strangers, one asked, the other said yes. The strong claim, and the
  /// whole argument for this app existing.
  final bool metHere;

  /// What to put on the card, or null when there is nothing true to say.
  String? get together {
    if (!madeHere) return null;
    final names = players.map((p) => p.name).toList(growable: false);
    final who = switch (names.length) {
      0 => null,
      1 => names.first,
      2 => '${names[0]} and ${names[1]}',
      _ => '${names[0]}, ${names[1]} and ${names.length - 2} more',
    };
    if (who == null) return metHere ? 'Made here' : null;
    return metHere ? 'Met here · with $who' : 'With $who';
  }
}


/// A question you asked, and whatever came back.
///
/// The help screen could send a question and never show it again — so
/// somebody who asked something on Tuesday had no way to find out whether
/// anybody had answered, short of an email arriving.
class HelpRequest {
  const HelpRequest({
    required this.id,
    required this.question,
    required this.status,
    required this.askedAt,
    this.notes = '',
    this.answeredAt,
  });

  final String id;
  final String question;
  final String status;
  final DateTime askedAt;

  /// What was said back, appended over time rather than replaced.
  final String notes;
  final DateTime? answeredAt;

  bool get answered => status == 'answered' && notes.trim().isNotEmpty;
}
