import 'package:flutter/material.dart';

import '../app/colabroom_theme.dart';
import '../features/help/help_answers.dart';

/// The answer to one question, beside the thing it is about.
///
/// The app already knew how to explain itself. `help_answers.dart` answers
/// exactly the questions a new person has — who can hear my song, how do I
/// ask somebody for help, what happens when I put a song on the Open Mic —
/// and every one of them was filed behind the avatar, in Account, under
/// Help. Two taps from anywhere and signposted from nowhere.
///
/// Which is the difference between hiding complexity until it is needed and
/// never telling anybody it exists. The first is the reason this app is
/// calm. The second is why somebody can use it for a week without finding
/// out it hears chords.
///
/// So the answer moves to the question. A mark you can ignore completely —
/// it is the size of a full stop and the colour of the text around it — and
/// which, when somebody does wonder, answers in place rather than sending
/// them to a screen and losing their thread.
class HelpDot extends StatelessWidget {
  const HelpDot({required this.answerId, this.semanticLabel, super.key});

  /// The `id` of an entry in [helpAnswers].
  final String answerId;

  /// Overrides the tooltip, for a control whose question is phrased
  /// differently in place than it is in the help list.
  final String? semanticLabel;

  HelpAnswer? get _answer {
    for (final answer in helpAnswers) {
      if (answer.id == answerId) return answer;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final answer = _answer;
    // A dot pointing at nothing would be worse than no dot: it promises an
    // answer and opens an empty sheet. An id that stops matching after a
    // rename simply disappears.
    if (answer == null) return const SizedBox.shrink();

    return Tooltip(
      message: semanticLabel ?? answer.question,
      child: InkResponse(
        key: Key('help_dot_$answerId'),
        onTap: () => showHelpAnswer(context, answerId),
        radius: 16,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Icon(
            Icons.help_outline_rounded,
            size: 15,
            color: AppColors.muted.withValues(alpha: 0.75),
          ),
        ),
      ),
    );
  }
}

/// Shows one answer where somebody is standing.
///
/// A sheet rather than a route, because the question is about the thing on
/// screen and taking the thing off screen to answer it is the behaviour that
/// made the help screen useless in the first place.
Future<void> showHelpAnswer(BuildContext context, String answerId) async {
  HelpAnswer? found;
  for (final answer in helpAnswers) {
    if (answer.id == answerId) found = answer;
  }
  if (found == null) return;
  final answer = found;

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.raised,
    showDragHandle: true,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 4, 22, 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              answer.question,
              style: const TextStyle(
                color: AppColors.text,
                fontSize: 17,
                fontWeight: FontWeight.w800,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Text(
                  answer.answer,
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 14.5,
                    height: 1.55,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
