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

  /// How much of Flutter's own diagnostic to keep. Enough to name the widget
  /// and its geometry; not the subtree dump that follows.
  static const int _detailNodes = 4;
  static const int _detailMaxChars = 700;

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
        detail: _flutterDetail(details),
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
    String detail = '',
  }) async {
    try {
      final description = error.toString();
      // The signature stays keyed on the exception alone. [detail] names the
      // widget, and widgets are exactly what changes between two occurrences
      // of the same bug — folding it in would defeat the deduplication it is
      // meant to make useful.
      final signature = _localSignature(description, stack);
      if (!_claimSendSlot(signature)) return;

      final trace = _firstFrames(stack);
      final message = <String>[
        description,
        if (detail.isNotEmpty) detail,
        if (trace.isNotEmpty) trace,
      ].join('\n\n');
      await _reporter.reportError(
        service: 'app',
        stage: stage,
        message: message,
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

  /// What the framework knows about a Flutter error beyond its one-line
  /// message.
  ///
  /// `exception.toString()` on a layout error is "A RenderFlex overflowed by
  /// 3.0 pixels on the bottom." and nothing else — no widget, no screen, no
  /// way to act on it. A real report of exactly that arrived and could only
  /// be guessed at. Everything needed was already in [FlutterErrorDetails];
  /// it was just never read.
  ///
  /// [FlutterErrorDetails.context] is the phase ("during layout"), and the
  /// information collector is where the framework puts the offending
  /// `RenderFlex`, its size and orientation, and the widget that created it.
  ///
  /// Capped, because that collector is written for a console and will happily
  /// print a whole subtree. The first few nodes carry the identification; the
  /// rest is the part nobody reads.
  static String _flutterDetail(FlutterErrorDetails details) {
    final parts = <String>[];
    try {
      final context = details.context;
      if (context != null) parts.add(context.toDescription());
      final collected = details.informationCollector?.call();
      if (collected != null) {
        for (final node in collected.take(_detailNodes)) {
          final line = node.toDescription().replaceAll(RegExp(r'\s+'), ' ').trim();
          if (line.isNotEmpty) parts.add(line);
        }
      }
    } catch (_) {
      // Diagnostics are best-effort. A collector that throws while describing
      // a broken widget must not replace that widget's error with its own.
    }
    if (parts.isEmpty) return '';
    final joined = parts.join('\n');
    return joined.length <= _detailMaxChars
        ? joined
        : '${joined.substring(0, _detailMaxChars)}…';
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

  /// [_flutterDetail], reachable from a test.
  ///
  /// Exposed rather than driving `FlutterError.onError` directly, because
  /// under flutter_test that handler belongs to the test harness — invoking
  /// it reports a *test* failure instead of exercising this code.
  @visibleForTesting
  static String describeFlutterError(FlutterErrorDetails details) =>
      _flutterDetail(details);

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
