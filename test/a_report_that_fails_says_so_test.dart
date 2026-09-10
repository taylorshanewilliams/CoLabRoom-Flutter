import 'package:colabroom/services/telemetry_health.dart';
import 'package:flutter_test/flutter_test.dart';

/// The thing that records failures, recording its own.
///
/// `ErrorReporter._report` ended in `catch (_) {}` from the first build. The
/// reason given was correct — telemetry must never break the thing it is
/// watching — but it did more than that: it destroyed the evidence. On
/// 2026-09-05 `analysis_errors` held 36 rows from one account; on 2026-09-10
/// it held 57 rows from one account, five days and three other users later.
///
/// Two explanations fit that equally — nobody else hit a failure, or every
/// report they produced was swallowed — and the app was built so they cannot
/// be told apart from the outside. This is the counter that tells them apart.
void main() {
  setUp(TelemetryHealth.reset);

  test('a working reporter adds nothing to anybody’s message', () {
    // The usual case, and the one that must stay silent. A line about
    // telemetry on every report somebody sends by hand is noise attached to
    // the scarcest thing this app receives.
    expect(TelemetryHealth.summary, isNull);
    expect(TelemetryHealth.failures, 0);
  });

  test('a report that could not be sent is counted and says why', () {
    TelemetryHealth.reportFailed(
      StateError('new row violates row-level security policy '
          'for table "analysis_errors"'),
    );

    expect(TelemetryHealth.failures, 1);
    expect(TelemetryHealth.summary, contains('1 report'));
    expect(
      TelemetryHealth.summary,
      contains('row-level security'),
      reason: 'the refusal is the whole diagnosis, and it is the one sentence '
          'that never reaches the table because the table is what refused it',
    );
    expect(TelemetryHealth.lastAt, isNotNull);
  });

  test('only the first line of the reason is kept', () {
    TelemetryHealth.reportFailed(
      StateError('PostgrestException: refused\n#0 something\n#1 else'),
    );

    expect(TelemetryHealth.summary, contains('refused'));
    expect(
      TelemetryHealth.summary,
      isNot(contains('#1 else')),
      reason: 'the stack below a swallowed report is error_reporter.dart '
          'every single time, and this line has to fit in a message a person '
          'is about to read before sending',
    );
  });

  test('a crash loop is a count, not a hundred lines', () {
    for (var i = 0; i < 12; i++) {
      TelemetryHealth.reportFailed(StateError('offline'));
    }

    expect(TelemetryHealth.failures, 12);
    expect(TelemetryHealth.summary, contains('12 report'));
  });
}
