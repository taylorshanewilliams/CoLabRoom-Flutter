import 'package:flutter/foundation.dart';

import 'music_models.dart';

/// A teacher's standing link (migration 0129): one QR code on a studio
/// wall, and a room of their own with the teacher for everybody who opens
/// it.
///
/// Since 0148 a teacher keeps several, each named for what it opens
/// ("Tuesday beginners", "Jazz studio"), and one can be a class: everybody
/// who opens it also lands in one room with the whole class, to listen.
@immutable
class LessonLink {
  const LessonLink({
    required this.id,
    required this.code,
    required this.title,
    required this.createdAt,
    this.students = 0,
    this.classRoomId,
    this.classRoomName,
  });

  final String id;

  /// Twelve hex characters; see lessonCodeSaid for how a person reads it.
  final String code;

  /// What they teach, in their words: "Guitar lessons".
  final String title;
  final DateTime createdAt;

  /// How many people have joined through it. The app says only whether
  /// anybody has (Every Musician, Same Song, 17 September 2026: no counts
  /// anywhere); the number is the server's.
  final int students;

  /// The room the whole class listens in, when this link is a class (0148);
  /// null for a link that opens only a room of their own with the teacher.
  final String? classRoomId;

  /// That room's name, which is the link's title unless the teacher already
  /// had a room called that ("Jazz studio 2").
  final String? classRoomName;

  bool get isClass => classRoomId != null;
}

/// What opening a lesson link gave you: your own room with the teacher
/// (0129), and the class room this scan put you in, when the link is a class
/// and you were not in that room already (0148). A null [room] means the
/// link opened but the library has not shown the room yet.
@immutable
class LessonJoined {
  const LessonJoined({required this.room, this.classRoom});

  final MusicRoom? room;
  final MusicRoom? classRoom;

  /// What to tell the person. The class room is said whenever this scan put
  /// them in it: they opened a link, not a room with other people in it, and
  /// nobody is put anywhere without being told (the rule since 0129). With
  /// [sayWhere], where the rooms are, for a screen that does not open one.
  String sentence({bool sayWhere = false}) {
    final own = room;
    final together = classRoom;
    if (own == null) return 'Your lesson room is ready. It is under Your music.';
    if (together == null) {
      return 'Your lesson room is ready: ${own.name}.${sayWhere ? ' It is under Your music.' : ''}';
    }
    return 'Your lesson room is ready: ${own.name}. You are also in ${together.name} '
        'with the whole class, to listen.${sayWhere ? ' Both are under Your music.' : ''}';
  }
}

/// How many lesson links a teacher can keep open at once (0148): enough for
/// a timetable, few enough to still say which poster is which.
const int lessonLinksOpenAtOnce = 8;

/// What a teacher is told at the ninth, in the server's own words. Says what
/// to do rather than how many there are.
const String lessonLinksAreCapped = 'Eight lesson links are open. Turn one off to make another.';

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
