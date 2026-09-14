import 'dart:async';

import 'package:colabroom/services/retry.dart';
import 'package:colabroom/services/user_facing_error.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Two things production said in the week of 9 September 2026, and what a
/// person should have been told instead.
void main() {
  group('a clock that is ahead', () {
    test('is named as the clock, not as something going wrong', () {
      final message = describeForUser(PostgrestException(
        message: 'JWT issued at future',
        code: 'PGRST303',
        details: 'Unauthorized',
      ));
      expect(message, contains('clock'));
      expect(message, contains('automatic date and time'));
      expect(message, isNot(contains('PGRST')));
      expect(message, isNot(contains('JWT')));
    });

    test('any other refused token asks for a fresh sign-in', () {
      final message = describeForUser(PostgrestException(
        message: 'JWT expired',
        code: 'PGRST301',
      ));
      expect(message, contains('Sign out'));
      expect(message, isNot(contains('JWT')));
    });

    test('a gateway timeout is a sentence, not a JSON blob', () {
      final message = describeForUser(
        AuthRetryableFetchException(message: '{"message":"Gateway Timeout"}'),
      );
      expect(message, isNot(contains('{')));
      expect(message, contains('did not answer'));
    });
  });

  group('retrying', () {
    test('tries again on the failures that go away by themselves', () async {
      var calls = 0;
      final pauses = <Duration>[];
      final result = await retrying<String>(
        () async {
          calls++;
          if (calls < 3) {
            throw AuthRetryableFetchException(
                message: '{"message":"Gateway Timeout"}');
          }
          return 'registered';
        },
        wait: (pause) async => pauses.add(pause),
      );
      expect(result, 'registered');
      expect(calls, 3);
      // Doubling, so three quick failures do not become a hammer.
      expect(pauses, <Duration>[
        const Duration(seconds: 1),
        const Duration(seconds: 2),
      ]);
    });

    test('gives up after the last try and rethrows what happened', () async {
      var calls = 0;
      await expectLater(
        retrying<void>(
          () async {
            calls++;
            throw TimeoutException('still nothing');
          },
          wait: (_) async {},
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(calls, 3);
    });

    test('does not retry a token the server refused', () async {
      var calls = 0;
      await expectLater(
        retrying<void>(
          () async {
            calls++;
            throw PostgrestException(
                message: 'JWT issued at future', code: 'PGRST303');
          },
          wait: (_) async {},
        ),
        throwsA(isA<PostgrestException>()),
      );
      // Waiting does not move a clock. One call, one row in the table.
      expect(calls, 1);
    });

    test('knows which failures are worth a second try', () {
      expect(worthRetrying(TimeoutException('x')), isTrue);
      expect(
        worthRetrying(AuthRetryableFetchException(message: 'gateway')),
        isTrue,
      );
      expect(
        worthRetrying(PostgrestException(message: 'Gateway Timeout')),
        isTrue,
      );
      expect(
        worthRetrying(PostgrestException(
            message: 'duplicate key value', code: '23505')),
        isFalse,
      );
      expect(
        worthRetrying(PostgrestException(
            message: 'JWT issued at future', code: 'PGRST303')),
        isFalse,
      );
      expect(worthRetrying(StateError('a bug')), isFalse);
    });
  });
}
