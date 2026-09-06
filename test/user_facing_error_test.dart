import 'dart:async';

import 'package:colabroom/domain/name_policy.dart';
import 'package:colabroom/services/error_reporter.dart';
import 'package:colabroom/services/user_facing_error.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('describeForUser', () {
    test('never puts a database message on a musician screen', () {
      // The exact failure a beta tester was shown, repeatedly, while standing
      // next to the person who wrote the app.
      final message = describeForUser(PostgrestException(
        message: 'duplicate key value violates unique constraint '
            '"room_members_room_color_unique"',
        code: '23505',
        details: 'Key (room_id, color_value)=(2531…, 4294957644) '
            'already exists.',
      ));

      expect(message, isNot(contains('constraint')));
      expect(message, isNot(contains('room_members')));
      expect(message, isNot(contains('PostgrestException')));
      expect(message, isNot(contains('23505')));
    });

    test('keeps the sentence when the database was given one to raise', () {
      // 22023 is what the invite functions use for the messages that were
      // written to be read: "That invitation is no longer available."
      expect(
        describeForUser(PostgrestException(
          message: 'That invitation is no longer available.',
          code: '22023',
        )),
        'That invitation is no longer available.',
      );
    });

    test('keeps the app\'s own written errors', () {
      expect(
        describeForUser(const NameConflict('A song with that name exists.')),
        'A song with that name exists.',
      );
      expect(
        describeForUser(StateError('That take came back silent.')),
        'That take came back silent.',
      );
    });

    test('says something useful about a connection that gave up', () {
      expect(describeForUser(TimeoutException('x')), contains('connection'));
    });

    test('falls back to a sentence, not a type name', () {
      final message = describeForUser(ArgumentError('bad input'));
      expect(message, isNot(contains('ArgumentError')));
      expect(message, contains('reported'));
    });
  });

  group('reportAndDescribe', () {
    test('sends the detail home and returns only the readable half', () async {
      final reporter = _RecordingReporter();
      final shown = reportAndDescribe(
        PostgrestException(
          message: 'duplicate key value violates unique constraint '
              '"room_members_room_color_unique"',
          code: '23505',
        ),
        service: 'app',
        stage: 'invite',
        route: 'Inbox',
        reporter: reporter,
      );

      // The report is unawaited on purpose — telemetry must not slow down
      // telling somebody their tap failed — so let the microtask run.
      await Future<void>.delayed(Duration.zero);

      expect(shown, isNot(contains('room_members')));
      expect(reporter.messages.single, contains('room_members_room_color_unique'));
      expect(reporter.services.single, 'app');
      expect(reporter.stages.single, 'invite');
      // The screen, which is the fact every report in this app has been
      // missing and the one the triage agent kept asking for.
      expect(reporter.routes.single, 'Inbox');
    });
  });
}

/// Same shape as crash_reporter_test's fake: extend rather than implement, so
/// nothing here has to keep up with the reporter's other methods.
class _RecordingReporter extends ErrorReporter {
  final List<String> messages = <String>[];
  final List<String> services = <String>[];
  final List<String?> stages = <String?>[];
  final List<String?> routes = <String?>[];

  @override
  Future<void> reportError({
    required String service,
    required String message,
    String? stage,
    String? projectId,
    String? route,
  }) async {
    services.add(service);
    messages.add(message);
    stages.add(stage);
    routes.add(route);
  }
}
