import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';

/// Who hears a take when it stops being private, and what the app calls that.
///
/// Every Musician, Same Song, 17 September 2026: a lesson room is the teacher
/// and one student and nobody else (0129), and a take is private until it is
/// shared (0057), so handing work in to a teacher already works by
/// construction — the app simply never said so. Sharing into a band room is
/// an announcement to four people; sharing into a lesson is sending something
/// to one, and a student deciding whether to press it needs to know which of
/// those is about to happen.
///
/// Kept out of the screen so the words can be read in a test. The wording is
/// the whole feature here, and wording that only a phone can check is wording
/// that drifts.

/// The teacher to send this take to, or null when there is no such person.
///
/// Null for every band room. Null, too, for the teacher themselves — the
/// owner of a lesson room is the teacher, and "Send to yourself" is nonsense
/// — so a teacher recording a demonstration in a lesson room shares it the
/// ordinary way.
///
/// The name comes from the room's own membership rather than from a second
/// lookup, because there is then no second copy of a teacher's name to fall
/// out of step with the first.
String? teacherToSendTo({
  required bool lessonRoom,
  required MusicRoom? room,
  required String? me,
}) {
  if (!lessonRoom || room == null) return null;
  for (final member in room.members) {
    if (member.role != RoomRole.owner) continue;
    if (member.userId == me) return null;
    final name = member.displayName.trim();
    // A lesson room always names its teacher (join_lesson_link falls back to
    // "Your teacher"), but a room read back without members would otherwise
    // put an empty gap in the middle of a sentence.
    return name.isEmpty ? 'your teacher' : name;
  }
  return null;
}

/// What the button on the lane says. "Share" in a band room.
String shareLabelFor(String? teacher) =>
    teacher == null ? 'Share' : 'Send to $teacher';

/// Asks once, before anybody else can hear a take.
///
/// Confirmed because it is the one action on the takes screen that other
/// people find out about. Everything else — recording again, muting,
/// adjusting, deleting — happens in private, and an action that crosses that
/// line should ask rather than surprise somebody who mis-tapped while
/// scrolling.
///
/// Both answers promise the same thing about taking it back, because
/// unshare_layer (0057) is real in a lesson room as well as a band one.
Future<bool> confirmSharing(BuildContext context, {String? teacher}) async {
  final said = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: AppColors.raised,
      title: Text(
        teacher == null ? 'Let the room hear this?' : 'Send to $teacher?',
      ),
      content: Text(
        teacher == null
            ? 'Everybody in the room gets told, and it plays for them from now '
                'on. You can take it back afterwards.'
            : 'Only $teacher will hear this. You can take it back afterwards.',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Not yet'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(teacher == null ? 'Share it' : 'Send it'),
        ),
      ],
    ),
  );
  return said == true;
}
