import 'package:flutter/foundation.dart';

/// What a followed session leaves behind, as stored (migration 0128).
///
/// Follow me moves a student's song with the teacher's for an hour. When it
/// ends, this is what is kept on the follower's own account: the song, who
/// led, the parts that were worked on and at what speed, and the note the
/// leader left on the way out. Read by nobody else. The seconds exist only
/// to put the parts in order; no screen shows them.
///
/// The rules for building one live beside the other practice rules, in
/// features/workspace/practice_marks.dart.

/// One part of the song that was worked on, and how fast.
@immutable
class PracticePart {
  const PracticePart({
    required this.label,
    required this.rate,
    required this.seconds,
    this.startMs,
    this.endMs,
  });

  /// Null for the whole song.
  final int? startMs;
  final int? endMs;

  /// As the chips in Perform say it: "Chorus 2", or "The whole song".
  final String label;
  final double rate;
  final int seconds;

  bool get isLoop => startMs != null && endMs != null;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'start': startMs,
        'end': endMs,
        'label': label,
        'rate': rate,
        'seconds': seconds,
      };

  /// Null for anything that does not read as a part, so one odd entry does
  /// not lose the rest of the mark.
  static PracticePart? fromJson(Object? json) {
    if (json is! Map) return null;
    final label = json['label'];
    final rate = json['rate'];
    if (label is! String || label.trim().isEmpty || rate is! num || rate <= 0) {
      return null;
    }
    final start = json['start'];
    final end = json['end'];
    final seconds = json['seconds'];
    final loop = start is num && end is num && end > start;
    return PracticePart(
      label: label,
      rate: rate.toDouble(),
      seconds: seconds is num ? seconds.round() : 0,
      startMs: loop ? start.round() : null,
      endMs: loop ? end.round() : null,
    );
  }
}

/// A followed session, kept.
@immutable
class PracticeMark {
  const PracticeMark({
    required this.id,
    required this.projectId,
    required this.ledByName,
    required this.parts,
    required this.updatedAt,
    this.ledBy,
    this.note,
  });

  /// Named by the phone before it is saved, so saving the same session
  /// again updates it rather than adding a second.
  final String id;
  final String projectId;
  final String? ledBy;
  final String ledByName;
  final String? note;

  /// Most worked on first.
  final List<PracticePart> parts;
  final DateTime updatedAt;

  /// The part Practise opens on, when there is one.
  PracticePart? get lead => parts.isEmpty ? null : parts.first;
}
