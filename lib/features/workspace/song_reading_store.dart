import 'package:flutter/foundation.dart';
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

  /// Every kept reading this session knows, so Home can name a chord the way
  /// the sheet will while it draws instead of waiting on a disk read.
  ///
  /// The same trio as SongTransposeStore, for the same bug: Home's Tonight
  /// card is built in the middle of a build, and without this it suggested a
  /// chord in the concert key on a song whose sheet opens in the trumpet's
  /// (review, 17 September 2026).
  static final Map<String, HornReading> _held = <String, HornReading>{};

  static final ValueNotifier<int> _changes = ValueNotifier<int>(0);

  static Future<void>? _warming;

  /// Ticks whenever a kept reading changes, so a card on screen beside the
  /// song follows the Read as choice.
  static ValueListenable<int> get changes => _changes;

  /// The kept reading for [projectId] as far as this session knows: concert
  /// until [warm] has read it back or this session has saved one.
  static HornReading held(String projectId) =>
      _held[projectId] ?? HornReading.concert;

  /// Reads every kept reading back, once.
  static Future<void> warm() => _warming ??= _readAll();

  static Future<void> _readAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var changed = false;
      for (final name in prefs.getKeys()) {
        if (!name.startsWith(_prefix)) continue;
        final projectId = name.substring(_prefix.length);
        final value = prefs.get(name);
        // A reading chosen this session, before the read came back, is newer
        // than what is on disk.
        if (value is! String || _held.containsKey(projectId)) continue;
        final reading = HornReading.fromStored(value);
        if (reading == HornReading.concert) continue;
        _held[projectId] = reading;
        changed = true;
      }
      if (changed) _changes.value++;
    } catch (_) {
      // Nothing read back: Home names chords in each song's own key.
    }
  }

  static Future<HornReading> load(String projectId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return HornReading.fromStored(prefs.getString(_key(projectId)));
    } catch (_) {
      return HornReading.concert;
    }
  }

  static Future<void> save(String projectId, HornReading reading) async {
    // Held before the write, so this session agrees with the sheet on screen
    // even when the disk does not take it.
    if (held(projectId) != reading) {
      _held[projectId] = reading;
      _changes.value++;
    }
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

  @visibleForTesting
  static void resetForTesting() {
    _held.clear();
    _warming = null;
  }
}
