import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/name_policy.dart';
import 'error_reporter.dart';
import 'recent_trouble.dart';

/// What to put on screen when an action fails, and what to send home about it.
///
/// These two questions have the same answer everywhere and had been answered
/// separately — badly — in every screen. The join button in the Inbox showed
/// the exception's own `toString()`:
///
///   PostgrestException(message: duplicate key value violates unique
///   constraint "room_members_room_color_unique", code: 23505, details: Key
///   (room_id, color_value)=(2531…, 4294957644) already exists., hint: null)
///
/// A person holding a phone learns nothing from that, and — because nothing
/// reported it — neither did anybody else. A real beta tester was handed that
/// sentence repeatedly on 2026-09-05 while `analysis_errors` stayed empty for
/// nine days and the triage workflow kept reporting "no new error signatures".
///
/// So: the reader gets a sentence about what happened to them, the database
/// gets the detail, and the detail is no longer the only copy.
String describeForUser(Object error) {
  // Errors the app raised on purpose already carry a sentence written for a
  // reader. NameConflict is the app's own "that name is taken".
  if (error is NameConflict) return error.message;

  if (error is PostgrestException) {
    switch (error.code) {
      case '23505':
        return 'Something with those details already exists.';
      case '42501':
        return "You don't have access to do that.";
      case '22023':
        // The invite functions raise this with a sentence already meant for a
        // reader — "That invitation is no longer available."
        return error.message;
      case '54000':
        return 'That Room is full.';
    }
    // A database message is not written for a musician, so don't show one.
    return 'That did not go through. It has been reported — try again in a moment.';
  }

  if (error is AuthException) return error.message;

  if (error is TimeoutException) {
    return 'That took too long. Check your connection and try again.';
  }

  // StateError and friends are used across this app to carry a sentence the
  // user is meant to read ("That take came back silent — …"), so the message
  // is worth showing where there is one.
  if (error is StateError && error.message.trim().isNotEmpty) {
    return error.message;
  }

  return 'Something went wrong. It has been reported — try again in a moment.';
}

/// Report a failure, then say what to show for it.
///
/// The reporting is deliberately fire-and-forget and deliberately unawaited:
/// telemetry must never be the reason a screen takes longer to tell somebody
/// their action failed. [ErrorReporter] already swallows its own failures.
/// The same, for something that degraded rather than failed.
///
/// Warnings matter more than they look: a stage that quietly falls back still
/// produces a result, so it is invisible in any success/failure count, which
/// is exactly why it needs its own signal. Returns nothing, because nobody is
/// being shown a sentence - this is for the table only.
void reportWarningAndDescribe(
  Object error, {
  required String service,
  String? stage,
  String? projectId,
  String? route,
  ErrorReporter? reporter,
}) {
  unawaited((reporter ?? ErrorReporter()).reportWarning(
    service: service,
    stage: stage,
    message: error.toString(),
    projectId: projectId,
    route: route,
  ));
}

String reportAndDescribe(
  Object error, {
  required String service,
  String? stage,
  String? projectId,
  String? route,
  ErrorReporter? reporter,
}) {
  unawaited((reporter ?? ErrorReporter()).reportError(
    service: service,
    stage: stage,
    // The full detail, not the sentence — this half is for whoever is reading
    // the table, and losing the constraint name is losing the diagnosis.
    message: error.toString(),
    projectId: projectId,
    route: route,
  ));
  // Held on to for a few minutes, so that if the person decides to say what
  // they were doing, the exception rides along without them being asked to
  // retype an error message they were shown and dismissed.
  RecentTrouble.remember(error, route: route);
  return describeForUser(error);
}
