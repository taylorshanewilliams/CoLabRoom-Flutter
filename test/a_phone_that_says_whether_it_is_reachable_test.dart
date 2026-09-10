import 'package:colabroom/services/error_reporter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:colabroom/services/user_facing_error.dart';
import 'package:flutter_test/flutter_test.dart';

/// The two facts the notifications screen used to conflate.
///
/// Established 2026-09-10 by querying production: `device_tokens` held **zero
/// rows and always had**, against 184 notifications. Every server-side part
/// of delivery was built and deployed — the register RPC, the
/// notifications_deliver trigger, push_config, the send-push function — and
/// none of it had ever carried a notification to a phone, because no phone
/// had ever registered.
///
/// The screen could not say so. It read `getNotificationSettings`, which is
/// the *operating system's* permission, and printed a claim about *this app*:
/// "Notifications reach you when the app is closed." Those are different
/// facts, and on 10 September the first was capable of being true while the
/// second was false for every account in existence.
///
/// The middle state is the one worth naming: allowed, and unreachable. It is
/// what iOS does when the Firebase project has no APNs key, and it looked
/// exactly like success.
void main() {
  test('a failure in the push path is described for a person', () {
    // These used to end in `if (kDebugMode) debugPrint(...)`, which is
    // nothing at all in the build a tester runs.
    // The real shape of a refused token registration.
    final sentence = describeForUser(
      const PostgrestException(
        message: 'new row violates row-level security policy for table '
            '"device_tokens"',
        code: '42501',
      ),
    );
    expect(sentence, "You don't have access to do that.",
        reason: 'the table gets the exception; the person gets a sentence');
  });

  test('the reporter accepts a warning as well as a failure', () {
    // getToken returning null is not an error — it is what iOS does without
    // an APNs key, every time, for everybody. It needs a row all the same,
    // because it is indistinguishable from working from anywhere else in the
    // app, and it silently removes push for the whole platform.
    final reporter = _Recording();
    reportWarningAndDescribe(
      StateError('getToken returned no token'),
      service: 'app',
      stage: 'push.no_token',
      reporter: reporter,
    );
    expect(reporter.warnings, hasLength(1));
    expect(reporter.warnings.single, 'push.no_token');
    expect(reporter.errors, isEmpty,
        reason: 'a warning must not inflate the failure count — a stage that '
            'degrades still produced a result, which is exactly why it needs '
            'its own signal');
  });
}

class _Recording extends ErrorReporter {
  final List<String> errors = <String>[];
  final List<String> warnings = <String>[];

  @override
  Future<void> reportError({
    required String service,
    required String message,
    String? stage,
    String? projectId,
    String? route,
  }) async =>
      errors.add(stage ?? '');

  @override
  Future<void> reportWarning({
    required String service,
    required String message,
    String? stage,
    String? projectId,
    String? route,
  }) async =>
      warnings.add(stage ?? '');
}
