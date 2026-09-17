import 'package:flutter/foundation.dart';

/// A teacher's standing link (migration 0129): one QR code on a studio
/// wall, and a room of their own with the teacher for everybody who opens
/// it.
@immutable
class LessonLink {
  const LessonLink({
    required this.id,
    required this.code,
    required this.title,
    required this.createdAt,
    this.students = 0,
  });

  final String id;

  /// Twelve hex characters; see lessonCodeSaid for how a person reads it.
  final String code;

  /// What they teach, in their words: "Guitar lessons".
  final String title;
  final DateTime createdAt;

  /// How many people have joined through it.
  final int students;
}

/// The server asking for a birth month before it will open a lesson link, or
/// make one (migration 0139).
///
/// Every Musician, Same Song, 17 September 2026: adult students first, and
/// lesson links for people 18 and over until there is a guardian step -- the
/// rule calls have had since 0134. This one is not a no: the account has
/// simply never said when it was born, and the answer decides.
class LessonNeedsABirthMonth implements Exception {
  const LessonNeedsABirthMonth();

  @override
  String toString() => 'Your birth month first.';
}

/// How that refusal is known from the others the server can raise. A hint
/// rather than the sentence, so the sentence can be reworded without the app
/// stopping asking.
const String lessonBirthMonthHint = 'lesson_birth_month';

/// What somebody under 18 is told, in the server's own words (0139). Here so
/// that the preview repository turns nobody away in words of its own.
const String lessonLinksAreForAdults = 'Lesson links are for people 18 and over for now.';

/// What a teacher is told, on the screen where the link is made and shared:
/// the same fact, said to the person handing the code out rather than to
/// somebody being turned away.
const String lessonLinksAreForStudents18AndOver = 'Lesson links are for students 18 and over for now.';

/// And an account that answered under 13: one sentence with no age in it, as
/// 0138 settled on for calls, because the FTC's COPPA FAQ (D.7, H.3) warns
/// against naming the age that would have let somebody in.
const String lessonLinksClosedOnThisAccount = 'Lesson links are not available on this account.';
