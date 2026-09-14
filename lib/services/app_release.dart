import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app/beta_config.dart';
import 'user_facing_error.dart';

/// Whether the build on this phone is older than the app now is.
///
/// On 13 September 2026 both iPhones in the band were on 0.4.0 while the
/// Android phone was on 0.4.1, and the three of them were, in every way that
/// mattered, using two different apps: one had friends and a People screen,
/// two had never heard of either. TestFlight had the newer build for three
/// days. Nobody knew.
///
/// The server holds one number — the oldest version that still matches
/// everybody else — and this asks for it once per launch. Below it, Your
/// music draws one card. Nothing is blocked: a build that is behind still
/// works, it just says so.
abstract final class AppRelease {
  /// The oldest version the server still considers current, once known.
  ///
  /// Null until the answer arrives, and null forever in a build with no
  /// server — the preview, the tests, the web build, which is always the
  /// newest by construction.
  static final ValueNotifier<String?> minimum = ValueNotifier<String?>(null);

  /// True when this build should ask to be updated.
  static bool get isStale {
    final oldest = minimum.value;
    return oldest != null && isOlder(BetaConfig.appVersion, oldest);
  }

  /// Asks the server, once. Failing to find out is a warning, not a problem
  /// anybody is shown: the answer is worth having and the app is fine
  /// without it.
  static Future<void> check() async {
    // A browser reloads the newest build every time; there is nothing to
    // update and no store to update it from.
    if (kIsWeb) return;
    try {
      final answer = await Supabase.instance.client
          .rpc<dynamic>('minimum_app_version');
      final text = answer?.toString().trim();
      minimum.value = text == null || text.isEmpty ? null : text;
    } catch (error) {
      reportWarningAndDescribe(error, service: 'app', stage: 'release.check');
    }
  }

  /// Whether [version] is older than [than], read as dotted numbers.
  ///
  /// Anything that does not parse is treated as current: an unreadable
  /// version string is a bug to fix in the string, not a reason to nag every
  /// phone in the product.
  static bool isOlder(String version, String than) {
    final a = _parts(version);
    final b = _parts(than);
    if (a == null || b == null) return false;
    final length = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < length; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x < y;
    }
    return false;
  }

  static List<int>? _parts(String version) {
    final clean = version.trim().split(RegExp(r'[+\s(]')).first;
    if (clean.isEmpty) return null;
    final parts = <int>[];
    for (final piece in clean.split('.')) {
      final number = int.tryParse(piece);
      if (number == null) return null;
      parts.add(number);
    }
    return parts;
  }

  /// What to actually do, on this kind of phone.
  ///
  /// There is no store listing yet, so Android cannot be sent anywhere; the
  /// sentence has to be honest about that rather than name a button that
  /// does not exist.
  static String get howToUpdate {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      return 'Open the TestFlight app, find CoLabRoom and tap Update.';
    }
    return 'Install the newest CoLabRoom build, then open it again.';
  }

  @visibleForTesting
  static void reset() => minimum.value = null;
}
