import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app/beta_config.dart';

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
  }) {
    return _report(
      severity: 'error',
      service: service,
      message: message,
      stage: stage,
      projectId: projectId,
    );
  }

  Future<void> reportWarning({
    required String service,
    required String message,
    String? stage,
    String? projectId,
  }) {
    return _report(
      severity: 'warning',
      service: service,
      message: message,
      stage: stage,
      projectId: projectId,
    );
  }

  Future<void> _report({
    required String severity,
    required String service,
    required String message,
    String? stage,
    String? projectId,
  }) async {
    final cleaned = message.trim();
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
          'in_app_version': BetaConfig.appVersion,
          'in_platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
        });
        return;
      }

      await _client.from('analysis_errors').insert(<String, dynamic>{
        'severity': severity,
        'service': service,
        'stage': stage,
        // Capped well above a normal message but below the point where one
        // pathological stack trace dominates the table. The signature the
        // trigger derives keeps both ends of long messages, so truncating
        // here would cost the most diagnostic part.
        'message': cleaned.length > 8000 ? cleaned.substring(0, 8000) : cleaned,
        'project_id': projectId,
        'app_version': BetaConfig.appVersion,
        'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
      });
    } catch (_) {
      // Telemetry must never break the thing it is watching. A failed report
      // is strictly less bad than an analysis that dies while recording that
      // something else died.
    }
  }
}
