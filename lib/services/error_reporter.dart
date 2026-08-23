import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app/beta_config.dart';

/// Records analysis failures and degradations into `analysis_errors` so they
/// can be counted instead of discovered one screenshot at a time.
///
/// Warnings are reported as well as errors, and matter more than they look.
/// When a stage degrades — cloud chord detection falling back to the
/// on-device heuristic, lyrics giving up on an unclear vocal — the analysis
/// still completes and the user still gets a result, just a materially worse
/// one. Those runs are invisible in any success/failure metric, which is
/// exactly why they need their own signal.
class ErrorReporter {
  ErrorReporter({SupabaseClient? client}) : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

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
