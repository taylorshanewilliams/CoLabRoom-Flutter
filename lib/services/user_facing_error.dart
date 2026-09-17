import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/name_policy.dart';
import 'clock_skew.dart';
import 'error_reporter.dart';
import 'recent_trouble.dart';

/// The default answer to a limit: joining a Room is where most people meet
/// one, and it is the only place that hits a cap without having asked for
/// anything by name.
const String _roomIsFull = 'That Room is full.';

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
///
/// [whenFull] is the sentence for a limit the database refused to go past.
/// Postgres has one code for all of them — 54000, "program limit exceeded" —
/// and this app raises it from more than one place: a Room with no unused
/// collaborator colour left, and a profile that already shows eight links. The
/// sentence was written once, for the Room, so somebody adding a ninth link to
/// their own profile was told "That Room is full." — an answer to a question
/// they had not asked (audit, 17 September 2026). Only the caller knows what
/// was being added, so only the caller can say.
String describeForUser(Object error, {String whenFull = _roomIsFull}) {
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
        return whenFull;
      case 'PGRST301':
        return 'Your sign-in has expired. Sign out and back in.';
      case 'PGRST303':
        // "JWT issued at future": the phone's clock is ahead of the server's,
        // so every token it is handed looks forged. Seen five times in the
        // week of 9 September 2026 from one Android phone that could not load
        // anything and was told only that something went wrong. The person
        // can fix this in thirty seconds, but only if the sentence says what
        // it is.
        //
        // And then, on 14 September, it happened on an emulator whose clock
        // was eight seconds *behind* the host. The skew can be on the other
        // side, between the server that mints a token and the one that
        // checks it, and from the phone the two look identical. So the
        // sentence no longer swears it is the phone, the load tries again
        // first (worthRetrying), and ClockSkew files which clock it was.
        if (error.message.toLowerCase().contains('future')) {
          return 'The server refused this sign-in as if it came from the '
              "future. If this phone's clock is wrong, turn on automatic "
              'date and time; if it is right, this is on our side and trying '
              'again in a few seconds usually works.';
        }
        return 'Your sign-in needs refreshing. Sign out and back in.';
    }
    // A database message is not written for a musician, so don't show one.
    return 'That did not go through. It has been reported — try again in a moment.';
  }

  // The auth client's own "the gateway did not answer" carries a JSON blob as
  // its message — {"message":"Gateway Timeout"} — which is not a sentence.
  // Checked before the general AuthException case, which shows messages
  // as they are because the rest of them are written for a reader.
  if (error is AuthRetryableFetchException) {
    return 'The server did not answer in time. Check your connection and '
        'try again.';
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

/// Whether [error] is the app or the server saying no on purpose, in a
/// sentence already written for a reader: a name that is taken, an
/// invitation that has lapsed, "That is your own lesson link. Share it with
/// a student." Those are answers, not faults, and a screen should say them
/// plainly rather than offer to take a bug report about them.
bool isRefusal(Object error) =>
    error is NameConflict || (error is PostgrestException && error.code == '22023');

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
  String whenFull = _roomIsFull,
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
  // A token "from the future" is a question about clocks, and the phone can
  // answer it: one request, one header, filed beside the error. Without
  // this the table said "clock" five times and never which one.
  if (error is PostgrestException && error.code == 'PGRST303') {
    unawaited(ClockSkew.report(reporter: reporter, route: route));
  }
  // Held on to for a few minutes, so that if the person decides to say what
  // they were doing, the exception rides along without them being asked to
  // retype an error message they were shown and dismissed.
  RecentTrouble.remember(error, route: route);
  return describeForUser(error, whenFull: whenFull);
}
