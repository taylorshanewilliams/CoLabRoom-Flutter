import 'dart:math' as math;

import '../../domain/practice_mark.dart';
import '../../services/follow_me.dart';
import 'practice_rules.dart';

/// Building what a practice session leaves behind (see domain/practice_mark).
///
/// The lesson is one hour of a student's week and the practising is the
/// other hundred and sixty-seven. So when following ends, the parts that
/// were worked on and the speed they were worked at are kept, and Home
/// offers them back with one verb: Practise. A session with nobody leading
/// leaves the same thing, with the person as their own leader — most of that
/// hundred and sixty-seven has nobody else in it.

/// How long a part has to have played before it counts as worked on.
///
/// Twenty seconds is a chorus once through at three-quarter speed. Less than
/// that is somebody passing through on the way to something else.
const int practiceThresholdSeconds = 20;

/// The longest gap between two words from the leader that is counted as
/// playing. The leader says where the song is every two seconds while it
/// plays; a longer silence is a lost connection, not practice.
const int practiceGapCapMs = 6000;

/// The parts kept, at most.
const int practicePartsKept = 3;

/// "Chorus 2 at ¾", or just "Chorus 2" at full speed.
String practiceSaid(PracticePart part) =>
    part.rate == 1 ? part.label : '${part.label} at ${rateLabel(part.rate)}';

/// What was worked on, in a line: "Chorus 2 at ¾", "Chorus 2 at ¾ and
/// Verse 1", "Chorus 2 at ¾ and 2 more". Null when all that was kept is a
/// note.
String? practiceWorked(PracticeMark mark) {
  final parts = mark.parts;
  if (parts.isEmpty) return null;
  if (parts.length == 1) return practiceSaid(parts.first);
  if (parts.length == 2) return '${practiceSaid(parts[0])} and ${practiceSaid(parts[1])}';
  return '${practiceSaid(parts[0])} and ${parts.length - 1} more';
}

/// Whether a session left anything worth a card: something practised, or
/// something said.
bool worthKeeping(List<PracticePart> parts, String? note) =>
    parts.isNotEmpty || (note ?? '').trim().isNotEmpty;

/// Whether a mark is this person's own practice rather than a lesson they
/// followed.
///
/// A lesson is not the only practice there is: somebody who puts Chorus 2 on
/// repeat on a Tuesday with nobody waiting on them has practised too, and a
/// solo session keeps itself with the person as its own leader (Every
/// Musician, Same Song, 17 September 2026). So the two tell themselves apart
/// after the round trip through the server, without a column that says which
/// is which.
bool isYourOwnPractice(PracticeMark mark, {required String me}) =>
    me.isNotEmpty && mark.ledBy == me;

/// What the card says above the song's name.
///
/// Your own practice says so rather than saying your own name back to you.
/// Neither wording says when, and there is nothing here to say it with: a
/// card that read "three days ago" would turn a record of practising into a
/// record of not practising.
String practiceFrom(PracticeMark mark, {required String me}) =>
    isYourOwnPractice(mark, me: me) ? 'Your practice' : 'From ${mark.ledByName}';

/// The name a solo session on this song keeps its mark under: the one this
/// person's own practice on it already has, or a new one.
///
/// 0128 names marks on the phone so that saving again updates the same row
/// rather than adding another. A followed lesson is a rare enough thing that
/// a row a session was never a problem; practising alone is meant to be a
/// Tuesday habit, and a row a visit would fill a person's fortnight with one
/// song and push everything else — including a teacher's note — off Home,
/// which reads back only the twenty newest. So your own practice on a song is
/// one mark, brought up to date (Every Musician, Same Song, 17 September
/// 2026). A lesson's mark is never the one returned: it belongs to whoever
/// led it.
String ownPracticeMarkId(
  Iterable<PracticeMark> kept, {
  required String projectId,
  required String me,
}) {
  for (final mark in kept) {
    if (mark.projectId == projectId && isYourOwnPractice(mark, me: me)) return mark.id;
  }
  return newPracticeMarkId();
}

/// Adds up, while following, how long the song played in each part at each
/// speed.
///
/// Fed every state the leader sends. The time between one state and the
/// next is credited to the first -- that is what was playing in between --
/// when it was playing with the song as the clock. Only a part on repeat or
/// a slower speed is practice: a band running a song through at full speed
/// is rehearsing, and keeps nothing.
class PracticeLog {
  final Map<String, _Span> _spans = <String, _Span>{};
  FollowState? _last;
  int? _lastAt;

  void heard(FollowState state, int atMs) {
    _credit(atMs);
    _last = state;
    _lastAt = atMs;
  }

  /// Following stopped: whatever was playing stops counting now.
  void pause(int atMs) {
    _credit(atMs);
    _last = null;
    _lastAt = null;
  }

  void _credit(int atMs) {
    final last = _last;
    final lastAt = _lastAt;
    if (last == null || lastAt == null || !last.playing || !last.synced) return;
    final span = math.min(math.max(0, atMs - lastAt), practiceGapCapMs);
    if (span == 0) return;
    final start = last.looping ? last.loopStartMs : null;
    final end = last.looping ? last.loopEndMs : null;
    final key = '$start:$end:${last.rate}';
    _spans[key] = _Span(
      startMs: start,
      endMs: end,
      rate: last.rate,
      ms: (_spans[key]?.ms ?? 0) + span,
    );
  }

  /// The parts worth keeping, most worked on first, named by [labelFor]
  /// (a null start and end is the whole song).
  List<PracticePart> parts(String Function(int? startMs, int? endMs) labelFor) {
    final kept = _spans.values
        .where((span) =>
            span.ms >= practiceThresholdSeconds * 1000 &&
            (span.startMs != null || span.rate < 1))
        .toList()
      ..sort((a, b) => b.ms.compareTo(a.ms));
    return <PracticePart>[
      for (final span in kept.take(practicePartsKept))
        PracticePart(
          startMs: span.startMs,
          endMs: span.endMs,
          label: labelFor(span.startMs, span.endMs),
          rate: span.rate,
          seconds: span.ms ~/ 1000,
        ),
    ];
  }
}

class _Span {
  const _Span({required this.startMs, required this.endMs, required this.rate, required this.ms});

  final int? startMs;
  final int? endMs;
  final double rate;
  final int ms;
}

/// A version 4 UUID, made on the phone so a mark can be named before it is
/// saved.
String newPracticeMarkId([math.Random? random]) {
  final source = random ?? math.Random.secure();
  final bytes = List<int>.generate(16, (_) => source.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}
