import 'package:flutter/foundation.dart';

import 'practice_mark.dart';

/// What to practise on a song a teacher sent, as stored (migration 0150).
///
/// Every Musician, Same Song, 17 September 2026, slice 20: the song arriving
/// in a student's lesson room (0149) is half an assignment, and this is the
/// other half. Which passage, how fast, what the teacher will be listening
/// for, and when by, in the teacher's own words.
///
/// Read by the two people it is between and nobody else. There is nothing on
/// it that counts anything and there never will be: no score, no tick, and
/// nothing that records whether the student opened it. When it is due is a
/// phrase somebody typed ("before Thursday"), never a date, so nothing can be
/// counted down to and nothing can be late.
///
/// The words for it, and the sheet a teacher fills in, live in
/// features/lessons/what_to_practise.dart.

/// How many things to listen for a brief holds, at most. The server keeps
/// the first of them and drops the rest (0150).
const int briefPhrasesKept = 5;

/// The longest a phrase, and the words for when it is due, may be.
const int briefPhraseLength = 80;
const int briefDueLength = 40;

/// What a teacher decided, before it is sent.
@immutable
class BriefToSend {
  const BriefToSend({
    required this.passage,
    required this.rate,
    this.startMs,
    this.endMs,
    this.listeningFor = const <String>[],
    this.dueWords,
  });

  /// As Perform names it: "Bars 1–16", "Chorus 2", "The whole song".
  final String passage;

  /// Null for the whole song.
  final int? startMs;
  final int? endMs;
  final double rate;

  /// A few short phrases, in the order the teacher said them.
  final List<String> listeningFor;

  /// "before Thursday", or null when nothing was said about when.
  final String? dueWords;
}

/// A brief on a song, as the server has it.
@immutable
class SongBrief {
  const SongBrief({
    required this.id,
    required this.projectId,
    required this.teacherId,
    required this.studentId,
    required this.teacherName,
    required this.passage,
    required this.rate,
    required this.setAt,
    this.startMs,
    this.endMs,
    this.listeningFor = const <String>[],
    this.dueWords,
  });

  /// New every time the teacher says what to practise, so a card somebody
  /// closed comes back for this week's brief and stays closed for last
  /// week's.
  final String id;
  final String projectId;
  final String teacherId;
  final String studentId;
  final String teacherName;
  final String passage;
  final int? startMs;
  final int? endMs;
  final double rate;
  final List<String> listeningFor;
  final String? dueWords;

  /// Puts several cards in order and is shown nowhere: a card that said how
  /// long ago it was asked would be a countdown read backwards.
  final DateTime setAt;

  /// The passage and the speed, in the shape Perform opens on. No seconds:
  /// nothing was played, and nothing about a brief is ever timed.
  PracticePart get part => PracticePart(
        label: passage,
        rate: rate,
        seconds: 0,
        startMs: startMs,
        endMs: endMs,
      );
}
