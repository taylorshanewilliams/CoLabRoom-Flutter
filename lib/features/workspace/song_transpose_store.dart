import 'package:shared_preferences/shared_preferences.dart';

/// The key somebody plays a song in, remembered on this device.
///
/// Transposing a song reset the moment you left it, and Perform never read
/// it at all: a singer who moved a song down two to fit their voice got the
/// original chords back on stage (audit, 17 September 2026). So it is kept
/// per song, and the sheet, the chart and Perform all start from it.
///
/// Personal, deliberately, like SongLevelStore. The key you need is about
/// your voice or your capo, not the song, so it is never written to the room
/// and never carried by Follow me: a leader who plays in A does not move a
/// follower who reads in G.
///
/// Fail-safe both ways. A preferences store that will not open means the
/// song opens in its own key, which is what it did before any of this.
abstract final class SongTransposeStore {
  static String _key(String projectId) => 'song_transpose_$projectId';

  /// Eleven semitones either way; twelve is the same key again.
  static const int limit = 11;

  static Future<int> load(String projectId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getInt(_key(projectId)) ?? 0).clamp(-limit, limit);
    } catch (_) {
      return 0;
    }
  }

  static Future<void> save(String projectId, int semitones) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = semitones.clamp(-limit, limit);
      // The original key is the absence of a choice, so it is stored as
      // nothing rather than as a zero kept forever for every song opened.
      if (value == 0) {
        await prefs.remove(_key(projectId));
      } else {
        await prefs.setInt(_key(projectId), value);
      }
    } catch (_) {
      // Not remembered this time; the sheet on screen is still right.
    }
  }
}
