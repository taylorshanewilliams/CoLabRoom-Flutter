import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../domain/practice_mark.dart';
import '../../domain/song_analysis_models.dart';
import '../workspace/musician_sheet_logic.dart' show buildMusicianSheetLines;
import '../workspace/practice_marks.dart';
import '../workspace/practice_rules.dart';

/// A teacher leaving a student something to practise, without a live session
/// (migration 0143).
///
/// Every Musician, Same Song, 17 September 2026: the lesson is one hour of
/// the week and the practising is the other hundred and sixty-seven. Follow
/// me already leaves a mark when an hour ends (0128), and Home offers it back
/// with one verb. What there was no way to do was think of it afterwards —
/// on Wednesday evening, that Jess should spend the week on the second
/// chorus, slowly. This is that, and it writes the same mark, so the student
/// sees the card they already know rather than a new kind of thing.
///
/// Kept out of the screen so the words and the rule about who sees the
/// action can be read in a test, the same reason sending_a_take is its own
/// file.

/// The student to leave practice for, or null when there is no such person.
///
/// The mirror of teacherToSendTo in layers/sending_a_take: that one asks who
/// a take is going to and answers for the student, this one asks who practice
/// is being left for and answers for the teacher. Both refuse for the same
/// reasons, because they are the same promise read from opposite ends.
///
/// Null for every band room — a band room is four people and none of them is
/// anybody's teacher. Null for the student's own side of a lesson, where the
/// owner is somebody else. And null once a third person is in the room,
/// because by then which of them the lesson belongs to is no longer a
/// question the membership answers.
({String id, String name})? studentToLeavePracticeFor({
  required bool lessonRoom,
  required MusicRoom? room,
  required String? me,
}) {
  if (!lessonRoom || room == null || me == null || me.isEmpty) return null;
  if (room.members.length != 2) return null;
  RoomMember? owner;
  RoomMember? other;
  for (final member in room.members) {
    if (member.role == RoomRole.owner) {
      owner = member;
    } else {
      other = member;
    }
  }
  if (owner == null || other == null) return null;
  if (owner.userId != me) return null;
  final name = other.displayName.trim();
  // A lesson room always names its student (join_lesson_link falls back to
  // "A student"), but a room read back without names would otherwise put an
  // empty gap in the middle of the menu.
  return (id: other.userId, name: name.isEmpty ? 'your student' : name);
}

/// What the menu entry says.
String leavePracticeLabel(String student) => 'Leave practice for $student';

/// Whether Perform will have a sheet to follow on this song.
///
/// The one question that decides what is worth leaving. Perform applies a
/// mark's part and its speed only when it has sheet lines to move against —
/// `_hasSync` in live_performance_screen, which is a ready analysis with
/// lines in it — and without them the song opens whole, at its own speed,
/// with the practice row not on screen at all. So a song with no sheet is
/// offered neither a part nor a speed: a card reading "Chorus 1 at ½" over a
/// song that opens at the top at 1× would be the app telling the teacher one
/// thing and the student another, and the teacher would never find out,
/// because they do not see the card.
///
/// Asked the same way Perform asks it, from the same two functions, so the
/// two cannot drift apart without the tests noticing.
bool songHasASheet(SongProject project, SongAnalysisBundle? analysis) {
  if (analysis == null || !analysis.ready) return false;
  return buildMusicianSheetLines(project, analysis, ignoreWorkspaceLyrics: true)
      .isNotEmpty;
}

/// One thing to point at on the song: the whole of it, or a part the sheet
/// found.
///
/// The whole song first and already chosen, because it is the answer that is
/// never wrong — a song with no sheet yet still has a teacher who wants to
/// say "all of it, at half speed".
@immutable
class PracticeTarget {
  const PracticeTarget({required this.label, this.startMs, this.endMs});

  final String label;
  final int? startMs;
  final int? endMs;
}

/// What there is to point at, named the way Perform's chips name it, so the
/// card the student gets says what they would have heard said out loud.
List<PracticeTarget> practiceTargets(List<StructureSection> sections) {
  final labels = sectionChipLabels(sections);
  return <PracticeTarget>[
    const PracticeTarget(label: 'The whole song'),
    for (var index = 0; index < sections.length; index += 1)
      PracticeTarget(
        label: labels[index],
        startMs: sections[index].startMs,
        endMs: sections[index].endMs,
      ),
  ];
}

/// What a teacher decided to leave.
@immutable
class PracticeToLeave {
  const PracticeToLeave({required this.part, this.note});

  /// Nothing was played, so nothing was timed: the seconds on a part exist
  /// only to put several of them in order (0128) and no screen reads them.
  final PracticePart part;
  final String? note;
}

/// The line the teacher sees back once it is left: what they pointed at, in
/// the words the student's card will use.
///
/// No time in it and no date. The student's card says nothing about when,
/// for the reason 0128 gives — a card that read "three days ago" would turn
/// a record of practising into a record of not practising — and the sentence
/// the teacher is shown should not quietly say more than the one the student
/// gets.
String practiceLeftSaid(String student, PracticeToLeave left) =>
    'Left for $student · ${practiceSaid(left.part)}';

/// Asks the teacher what to leave: a part, a speed, and a few words.
Future<PracticeToLeave?> showLeavePractice(
  BuildContext context, {
  required String student,
  required List<StructureSection> sections,
  required bool sheet,
}) {
  return showModalBottomSheet<PracticeToLeave>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.raised,
    // The sheet's own context, not the song's: the keyboard comes up under
    // this builder, and a MediaQuery read from the screen behind would be
    // read once and never again.
    builder: (sheetContext) => Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
      child: LeavePracticeSheet(
        student: student,
        sections: sections,
        sheet: sheet,
      ),
    ),
  );
}

/// The sheet itself, public so a test can put it on screen without a route.
class LeavePracticeSheet extends StatefulWidget {
  const LeavePracticeSheet({
    required this.student,
    required this.sections,
    required this.sheet,
    super.key,
  });

  final String student;
  final List<StructureSection> sections;

  /// Whether Perform has a sheet to follow on this song (see [songHasASheet]).
  ///
  /// False is the ordinary case before a recording has been made, and it is
  /// what keeps the sheet from offering a part or a speed that Practise would
  /// quietly drop. The words always work.
  final bool sheet;

  @override
  State<LeavePracticeSheet> createState() => _LeavePracticeSheetState();
}

class _LeavePracticeSheetState extends State<LeavePracticeSheet> {
  final TextEditingController _note = TextEditingController();
  int _target = 0;
  double _rate = practiceRates.last;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _leaveIt(List<PracticeTarget> targets) {
    final target = targets[_target];
    final note = _note.text.trim();
    Navigator.pop(
      context,
      PracticeToLeave(
        part: PracticePart(
          label: target.label,
          rate: _rate,
          seconds: 0,
          startMs: target.startMs,
          endMs: target.endMs,
        ),
        note: note.isEmpty ? null : note,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // No sheet, nothing to point at inside the song: Perform would open it at
    // the top whichever part was chosen.
    final targets =
        practiceTargets(widget.sheet ? widget.sections : const <StructureSection>[]);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.82,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                leavePracticeLabel(widget.student),
                style: const TextStyle(
                  color: AppColors.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 5),
              // What it is, said once: this is the thing Home offers back,
              // not a message in the thread.
              Text(
                'It waits on ${widget.student}’s Home, ready to play.',
                style: const TextStyle(
                    color: AppColors.muted, fontSize: 12.5, height: 1.45),
              ),
              const SizedBox(height: 16),
              const _Label('Which part'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (var index = 0; index < targets.length; index += 1)
                    ChoiceChip(
                      key: Key('leave_practice_part_$index'),
                      label: Text(targets[index].label),
                      selected: index == _target,
                      onSelected: (_) => setState(() => _target = index),
                    ),
                ],
              ),
              if (!widget.sheet) ...<Widget>[
                const SizedBox(height: 8),
                // Said once, plainly, and it covers both the missing chips
                // and the missing speeds: there is nothing to slow down to
                // and nowhere inside the song to start.
                const Text(
                  'This song has no sheet yet, so the whole of it is all '
                  'there is to point at, and it opens at its own speed.',
                  key: Key('leave_practice_no_sheet'),
                  style: TextStyle(
                      color: AppColors.muted, fontSize: 12.5, height: 1.45),
                ),
              ],
              if (widget.sheet) ...<Widget>[
                const SizedBox(height: 18),
                const _Label('How fast'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: <Widget>[
                    for (final rate in practiceRates)
                      ChoiceChip(
                        key: Key('leave_practice_rate_${rateLabel(rate)}'),
                        label: Text(rateLabel(rate)),
                        selected: rate == _rate,
                        onSelected: (_) => setState(() => _rate = rate),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 18),
              const _Label('Anything to say', note: 'optional'),
              const SizedBox(height: 8),
              TextField(
                key: const Key('leave_practice_note'),
                controller: _note,
                maxLines: 3,
                maxLength: 280,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'Keep it slow until the change is clean.',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 6),
              FilledButton(
                key: const Key('leave_practice_do'),
                onPressed: () => _leaveIt(targets),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                ),
                child: const Text('Leave it'),
              ),
              const SizedBox(height: 8),
              // The half of it a teacher would otherwise have to guess at.
              // Practice is private to whoever practises (0128), and a
              // teacher who believed otherwise would be watching for
              // something that is never going to appear.
              Text(
                'You will not see whether ${widget.student} opened it.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.muted, fontSize: 11.5, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text, {this.note});

  final String text;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Text(
          text,
          style: const TextStyle(
            color: AppColors.text,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (note != null) ...<Widget>[
          const SizedBox(width: 6),
          Text(
            note!,
            style: const TextStyle(color: AppColors.muted, fontSize: 11.5),
          ),
        ],
      ],
    );
  }
}
