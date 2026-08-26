/// Something a bandmate did, in the words a person would use.
///
/// Read across every song at once, which is the thing the app could not do:
/// project_events has carried a per-song stream — messages alongside edits,
/// analyses and recordings, each with an actor — since migration 0032, and
/// the only way to see any of it was to already be inside the song it
/// happened in. So a lead added to a song you were not thinking about
/// reached you as a generic notification, or not at all.
class ActivityItem {
  const ActivityItem({
    required this.id,
    required this.projectId,
    required this.projectTitle,
    required this.kind,
    required this.at,
    this.actorName,
    this.actorId,
    this.actorAvatarPath,
    this.body = '',
  });

  final String id;
  final String projectId;
  final String projectTitle;
  final ActivityKind kind;
  final DateTime at;

  /// Null for a system event with nobody behind it, and for somebody whose
  /// account has been deleted — their words stay, which is migration 0032's
  /// decision and not this one's to revisit.
  final String? actorName;
  final String? actorId;
  final String? actorAvatarPath;

  /// What was said, for a message. Empty for everything else.
  final String body;

  /// The whole event as one line, without the song's name — the song is drawn
  /// separately so it can be emphasised.
  ///
  /// A message shows what was actually said. "Dylan said something" is worse
  /// than useless: it makes a person open the song to find out, which is the
  /// exact cost this screen exists to remove.
  String get sentence {
    final who = actorName?.trim();
    final name = (who == null || who.isEmpty) ? 'Somebody' : who;
    return switch (kind) {
      ActivityKind.message => body.trim().isEmpty ? '$name said something' : '$name: ${body.trim()}',
      ActivityKind.edited => '$name changed the words',
      ActivityKind.analyzed => '$name analyzed it',
      ActivityKind.recording => '$name added a recording',
      ActivityKind.joined => '$name joined',
    };
  }
}

enum ActivityKind {
  message,
  edited,
  analyzed,
  recording,
  joined;

  static ActivityKind parse(String? value) => switch (value) {
        'message' => ActivityKind.message,
        'edited' => ActivityKind.edited,
        'analyzed' => ActivityKind.analyzed,
        'recording' => ActivityKind.recording,
        'joined' => ActivityKind.joined,
        // A kind added to the database later still has to render as
        // something rather than crash a screen that only wants to list it.
        _ => ActivityKind.edited,
      };
}

/// How long ago, at the resolution a person cares about.
///
/// "2h" not "2 hours 14 minutes ago". Nobody reading a band's activity needs
/// the minutes, and the precision makes the line harder to scan.
String shortAgo(DateTime at, {DateTime? now}) {
  final elapsed = (now ?? DateTime.now()).difference(at);
  if (elapsed.inSeconds < 60) return 'now';
  if (elapsed.inMinutes < 60) return '${elapsed.inMinutes}m';
  if (elapsed.inHours < 24) return '${elapsed.inHours}h';
  if (elapsed.inDays < 7) return '${elapsed.inDays}d';
  return '${(elapsed.inDays / 7).floor()}w';
}
