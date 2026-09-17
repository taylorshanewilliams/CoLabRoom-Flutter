import 'package:flutter/foundation.dart';
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
  static const String _prefix = 'song_transpose_';

  static String _key(String projectId) => '$_prefix$projectId';

  /// Eleven semitones either way; twelve is the same key again.
  static const int limit = 11;

  /// Every kept key this session knows, so Home can name a chord in your key
  /// while it draws instead of waiting on a disk read.
  ///
  /// Home's Tonight card suggested "Try Em" on a song whose sheet now opens
  /// in A, where the same move is F#m (review, 17 September 2026). The card
  /// is built in the middle of a build, so it reads from here.
  static final Map<String, int> _held = <String, int>{};

  static final ValueNotifier<int> _changes = ValueNotifier<int>(0);

  static Future<void>? _warming;

  /// Ticks whenever a kept key changes, so a card on screen beside the song
  /// (a desk shows both) follows the transpose buttons.
  static ValueListenable<int> get changes => _changes;

  /// The kept transpose for [projectId] as far as this session knows: zero
  /// until [warm] has read it back or this session has saved one.
  static int held(String projectId) => _held[projectId] ?? 0;

  /// Reads every kept key back, once.
  static Future<void> warm() => _warming ??= _readAll();

  static Future<void> _readAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var changed = false;
      for (final name in prefs.getKeys()) {
        if (!name.startsWith(_prefix)) continue;
        final projectId = name.substring(_prefix.length);
        final value = prefs.get(name);
        // A key chosen this session, before the read came back, is newer
        // than what is on disk.
        if (value is! int || _held.containsKey(projectId)) continue;
        _held[projectId] = value.clamp(-limit, limit);
        changed = true;
      }
      if (changed) _changes.value++;
    } catch (_) {
      // Nothing read back: Home names chords in each song's own key.
    }
  }

  static Future<int> load(String projectId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getInt(_key(projectId)) ?? 0).clamp(-limit, limit);
    } catch (_) {
      return 0;
    }
  }

  static Future<void> save(String projectId, int semitones) async {
    final value = semitones.clamp(-limit, limit);
    // Held before the write, so this session agrees with the sheet on screen
    // even when the disk does not take it.
    if (_held[projectId] != value) {
      _held[projectId] = value;
      _changes.value++;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
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

  @visibleForTesting
  static void resetForTesting() {
    _held.clear();
    _warming = null;
  }
}
