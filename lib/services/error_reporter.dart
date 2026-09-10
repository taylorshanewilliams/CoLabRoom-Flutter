import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app/beta_config.dart';
import 'app_session.dart';
import 'current_route.dart';
import 'telemetry_health.dart';

/// Records analysis failures and degradations into `analysis_errors` so they
/// can be counted instead of discovered one screenshot at a time.
///
/// Reports arrive whether or not anybody is signed in. That distinction used
/// to decide whether a crash was recorded at all, which meant the sign-in
/// screen — where a failure loses a person for good — was the one place the
/// app could break silently.
///
/// Warnings are reported as well as errors, and matter more than they look.
/// When a stage degrades — cloud chord detection falling back to the
/// on-device heuristic, lyrics giving up on an unclear vocal — the analysis
/// still completes and the user still gets a result, just a materially worse
/// one. Those runs are invisible in any success/failure metric, which is
/// exactly why they need their own signal.
class ErrorReporter {
  ErrorReporter({SupabaseClient? client}) : _clientOverride = client;

  final SupabaseClient? _clientOverride;

  /// Resolved on use so constructing a reporter never depends on Supabase
  /// being initialized — telemetry must not be the thing that breaks a
  /// screen it was only ever meant to observe.
  SupabaseClient get _client => _clientOverride ?? Supabase.instance.client;

  Future<void> reportError({
    required String service,
    required String message,
    String? stage,
    String? projectId,
    /// Where this happened. Defaults to whatever the app last knew; pass a
    /// better answer when the call site has one.
    String? route,
  }) {
    return _report(
      severity: 'error',
      service: service,
      message: message,
      stage: stage,
      projectId: projectId,
      route: route,
    );
  }

  Future<void> reportWarning({
    required String service,
    required String message,
    String? stage,
    String? projectId,
    /// Where this happened. Defaults to whatever the app last knew; pass a
    /// better answer when the call site has one.
    String? route,
  }) {
    return _report(
      severity: 'warning',
      service: service,
      message: message,
      stage: stage,
      projectId: projectId,
      route: route,
    );
  }

  Future<void> _report({
    required String severity,
    required String service,
    required String message,
    String? stage,
    String? projectId,
    String? route,
  }) async {
    final cleaned = message.trim();
    final where = route ?? CurrentRoute.name ?? 'unknown';
    if (cleaned.isEmpty) return;
    try {
      // Nobody signed in yet, which used to mean the report was simply lost.
      //
      // That blind spot covered the sign-in screen — the first thing every new
      // person sees, and the one place a crash costs you the user entirely. A
      // tester saying "it will not open" produced no row, which is
      // indistinguishable from nothing having gone wrong.
      //
      // The table still refuses anonymous writes. This goes through an RPC
      // that decides what it accepts: fixed services, a truncated message, one
      // row per repeated crash per ten minutes, and a ceiling per hour. See
      // migration 0040.
      if (_client.auth.currentSession == null) {
        await _client.rpc<void>('report_anonymous_error', params: <String, dynamic>{
          'in_service': service,
          'in_message': cleaned.length > 2000 ? cleaned.substring(0, 2000) : cleaned,
          'in_stage': stage,
          'in_severity': severity,
          'in_app_version': BetaConfig.fullVersion,
          'in_platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
        });
        return;
      }

      try {
        await _authenticatedInsert(
          severity: severity,
          service: service,
          message: cleaned,
          stage: stage,
          projectId: projectId,
          route: where,
        );
      } catch (error) {
        // The suspected shape of the five-day silence: the row is refused for
        // this account — row-level security, or the `user_id -> profiles`
        // foreign key on somebody who signed up but has no profile row yet —
        // and the report is lost for the one reason the table can never show,
        // because the loss happens before there is a row to show it in.
        //
        // The anonymous route was built for the sign-in screen and accepts
        // exactly this: it is `security definer`, it takes no user, and
        // `authenticated` has always been able to call it. It costs the
        // route, the session and the project, so those go into the message
        // where nothing else can drop them.
        await _client.rpc<void>(
          'report_anonymous_error',
          params: <String, dynamic>{
            'in_service': service,
            'in_message': _withLostContext(
              cleaned,
              route: where,
              projectId: projectId,
              because: error,
            ),
            'in_stage': stage,
            'in_severity': severity,
            'in_app_version': BetaConfig.fullVersion,
            'in_platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
          },
        );
      }
    } catch (error) {
      // Both routes are gone — offline, or the function itself is missing.
      // Nothing is thrown, because telemetry must never break the thing it is
      // watching; but it is counted, because a report that vanished without
      // leaving so much as a number behind is how this became unanswerable in
      // the first place. See [TelemetryHealth].
      TelemetryHealth.reportFailed(error);
    }
  }

  Future<void> _authenticatedInsert({
    required String severity,
    required String service,
    required String message,
    required String? stage,
    required String? projectId,
    required String route,
  }) async {
    await _client.from('analysis_errors').insert(<String, dynamic>{
        'severity': severity,
        'service': service,
        'stage': stage,
        // Capped well above a normal message but below the point where one
        // pathological stack trace dominates the table. The signature the
        // trigger derives keeps both ends of long messages, so truncating
        // here would cost the most diagnostic part.
        'message': message.length > 8000 ? message.substring(0, 8000) : message,
        'project_id': projectId,
        'route': route,
        // Which run of the app this came from. A join on time would be
        // guesswork — sessions overlap, a phone can run two builds in a day,
        // and a background upload finishing an hour later is not part of the
        // session that began it.
        'session_id': AppSession.id,
        'app_version': BetaConfig.fullVersion,
        'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
    });
  }

  /// What the anonymous route cannot carry in its own columns.
  ///
  /// Folded into the message rather than dropped, because a fallback report
  /// that has lost the screen it happened on is most of the way back to no
  /// report at all — and the reason the first route refused is the single
  /// most useful sentence in the whole row.
  static String _withLostContext(
    String message, {
    required String route,
    String? projectId,
    required Object because,
  }) {
    final head = StringBuffer('[fallback route=$route');
    if (projectId != null) head.write(' project=$projectId');
    head.write(' session=${AppSession.id}');
    head.write('] direct insert refused: ');
    head.write(because.toString().split('\n').first.trim());
    head.write('\n');
    final prefixed = '$head$message';
    return prefixed.length > 2000 ? prefixed.substring(0, 2000) : prefixed;
  }
}
