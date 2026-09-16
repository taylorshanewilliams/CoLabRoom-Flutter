import 'package:colabroom/app/colabroom_theme.dart';
import 'package:colabroom/domain/name_policy.dart';
import 'package:colabroom/services/user_facing_error.dart';
import 'package:colabroom/widgets/problem_report.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A refusal is an answer, not a fault.
///
/// On the emulator, 16 Sep 2026: typing your own lesson code into Join with
/// a code said "That is your own lesson link. Share it with a student." --
/// correct -- beside a "Tell us" button, as though the app thought it had
/// broken. A sentence the app or the server wrote for a reader on purpose
/// is said plainly; only a real failure offers to hear about it.
void main() {
  test('what counts as a refusal', () {
    expect(isRefusal(const NameConflict('A room with that name already exists.')), isTrue);
    expect(isRefusal(const PostgrestException(message: 'That is your own lesson link.', code: '22023')), isTrue);
    expect(isRefusal(const PostgrestException(message: 'permission denied', code: '42501')), isFalse);
    expect(isRefusal(StateError('broken')), isFalse);
  });

  Future<void> show(WidgetTester tester, Object error) async {
    await tester.pumpWidget(MaterialApp(
      theme: CoLabRoomTheme.dark(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showProblem(context, error, service: 'app', stage: 'test', route: 'Test'),
            child: const Text('go'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('a refusal is said without asking for a bug report', (tester) async {
    await show(tester, const PostgrestException(
      message: 'That is your own lesson link. Share it with a student.',
      code: '22023',
    ));
    expect(find.text('That is your own lesson link. Share it with a student.'), findsOneWidget);
    expect(find.text('Tell us'), findsNothing);
  });

  testWidgets('a real failure still offers to hear about it', (tester) async {
    await show(tester, const PostgrestException(message: 'boom', code: 'XX000'));
    expect(find.text('Tell us'), findsOneWidget);
  });
}
