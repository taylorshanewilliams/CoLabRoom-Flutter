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

  final DateTime createdAt;

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
