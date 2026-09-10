import 'package:flutter/foundation.dart';

/// Whether the thing that records failures is itself working.
///
/// `ErrorReporter` has always ended in `catch (_) {}`, and the reasoning was
/// sound as far as it went: telemetry must never break the thing it is
/// watching. But *not throwing* and *leaving no trace* are different, and only
/// the first one was required. The second cost five days of not knowing.
///
/// On 2026-09-05 `analysis_errors` held 36 rows from one account. On
/// 2026-09-10 it held 57 rows from one account, while three other people used
/// the app. There are two explanations — nobody else hit a failure, or every
/// report they produced was swallowed here — and the app was built so that
/// they look exactly alike from the outside. Nothing in the table can tell
/// them apart, and nothing ever will, because the evidence was discarded at
/// the moment it was created.
///
/// So a report that cannot be sent is counted where it happened. It costs
/// nothing, it cannot fail, and it turns "no rows" from an unanswerable
/// question into one the next person to open the report sheet answers by
/// accident.
abstract final class TelemetryHealth {
  static int _failures = 0;
  static String? _lastReason;
  static DateTime? _lastAt;

  /// A report could not be delivered by any route.
  static void reportFailed(Object error) {
    _failures++;
    // The first line only. A swallowed PostgrestException says what is wrong
    // in its message — "new row violates row-level security policy" is the
    // whole diagnosis — and the stack below it is this file every time.
    _lastReason = error.toString().split('\n').first.trim();
    _lastAt = DateTime.now();
  }

  /// How many reports this session went nowhere.
  static int get failures => _failures;

  /// A line to carry in a report somebody writes by hand, or null when the
  /// telemetry path has been working — which is the usual case, and must not
  /// add noise to every message somebody sends.
  static String? get summary {
    if (_failures == 0) return null;
    return 'Telemetry: $_failures report(s) could not be sent this session. '
        'Last reason: ${_lastReason ?? 'unknown'}.';
  }

  /// When the last one failed, for anyone asking whether this is current.
  static DateTime? get lastAt => _lastAt;

  @visibleForTesting
  static void reset() {
    _failures = 0;
    _lastReason = null;
    _lastAt = null;
  }
}
