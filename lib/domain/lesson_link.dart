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
