import 'package:flutter/foundation.dart';

/// Words about one moment of a recording (migration 0141).
///
/// Every Musician, Same Song, 17 September 2026: the thing anybody actually
/// says about a recording is "you rushed into the turnaround" — and until now
/// a comment could only attach to a lyric line, so there was nowhere to say
/// *where*. A teacher answering a student, a bandmate saying where the bass
/// drops out, and somebody marking their own second verse are one object: a
/// moment, and words about it.
@immutable
class MomentNote {
  const MomentNote({
    required this.id,
    required this.projectId,
    required this.atMs,
    required this.body,
    required this.authorId,
    required this.createdAt,
    this.layerId,
    this.endMs,
    this.authorName,
    this.onSharedTake = true,
    this.voicePath,
  });

  final String id;
  final String projectId;

  /// The take this is about, or null for the song's own recording — the
  /// reference the chords and words came from, which is not a take and shows
  /// as the first lane on the Takes screen.
  final String? layerId;

  final int atMs;

  /// The far end, when the note is about a passage rather than an instant.
  final int? endMs;

  final String body;
  final String authorId;

  /// Who left it, for a note somebody else left on your playing. Null when
  /// they have no display name, which the list reads as "Somebody".
  final String? authorName;

  /// Whether the recording had been shared when these words were typed
  /// (0141's `on_shared_take`, frozen by the database, never sent by the app).
  ///
  /// False is a note somebody pinned on a take only they could hear, and it
  /// stays theirs alone after they share the take — otherwise pressing Share
  /// would hand the room every private note on that recording at once. The
  /// list says "only you" on one, so nobody writes to the band on a row that
  /// only they will ever read.
  final bool onSharedTake;

  /// Where what was said is kept, for a note that was spoken rather than
  /// typed (0152). Null for a typed note, whose [body] is the whole of it.
  ///
  /// A spoken note is the same object as a typed one — a moment, and
  /// something about it — because a teacher with a guitar in their hands
  /// would rather say it (Every Musician, Same Song, 17 September 2026).
  final String? voicePath;

  final DateTime createdAt;

  bool get isSpoken => voicePath != null;

  /// As long as a spoken note may run. A minute is room to say "there, and
  /// again at the turnaround" and play the bar; longer than that is a
  /// lesson, not a note. Nothing shows how long one is, only that it is
  /// there — the plan keeps durations off every screen.
  static const Duration spokenLimit = Duration(seconds: 60);

  /// How far before the moment playback starts.
  ///
  /// A note about a breath is unhearable from the breath: you have to arrive
  /// at it. Three seconds is what the plan specifies — a note at 1:48 plays
  /// from 1:45.
  static const int leadInMs = 3000;

  /// How long a note with no far end runs before the loop turns round.
  ///
  /// Eight seconds, so 1:48 loops 1:45 to 1:56 as the plan describes. Long
  /// enough to hear the phrase the note is about and short enough that the
  /// loop is the moment rather than the song.
  static const int momentMs = 8000;

  /// As long as the column allows (0141). Long enough for a paragraph about
  /// one bar, short enough that a note is not an essay.
  static const int bodyLimit = 1000;

  /// Where playing starts when somebody taps this note.
  int get playFromMs => atMs - leadInMs < 0 ? 0 : atMs - leadInMs;

  /// Where the loop turns round: the end of the range, or the end of the
  /// moment.
  int get loopEndMs => endMs ?? atMs + momentMs;

  bool get isRange => endMs != null;

  /// The moment as a transport says it: 1:48.
  String get clock => clockOf(atMs);

  static String clockOf(int ms) {
    final seconds = ms ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}

/// Which note a notification was about, as much of it as the row can carry.
///
/// `public.notifications` has columns for the person, the type, a title, a
/// body, a room, a song, an invitation and an actor — and nothing for the
/// thing the notification is about. So a note's id cannot travel on it, and
/// the address we have is who left the note and the first 200 characters of
/// what they said, which is already in the body of the card somebody tapped.
///
/// That is enough to land on the right one: two people leaving notes on the
/// same song in the same minute still wrote different words. A nullable
/// `notifications.subject_id` is the honest fix and belongs to whichever
/// slice next touches that table.
@immutable
class NoteToOpen {
  const NoteToOpen({this.authorId, this.bodyStart});

  /// The notification's actor — whoever pinned the note.
  final String? authorId;

  /// The note's words, as far as the notification carried them.
  final String? bodyStart;

  /// The note this points at, out of everything on the song.
  ///
  /// Narrowing, never empty-handed: the person tapped a card saying somebody
  /// left them a note, so landing on the closest match beats landing nowhere.
  /// [exceptAuthor] is the person reading, who is never the one being told.
  MomentNote? findIn(Iterable<MomentNote> notes, {String? exceptAuthor}) {
    final others = <MomentNote>[
      for (final note in notes)
        if (note.authorId != exceptAuthor) note,
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (others.isEmpty) return null;

    final words = bodyStart?.trim() ?? '';
    MomentNote? bySamePerson;
    for (final note in others) {
      if (authorId != null && note.authorId != authorId) continue;
      if (words.isNotEmpty && note.body.trim().startsWith(words)) return note;
      bySamePerson ??= note;
    }
    return bySamePerson ?? others.first;
  }
}
