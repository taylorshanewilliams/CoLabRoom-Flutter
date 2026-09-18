import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/horn_reading.dart';
import '../../services/number_reading.dart';

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

/// Where somebody has put a capo for a song, remembered on this device.
///
/// A capo is the guitarist's answer to the same question the transpose
/// answers: this key is awkward under the hand, so play the shapes that are
/// not. The shapes move and the band does not hear anything change, which is
/// what makes it personal — nobody else in the room is affected by where your
/// capo is (Every Musician, Same Song, 17 September 2026).
///
/// No held-and-warmed copy, unlike its two siblings. Those exist because
/// Home's Tonight card names a chord and has to name it in the key the sheet
/// will open in; a capo does not change what key the song is in, so nothing
/// outside the song's own page has a reason to read it.
abstract final class SongCapoStore {
  static const String _prefix = 'song_capo_';

  static String _key(String projectId) => '$_prefix$projectId';

  /// Eleven frets. Twelve is the same shapes an octave up, which no guitar
  /// has room for and nobody plays.
  static const int limit = 11;

  static Future<int> load(String projectId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final kept = prefs.getInt(_key(projectId)) ?? 0;
      return kept.clamp(0, limit).toInt();
    } catch (_) {
      return 0;
    }
  }

  static Future<void> save(String projectId, int capo) async {
    final within = capo.clamp(0, limit).toInt();
    try {
      final prefs = await SharedPreferences.getInstance();
      // No capo is the absence of a choice, so it is stored as nothing rather
      // than as a row kept forever for every song ever opened.
      if (within == 0) {
        await prefs.remove(_key(projectId));
      } else {
        await prefs.setInt(_key(projectId), within);
      }
    } catch (_) {
      // Not remembered this time; the sheet on screen is still right.
    }
  }
}

/// Whether somebody reads a song in letters, numbers or numerals, remembered
/// on this device.
///
/// Per song, like the other readings, so the country player who reads one
/// band's material in numbers and their own songs in letters gets both. The
/// minor convention beside it is not per song — see [MinorNumbersStore].
abstract final class SongNumbersStore {
  static const String _prefix = 'song_numbers_';

  static String _key(String projectId) => '$_prefix$projectId';

  static Future<NumberStyle> load(String projectId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return NumberStyle.fromStored(prefs.getString(_key(projectId)));
    } catch (_) {
      return NumberStyle.letters;
    }
  }

  static Future<void> save(String projectId, NumberStyle style) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (style == NumberStyle.letters) {
        await prefs.remove(_key(projectId));
      } else {
        await prefs.setString(_key(projectId), style.stored);
      }
    } catch (_) {
      // Not remembered this time; the sheet on screen is still right.
    }
  }
}

/// Which note this person counts a minor song from.
///
/// One setting for the whole app rather than one per song: somebody who reads
/// 6- reads 6- everywhere, and being asked the same question again on the
/// next song would be asking them what they read in, which they already
/// answered.
abstract final class MinorNumbersStore {
  static const String _key = 'minor_numbers';

  static Future<MinorNumbers> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return MinorNumbers.fromStored(prefs.getString(_key));
    } catch (_) {
      return MinorNumbers.relativeMajor;
    }
  }

  static Future<void> save(MinorNumbers convention) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (convention == MinorNumbers.relativeMajor) {
        await prefs.remove(_key);
      } else {
        await prefs.setString(_key, convention.stored);
      }
    } catch (_) {
      // Not remembered this time; the sheet on screen is still right.
    }
  }
}
