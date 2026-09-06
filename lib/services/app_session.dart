import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app/beta_config.dart';

/// One run of the app, from launch to whenever it stops.
///
/// The denominator. Every error count this project has ever produced is an
/// absolute — 36 errors means nothing without knowing whether that was across
/// ten sessions or ten thousand, and a bad release looks exactly like a busy
/// week. A rate needs something to divide by.
///
/// The id is made on the phone, before anything else happens, and that is the
/// point: the first thing a session has to be able to do is own a crash that
/// occurs before any request succeeds. An id assigned by the server would be
/// null for precisely the sessions worth counting.
abstract final class AppSession {
  static final String id = _newId();

  /// Whether the row for this session reached the server.
  ///
  /// Read only by tests and by the reporter's own diagnostics. A session that
  /// failed to register still stamps its id on every error it produces — the
  /// row can be reconciled later, and an orphaned id is far more useful than
  /// no id.
  static bool registered = false;

  static String _newId() {
    // 32 hex characters from a secure source. Not a UUID because nothing here
    // needs the version bits, and a text column avoids a cast on a value the
    // client invents.
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < 32; i += 1) {
      buffer.write(random.nextInt(16).toRadixString(16));
    }
    return buffer.toString();
  }

  /// Records that the app started.
  ///
  /// Fire-and-forget and failure-tolerant, like everything else on this path.
  /// A session that cannot be recorded must not stop the app from running —
  /// the cost is one missing denominator, and the alternative is an app that
  /// will not open because its analytics could not.
  static Future<void> start() async {
    if (!BetaConfig.hasSupabase) return;
    try {
      final client = Supabase.instance.client;
      // Anonymous launches are not recorded. The row is keyed to a person by
      // RLS, and a session with no user is a row nothing can ever read back —
      // the sign-in screen's own failures are covered by the anonymous error
      // path in 0040 instead.
      if (client.auth.currentSession == null) return;
      await client.from('app_sessions').insert(<String, dynamic>{
        'id': id,
        'app_version': BetaConfig.appVersion,
        'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
      });
      registered = true;
    } catch (error) {
      if (kDebugMode) debugPrint('Session not recorded: $error');
    }
  }
}
