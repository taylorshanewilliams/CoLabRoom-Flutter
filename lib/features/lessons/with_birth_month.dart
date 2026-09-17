import 'package:flutter/widgets.dart';

import '../../data/music_repository.dart';
import '../../domain/lesson_link.dart';
import '../calls/birth_month_sheet.dart';

/// Somebody closed the birth month question instead of answering it. Nothing
/// happened, and there is nothing to tell them about what they just did.
class NothingSaidAboutAge implements Exception {
  const NothingSaidAboutAge();

  @override
  String toString() => 'No birth month was given.';
}

/// Runs [action], and if the server wants a birth month before it will open a
/// lesson link or make one (0139), asks for it and runs [action] once more.
///
/// Every Musician, Same Song, 17 September 2026: adult students first, and
/// lesson links for people 18 and over until there is a guardian step. The
/// question is the one calls have asked since 0134 and it saves the same
/// answer, so nobody says when they were born twice.
///
/// What the answer means is the server's to say, so the second try goes to it
/// rather than being judged here: somebody under 18 is turned away in the
/// server's own sentence, which the screens already show plainly. Throws
/// [NothingSaidAboutAge] if the question was closed without an answer.
Future<T> withBirthMonth<T>(
  Future<T> Function() action, {
  required BuildContext context,
  required MusicRepository repository,
}) async {
  try {
    return await action();
  } on LessonNeedsABirthMonth {
    if (!context.mounted) throw const NothingSaidAboutAge();
    final said = await askBirthMonth(
      context,
      repository,
      heading: 'One question first',
      why: 'Which month and year were you born? $lessonLinksAreForAdults '
          'Nobody else sees this, and you only say it once.',
    );
    if (said == null) throw const NothingSaidAboutAge();
    return action();
  }
}
