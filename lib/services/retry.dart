import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Trying again, only when trying again could work.
///
/// On 2026-09-12 a phone said yes to notifications, the OS agreed, and the
/// one call that puts the token in the database met a 504 from the gateway.
/// Nothing tried again, so that phone stayed unreachable until its next
/// launch. A gateway timeout is the textbook case of a failure that is over
/// by the time you have finished reading it.
///
/// The opposite case matters as much: a bad token (`PGRST303`, a clock that
/// is ahead) does not get better by waiting, and retrying it three times is
/// three times the noise in the error table for the same fact.
bool worthRetrying(Object error) {
  if (error is TimeoutException) return true;
  if (error is AuthRetryableFetchException) return true;
  if (error is PostgrestException) {
    final code = error.code ?? '';
    // PGRST3xx is the token itself being refused. Waiting changes nothing.
    if (code.startsWith('PGRST3')) return false;
    final text = error.message.toLowerCase();
    return text.contains('timeout') ||
        text.contains('gateway') ||
        text.contains('unavailable') ||
        text.contains('too many');
  }
  final text = error.toString().toLowerCase();
  // dart:io is not importable on the web, so the network layer's own
  // exceptions are matched by name rather than by type.
  return text.contains('socketexception') ||
      text.contains('clientexception') ||
      text.contains('failed to fetch') ||
      text.contains('connection closed') ||
      text.contains('connection reset');
}

/// Runs [attempt] up to [times] times, doubling the pause between tries.
///
/// Rethrows the last error once it has given up, so a caller's own catch
/// still sees what actually happened. [shouldRetry] and [wait] exist for
/// tests; production uses [worthRetrying] and a real clock.
Future<T> retrying<T>(
  Future<T> Function() attempt, {
  int times = 3,
  Duration first = const Duration(seconds: 1),
  bool Function(Object error)? shouldRetry,
  Future<void> Function(Duration pause)? wait,
}) async {
  final decide = shouldRetry ?? worthRetrying;
  final pause = wait ?? (Duration d) => Future<void>.delayed(d);
  var delay = first;
  for (var attemptNumber = 1;; attemptNumber++) {
    try {
      return await attempt();
    } catch (error) {
      if (attemptNumber >= times || !decide(error)) rethrow;
      await pause(delay);
      delay *= 2;
    }
  }
}
