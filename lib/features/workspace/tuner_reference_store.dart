import 'package:shared_preferences/shared_preferences.dart';

/// What the tuner calls A, remembered on this device.
///
/// 440 is the default and what nearly everybody tunes to, but it is a
/// convention rather than a fact: baroque ensembles play at 415, a lot of
/// European orchestras sit at 442, and a player who has to fit in with one of
/// them should not have to hear their tuner call them sharp all evening
/// (Every Musician, Same Song, 17 September 2026).
///
/// One number, one device, no account: the same shape as the count-in
/// preference beside it. A store that will not open means A is 440, which is
/// what the tuner did before any of this.
abstract final class TunerReferenceStore {
  static const String _key = 'tuner_a4_hz';

  static const int lowest = 415;
  static const int highest = 446;
  static const int standard = 440;

  static Future<int> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getInt(_key) ?? standard).clamp(lowest, highest);
    } catch (_) {
      return standard;
    }
  }

  static Future<void> save(int hz) async {
    final value = hz.clamp(lowest, highest);
    try {
      final prefs = await SharedPreferences.getInstance();
      // 440 is the absence of a choice, so it is stored as nothing.
      if (value == standard) {
        await prefs.remove(_key);
      } else {
        await prefs.setInt(_key, value);
      }
    } catch (_) {
      // Not remembered this time; the tuner on screen is still right.
    }
  }
}
