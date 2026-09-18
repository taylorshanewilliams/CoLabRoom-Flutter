import 'package:shared_preferences/shared_preferences.dart';

import '../../services/horn_reading.dart';

/// Which instrument somebody reads a song for, remembered on this device.
///
/// The sibling of SongTransposeStore, and personal for the same reason: what
/// you read a song in is about the instrument in your hands, not about the
/// song. It is never written to the room and never carried by Follow me, so a
/// trumpet player reading in E and a guitarist reading in D can follow the
/// same leader through the same song (Every Musician, Same Song, 17 September
/// 2026).
///
/// It stacks on the transpose rather than replacing it: a singer's capo key
/// and a horn's written key are two different answers to two different
/// questions, and a horn player in a band that plays a song down two still
/// needs it down two.
///
/// Fail-safe, like the transpose: a preferences store that will not open
/// means the song reads in concert pitch, which is what it did before any of
/// this.
abstract final class SongReadingStore {
  static const String _prefix = 'song_reading_';

  static String _key(String projectId) => '$_prefix$projectId';

  static Future<HornReading> load(String projectId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return HornReading.fromStored(prefs.getString(_key(projectId)));
    } catch (_) {
      return HornReading.concert;
    }
  }

  static Future<void> save(String projectId, HornReading reading) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Concert pitch is the absence of a choice, so it is stored as nothing
      // rather than as a row kept forever for every song ever opened.
      if (reading == HornReading.concert) {
        await prefs.remove(_key(projectId));
      } else {
        await prefs.setString(_key(projectId), reading.stored);
      }
    } catch (_) {
      // Not remembered this time; the sheet on screen is still right.
    }
  }
}
