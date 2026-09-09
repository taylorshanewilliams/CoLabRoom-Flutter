import 'package:colabroom/services/recent_trouble.dart';
import 'package:colabroom/services/user_facing_error.dart';
import 'package:colabroom/widgets/problem_report.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A failure somebody can say something about.
///
/// Reporting already worked: `reportAndDescribe` is called in around forty
/// places and every one lands a row. What never worked is the other half —
/// twelve screens showed the sentence and nothing asked the person the one
/// question the table cannot answer, which is what they were trying to do.
///
/// The Account screen's form has existed since the first build and has never
/// been used once.
void main() {
  setUp(RecentTrouble.clear);

  test('a described failure is remembered for the report that follows', () {
    expect(RecentTrouble.detail, isNull, reason: 'nothing has failed yet');

    reportAndDescribe(
      StateError('room_members_room_color_unique'),
      service: 'app',
      route: 'Inbox',
    );

    expect(RecentTrouble.detail, contains('room_members_room_color_unique'),
        reason: 'the exception is what the table needs and the person cannot '
            'be asked to retype');
    expect(RecentTrouble.route, 'Inbox');
  });

  test('nothing is attached when nothing recent went wrong', () {
    // Somebody opening the feedback form on a good day is writing about
    // something else. Stapling an unrelated stack trace to their message
    // would look like a diagnosis and point at the wrong thing.
    expect(RecentTrouble.detail, isNull);
  });

  testWidgets('the sentence carries an offer to say more', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: ProblemNote('That did not go through.'),
      ),
    ));

    expect(find.text('That did not go through.'), findsOneWidget);
    expect(
      find.text('Tell us what you were doing'),
      findsOneWidget,
      reason: 'this is the whole point: the moment somebody has just been let '
          'down is the only moment they will describe what they were doing',
    );
  });
}
