import 'package:flutter/foundation.dart';

/// One take a student has sent their teacher (migration 0151).
///
/// Every Musician, Same Song, 17 September 2026, slice 22: the teacher's
/// listening desk. A hand-in has worked since 0057 and 0129 — a take is
/// private until its player shares it, and a lesson room holds two people —
/// so this is not a new kind of object, only the first time they have been
/// readable together.
///
/// There is no date on it, because the server sends none and a screen cannot
/// print what it does not have; no duration, no count of anything, and
/// nowhere to put a mark. The plan forbids all of those, and the way to keep
/// forbidding them is to have nowhere to put one. [startMs] and [offsetMs]
/// are not an exception: they are a place in the song, not a time of day.
@immutable
class SentTake {
  const SentTake({
    required this.takeId,
    required this.projectId,
    required this.songTitle,
    required this.studentId,
    required this.studentName,
    required this.storagePath,
    this.startMs = 0,
    this.offsetMs = 0,
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

  /// Where on the song this take begins (0045). Zero for a take played from
  /// the top, which is most of them; 90000 for one punched in at 1:30.
  final int startMs;

  /// The latency trim: how much of the front of the recording is thrown
  /// away, because a phone records a moment behind what it plays (0038).
  final int offsetMs;

  /// The song's clock, from the take file's clock.
  ///
  /// The desk plays the take's own file, so its playhead counts from the
  /// first sample of the recording. A moment note counts from the top of the
  /// song: `moment_notes.at_ms` is what the Takes screen draws its marks
  /// against and what it loops the mix around (0141), and what the student
  /// will tap. Multitrack.mix lays a take down at exactly this offset, so
  /// this is the same arithmetic the mix does, read the other way.
  ///
  /// Without it, a note pinned five seconds into a take that was punched in
  /// at the last chorus would be filed five seconds into the song, and the
  /// student would open it on a bar where they are not playing.
  int songMsFor(int filePositionMs) {
    final into = filePositionMs - offsetMs;
    return startMs + (into < 0 ? 0 : into);
  }
}
