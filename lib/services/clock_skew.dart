import 'dart:async';

import 'package:http/http.dart' as http;

import '../app/beta_config.dart';
import 'error_reporter.dart';

/// How far this phone's clock is from the server's, measured rather than
/// assumed.
///
/// "JWT issued at future" (PGRST303) was read, in September 2026, as "the
/// phone's clock is ahead" and the sentence on screen said so. Then it
/// happened on an emulator whose clock was eight seconds *behind* the host.
/// The skew that matters is between the server that mints a token and the
/// server that checks it, or the phone and either -- and nobody can tell
/// which from a phone that has not looked at a clock other than its own.
/// This looks: one HEAD request, the `Date` header, the difference. Filed
/// beside the error as a warning, so the next report says which clock.
class ClockSkew {
  const ClockSkew._();

  /// The server's idea of now, from the `Date` header of a request that
  /// costs nothing. Null when it cannot be read -- offline, or a proxy that
  /// strips the header.
  static Future<DateTime?> serverTime({Future<http.Response> Function(Uri)? head}) async {
    final url = BetaConfig.supabaseUrl.trim();
    if (url.isEmpty) return null;
    try {
      final response = await (head ?? http.head)(Uri.parse('$url/auth/v1/health'))
          .timeout(const Duration(seconds: 8));
      final date = response.headers['date'];
      if (date == null) return null;
      return parseHttpDate(date);
    } catch (_) {
      return null;
    }
  }

  /// Phone minus server. Positive means the phone is ahead.
  static Future<Duration?> measure({
    Future<DateTime?> Function()? server,
    DateTime Function()? now,
  }) async {
    final theirs = await (server ?? serverTime)();
    if (theirs == null) return null;
    return (now ?? DateTime.now)().toUtc().difference(theirs.toUtc());
  }

  /// One sentence about the skew, for a report or a screen.
  static String describe(Duration skew) {
    final seconds = skew.inSeconds;
    if (seconds.abs() < 2) return 'This phone\'s clock agrees with the server\'s.';
    final how = seconds > 0 ? 'ahead of' : 'behind';
    return 'This phone\'s clock is ${seconds.abs()} s $how the server\'s.';
  }

  /// Measures and files the answer as a warning next to the error that asked
  /// for it. Best-effort: a diagnosis must not become a second failure.
  static Future<void> report({
    ErrorReporter? reporter,
    String? route,
    Future<DateTime?> Function()? server,
  }) async {
    try {
      final skew = await measure(server: server);
      await (reporter ?? ErrorReporter()).reportWarning(
        service: 'app',
        stage: 'clock_skew',
        message: skew == null ? 'Could not read the server\'s clock.' : describe(skew),
        route: route,
      );
    } catch (_) {
      // Nothing to do; the error this was filed beside is already there.
    }
  }

  /// RFC 7231 dates, the only shape a `Date` header takes:
  /// `Sun, 14 Sep 2026 19:13:53 GMT`.
  static DateTime? parseHttpDate(String value) {
    final match = RegExp(
      r'^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
    ).firstMatch(value.trim());
    if (match == null) return null;
    const months = <String>['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final month = months.indexOf(match.group(2)!) + 1;
    if (month == 0) return null;
    return DateTime.utc(
      int.parse(match.group(3)!),
      month,
      int.parse(match.group(1)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6)!),
    );
  }
}
