import 'package:shared_preferences/shared_preferences.dart';

/// How loud the song itself is, while somebody plays along to it.
///
/// Local and per person, deliberately. Every other level on the takes screen
/// is shared — a fader belongs to whoever recorded that take, and everybody
/// hears where they put it. This one is not a take. It is the record you are
/// playing against, and how loud you need it depends on your headphones, your
/// room and how loudly you sing, none of which the rest of the band should
/// inherit.
///
/// It exists because there was no way to turn the song down at all. A take
/// recorded on a phone sits well below a mastered mix, and layer gain is
/// capped at 2.0 in the database, so lifting the take could never rescue it.
/// The person could hear their part alone and could not hear it in the mix,
/// and nothing on the screen would have fixed that.
abstract final class SongLevelStore {
  static String _key(String projectId) => 'song_level_$projectId';

  /// Above 1.0 as well as below. Somebody wearing headphones over a quiet
  /// phone speaker may want the record louder, not only quieter.
  static const double min = 0;
  static const double max = 1.5;

  static Future<double> load(String projectId) async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getDouble(_key(projectId)) ?? 1.0).clamp(min, max);
  }

  static Future<void> save(String projectId, double level) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_key(projectId), level.clamp(min, max));
  }
}
