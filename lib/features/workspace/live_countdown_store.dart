import 'package:shared_preferences/shared_preferences.dart';

/// Persists the Live Performance "count-in" preference locally on-device —
/// a personal setup habit (how long a band wants to get ready before the
/// scroll/sync starts), not data that needs to sync across devices.
abstract final class LiveCountdownStore {
  static const _enabledKey = 'live_countdown_enabled';
  static const _secondsKey = 'live_countdown_seconds';
  static const defaultSeconds = 5;

  static Future<(bool enabled, int seconds)> load() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_enabledKey) ?? false;
    final seconds = (prefs.getInt(_secondsKey) ?? defaultSeconds).clamp(3, 10);
    return (enabled, seconds);
  }

  static Future<void> save({required bool enabled, required int seconds}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
    await prefs.setInt(_secondsKey, seconds.clamp(3, 10));
  }
}
