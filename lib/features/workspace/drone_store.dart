import 'package:shared_preferences/shared_preferences.dart';

/// How somebody likes their drone, remembered on this device.
///
/// Personal, like every other thing about how a song sounds to one person in
/// the room: a singer who keeps a tanpura under everything and a guitarist who
/// wants nothing are both right, and neither should be able to put a tone in
/// anybody else's ears (Every Musician, Same Song, 17 September 2026). It is
/// never written to the room and never carried by Follow me.
///
/// Two answers only: how loud, and whether the fifth is on. Which note it
/// sounds is not kept — it starts from the song's own 1 every time, because a
/// note picked for one song is nothing to do with the next one.
///
/// One device, no account, and a store that will not open means the drone is
/// at its ordinary level with no fifth, which is what somebody would get the
/// first time anyway.
abstract final class DroneStore {
  static const String _levelKey = 'drone_level';
  static const String _fifthKey = 'drone_fifth';

  /// Levels are kept as whole steps out of a hundred, which is what the slider
  /// moves in and what a preference can hold without a decimal point.
  static const int defaultLevel = 55;

  static Future<DroneSettings> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return DroneSettings(
        level: (prefs.getInt(_levelKey) ?? defaultLevel).clamp(0, 100),
        fifth: prefs.getBool(_fifthKey) ?? false,
      );
    } catch (_) {
      return const DroneSettings();
    }
  }

  static Future<void> save(DroneSettings settings) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // The ordinary answers are the absence of a choice, so they are stored
      // as nothing rather than as a row kept forever.
      if (settings.level == defaultLevel) {
        await prefs.remove(_levelKey);
      } else {
        await prefs.setInt(_levelKey, settings.level.clamp(0, 100));
      }
      if (!settings.fifth) {
        await prefs.remove(_fifthKey);
      } else {
        await prefs.setBool(_fifthKey, true);
      }
    } catch (_) {
      // Not remembered this time; the drone sounding now is still right.
    }
  }
}

/// How loud the drone is and whether it has its fifth.
class DroneSettings {
  const DroneSettings({
    this.level = DroneStore.defaultLevel,
    this.fifth = false,
  });

  /// 0 to 100. The slider moves in tens and nothing shows the number: how loud
  /// a drone is under your own voice is a thing you hear, not a reading.
  final int level;

  /// Whether a just fifth sounds over the note — a tanpura's Pa, and the
  /// second note of a pitch pipe.
  final bool fifth;

  /// What the player wants: 0 to 1.
  double get volume => level.clamp(0, 100) / 100;

  DroneSettings copyWith({int? level, bool? fifth}) => DroneSettings(
        level: level ?? this.level,
        fifth: fifth ?? this.fifth,
      );

  @override
  bool operator ==(Object other) =>
      other is DroneSettings && other.level == level && other.fifth == fifth;

  @override
  int get hashCode => Object.hash(level, fifth);
}
