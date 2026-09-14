import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/set_aside.dart';

/// Somebody who was busy when the app asked them to play.
///
/// The first thing the app now asks a new person to do is record twenty
/// seconds, because the sheet coming back over their own words is the best
/// minute the app has. Taylor, on the same afternoon: "what if someone wants
/// to check the app out, but is busy and cant record at that moment." So
/// "Not now" is a real answer, and this is what it costs: nothing today, and
/// one card on the next launch saying the offer still stands.
///
/// Three rules keep it from being a nag. It never appears in the session
/// where "not now" was said -- that person asked to look around, so they
/// look around. It disappears by itself the moment there is any recording
/// at all. And its x is remembered on the device for good, through
/// [SetAside], because a reminder somebody closed is a reminder they read.
abstract final class PlayLater {
  static const String _skippedKey = 'welcome_record_skipped_at';

  /// True from the moment "not now" is tapped until the app is next opened.
  static bool skippedThisSession = false;

  static int? _skippedAt;
  static bool _loaded = false;

  /// Read once, before the strip first draws.
  static Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _skippedAt = prefs.getInt(_skippedKey);
    } catch (_) {
      // A preference that cannot be read is a card that does not appear,
      // which is the harmless side of this.
    }
    _loaded = true;
  }

  static Future<void> markSkipped() async {
    skippedThisSession = true;
    _skippedAt = DateTime.now().millisecondsSinceEpoch;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_skippedKey, _skippedAt!);
    } catch (_) {
      // See load.
    }
  }

  /// Whether the card belongs on the strip right now.
  static bool shouldRemind({required bool hasAnyRecording}) {
    if (_skippedAt == null || skippedThisSession || hasAnyRecording) {
      return false;
    }
    return !SetAside.has(SetAside.playLater, 'first');
  }

  @visibleForTesting
  static void reset() {
    skippedThisSession = false;
    _skippedAt = null;
    _loaded = false;
  }
}
