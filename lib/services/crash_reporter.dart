import 'dart:async';

// PlatformDispatcher comes from here too, so dart:ui would be a second
// import of the same thing.
import 'package:flutter/foundation.dart';

import 'error_reporter.dart';

/// Sends uncaught errors somewhere they can be counted.
///
/// Until this existed, an exception that escaped a `try` went to the console
/// and nowhere else. On a debug build that means it scrolls past in a terminal
/// nobody is watching; on a tester's phone it means it is simply gone. The
/// only reason the save bug was ever diagnosed is that somebody happened to
/// read a message off a screen and type it into a chat — which is not a
/// reporting strategy, it is a coincidence.
///
/// Rows land in `analysis_errors` alongside the analysis pipeline's own
/// failures. The table's name is now too narrow for what it holds, but what it
/// gives up in naming it more than pays back in machinery: a trigger that
/// collapses per-occurrence noise into a stable grouping signature, indexes
/// for counting by that signature, and a triage workflow that already reads
/// it. A second table would have meant a second copy of all three. `service`
/// tells the two apart.
abstract final class CrashReporter {
  static ErrorReporter _reporter = ErrorReporter();

  @visibleForTesting
  static set reporter(ErrorReporter value) => _reporter = value;

  /// Reports seen this session and when, keyed by a cheap local signature.
  ///
  /// A crashing build does not fail once. A widget that throws during build
  /// throws again on the next frame, and a polling loop that throws does it
  /// every few seconds — so the naive version of this turns one bug into
  /// thousands of identical rows, which costs money and buries every other
  /// failure in the table. The first occurrence is the one that carries the
  /// information; the rest are volume.
  static final Map<String, DateTime> _lastSentAt = <String, DateTime>{};

  static int _sentThisSession = 0;

  /// A hard ceiling regardless of variety, for the case the cooldown cannot
  /// help with: a loop throwing errors that are each *slightly* different.
  static const int _maxPerSession = 25;

  static const Duration _repeatCooldown = Duration(minutes: 5);

  /// Enough frames to identify the bug, not so many that one stack fills the
  /// message column and crowds out the end of the exception.
  static const int _stackFrames = 12;

  /// Installs the handlers. Call once, as early in `main` as possible — errors
  /// thrown before this lands are not recoverable by anything downstream.
  static void install() {
    // Chained rather than replaced: the default prints the error, and a
    // reporter that silences the console would make local debugging worse in
    // exchange for making production better.
    final previous = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      previous?.call(details);
      unawaited(report(
        details.exception,
        details.stack,
        stage: details.library ?? 'flutter',
      ));
    };

    // Everything the framework does not route through FlutterError: errors
    // from futures with no `catchError`, from streams with no `onError`, from
    // a callback that was fired by the platform rather than by a widget.
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      unawaited(report(error, stack, stage: 'async'));
      // Handled, in the sense that it has been recorded. Returning false only
      // hands it back to a default that prints it and moves on.
      return true;
    };
  }

  /// Records one error. Never throws and never rethrows: a reporter that can
  /// take down the app it is watching is worse than no reporter.
  static Future<void> report(
    Object error,
    StackTrace? stack, {
    String stage = 'uncaught',
  }) async {
    try {
      final description = error.toString();
      final signature = _localSignature(description, stack);
      if (!_claimSendSlot(signature)) return;

      final trace = _firstFrames(stack);
      await _reporter.reportError(
        service: 'app',
        stage: stage,
        message: trace.isEmpty ? description : '$description\n\n$trace',
      );
    } catch (_) {
      // Reporting a crash must not become one.
    }
  }

  /// Whether this occurrence earns a row, and books it if so.
  static bool _claimSendSlot(String signature) {
    if (_sentThisSession >= _maxPerSession) return false;
    final now = DateTime.now();
    final last = _lastSentAt[signature];
    if (last != null && now.difference(last) < _repeatCooldown) return false;
    _lastSentAt[signature] = now;
    _sentThisSession += 1;
    return true;
  }

  /// A local grouping key, only ever used to decide whether this looks like
  /// something already sent. The authoritative signature is the one the
  /// database derives — this one just has to be cheap and stable.
  static String _localSignature(String description, StackTrace? stack) {
    final firstLine = description.split('\n').first.trim();
    final frames = stack?.toString().split('\n') ?? const <String>[];
    final topFrame = frames.isEmpty ? '' : frames.first.trim();
    return '$firstLine|$topFrame';
  }

  static String _firstFrames(StackTrace? stack) {
    if (stack == null) return '';
    final lines = stack
        .toString()
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .take(_stackFrames)
        .toList(growable: false);
    return lines.join('\n');
  }

  @visibleForTesting
  static void resetForTest() {
    _lastSentAt.clear();
    _sentThisSession = 0;
    _reporter = ErrorReporter();
  }

  @visibleForTesting
  static int get sentThisSession => _sentThisSession;

  @visibleForTesting
  static int get maxPerSession => _maxPerSession;
}
