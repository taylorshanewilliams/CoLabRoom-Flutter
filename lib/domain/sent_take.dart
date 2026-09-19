import 'package:flutter/foundation.dart';

/// One take a student has sent their teacher (migration 0151).
///
/// Every Musician, Same Song, 17 September 2026, slice 22: the teacher's
/// listening desk. A hand-in has worked since 0057 and 0129 — a take is
/// private until its player shares it, and a lesson room holds two people —
/// so this is not a new kind of object, only the first time they have been
/// readable together.
///
/// Deliberately six fields and no seventh. There is no date on it, because
/// the server sends none and a screen cannot print what it does not have;
/// no duration, no count of anything, and nowhere to put a mark. The plan
/// forbids all of those, and the way to keep forbidding them is to have
/// nowhere to put one.
@immutable
class SentTake {
  const SentTake({
    required this.takeId,
    required this.projectId,
    required this.songTitle,
    required this.studentId,
    required this.studentName,
    required this.storagePath,
  });

  /// The take's row in `song_layers`, which is also what a note pins to.
  final String takeId;

  final String projectId;
  final String songTitle;

  final String studentId;

  /// What the lesson room calls them, which is the name their teacher reads
  /// everywhere else in the app.
  final String studentName;

  /// Where the audio is. Signing it is where the bucket's own policies
  /// apply, so a path that will not sign simply does not play.
  final String storagePath;
}
