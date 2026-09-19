import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/horn_reading.dart';
import '../../services/melody_reading.dart';
import '../../services/number_reading.dart';
import '../../services/shape_reading.dart';

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

/// Which language somebody reads the sung notes in, remembered on this
/// device.
///
/// Per song, like the other readings: the same person can read their own
/// songs in letters and the ones they are learning in sargam. Never written
/// to the room and never carried by Follow me — a class following one teacher
/// can be reading the same tune in five languages at once (Every Musician,
/// Same Song, 17 September 2026).
abstract final class MelodyReadingStore {
  static const String _prefix = 'melody_reading_';

  static String _key(String projectId) => '$_prefix$projectId';

  static Future<MelodyReading> load(String projectId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return MelodyReading.fromStored(prefs.getString(_key(projectId)));
    } catch (_) {
      return MelodyReading.letters;
    }
  }

  static Future<void> save(String projectId, MelodyReading reading) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Letters are the absence of a choice, so they are stored as nothing
      // rather than as a row kept forever for every song ever opened.
      if (reading == MelodyReading.letters) {
        await prefs.remove(_key(projectId));
      } else {
        await prefs.setString(_key(projectId), reading.stored);
      }
    } catch (_) {
      // Not remembered this time; the sheet on screen is still right.
    }
  }
}

/// Where this person counts the sung notes from, when it is not the song's
/// own key — Sa, in sargam's word for it. A pitch class, 0 for C up to 11.
///
/// Personal and per song, like the reading it belongs to. A singer who keeps
/// a tanpura on C♯ reads the tune against C♯ whatever key the band put the
/// recording in, and nobody else in the room sees anything change: where the
/// 1 is *for the room* is a shared fact, set from "Where the 1 is" and kept
/// on the song (Every Musician, Same Song, 17 September 2026).
abstract final class MelodySaStore {
  static const String _prefix = 'melody_sa_';

  static String _key(String projectId) => '$_prefix$projectId';

  /// The kept Sa, or null for the song's own key.
  static Future<int?> load(String projectId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final kept = prefs.getInt(_key(projectId));
      // A value this version cannot read is no answer at all, and the song's
      // own key is the honest fallback.
      if (kept == null || kept < 0 || kept > 11) return null;
      return kept;
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(String projectId, int? sa) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (sa == null || sa < 0 || sa > 11) {
        await prefs.remove(_key(projectId));
      } else {
        await prefs.setInt(_key(projectId), sa);
      }
    } catch (_) {
      // Not remembered this time; the sheet on screen is still right.
    }
  }
}

/// Whether this person is shown the plain chord inside an extended one.
///
/// One setting for the whole app rather than one per song, like the minor
/// convention below it and for the same reason: a hand that cannot make a
/// Cmaj7 tonight cannot make one in the next song either, and being asked
/// again on every song would be asking somebody what their hands can do
/// (Every Musician, Same Song, 17 September 2026).
///
/// Held as well as stored, because the sheet a chord opens is built in the
/// frame the chord is tapped in and cannot wait on a disk read. Off until a
/// read says otherwise, which is what every chord sheet did before this.
abstract final class SimplerShapesStore {
  static const String _key = 'simpler_shapes';

  static bool _held = false;
  static Future<void>? _warming;

  /// What this session knows: false until [warm] has read it back or this
  /// session has saved a choice.
  static bool get held => _held;

  /// Reads the choice back, once.
  static Future<void> warm() => _warming ??= _read();

  static Future<void> _read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _held = prefs.getBool(_key) ?? false;
    } catch (_) {
      // Nothing read back: chords are drawn the way they are written.
    }
  }

  static Future<bool> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_key) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> save(bool on) async {
    // Held before the write, so the next chord tapped agrees with the chip
    // that was just pressed even when the disk does not take it.
    _held = on;
    try {
      final prefs = await SharedPreferences.getInstance();
      // Off is the absence of a choice, stored as nothing.
      if (on) {
        await prefs.setBool(_key, true);
      } else {
        await prefs.remove(_key);
      }
    } catch (_) {
      // Not remembered this time; the sheet on screen is still right.
    }
  }

  @visibleForTesting
  static void resetForTesting() {
    _held = false;
    _warming = null;
  }
}

/// Which instrument this person is shown a chord's shape for.
///
/// One setting for the whole app rather than one per song, like Simpler shapes
/// above it: the instrument in somebody's hands is the same instrument in the
/// next song, and asking again on every song would be asking them what they
/// play (Every Musician, Same Song, 17 September 2026).
///
/// Held as well as stored, for the same reason Simpler shapes is: the sheet a
/// chord opens is built in the frame the chord is tapped in and cannot wait on
/// a disk read. It also ticks [changes], because a capo means nothing to a
/// pianist — the page takes the capo back off when the shapes being read are
/// not a fretted instrument's, and it has to hear about the choice to do it.
abstract final class ShapeReadingStore {
  static const String _key = 'shape_reading';

  static ShapeReading _held = ShapeReading.guitar;
  static final ValueNotifier<int> _changes = ValueNotifier<int>(0);
  static Future<void>? _warming;

  /// Ticks whenever the choice changes, so a page already on screen follows.
  static ValueListenable<int> get changes => _changes;

  /// What this session knows: the guitar until [warm] has read a choice back
  /// or this session has saved one.
  static ShapeReading get held => _held;

  /// Reads the choice back, once.
  static Future<void> warm() => _warming ??= _read();

  static Future<void> _read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final reading = ShapeReading.fromStored(prefs.getString(_key));
      if (reading == _held) return;
      _held = reading;
      _changes.value++;
    } catch (_) {
      // Nothing read back: chords are drawn for a guitar, which is what they
      // were drawn for before any of this.
    }
  }

  static Future<ShapeReading> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return ShapeReading.fromStored(prefs.getString(_key));
    } catch (_) {
      return ShapeReading.guitar;
    }
  }

  static Future<void> save(ShapeReading reading) async {
    // Held before the write, so the next chord tapped agrees with the chip
    // that was just pressed even when the disk does not take it.
    if (_held != reading) {
      _held = reading;
      _changes.value++;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      // The guitar is the absence of a choice, stored as nothing.
      if (reading == ShapeReading.guitar) {
        await prefs.remove(_key);
      } else {
        await prefs.setString(_key, reading.stored);
      }
    } catch (_) {
      // Not remembered this time; the sheet on screen is still right.
    }
  }

  @visibleForTesting
  static void resetForTesting() {
    _held = ShapeReading.guitar;
    _warming = null;
  }
}

/// Whether this person reads a neck the other way round.
///
/// One setting for the whole app and never a question asked per song: which
/// hand somebody frets with is not a property of a song, and asking again
/// would be asking them what their hands are (Every Musician, Same Song, 17
/// September 2026). Nothing is inferred either — it is chosen or it is absent.
///
/// Held as well as stored, like the reading above it.
abstract final class LeftHandedStore {
  static const String _key = 'left_handed_shapes';

  static bool _held = false;
  static Future<void>? _warming;

  /// What this session knows: false until [warm] has read it back or this
  /// session has saved a choice.
  static bool get held => _held;

  /// Reads the choice back, once.
  static Future<void> warm() => _warming ??= _read();

  static Future<void> _read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _held = prefs.getBool(_key) ?? false;
    } catch (_) {
      // Nothing read back: diagrams are drawn right-handed.
    }
  }

  static Future<bool> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_key) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> save(bool on) async {
    _held = on;
    try {
      final prefs = await SharedPreferences.getInstance();
      // Right-handed is the absence of a choice, stored as nothing.
      if (on) {
        await prefs.setBool(_key, true);
      } else {
        await prefs.remove(_key);
      }
    } catch (_) {
      // Not remembered this time; the sheet on screen is still right.
    }
  }

  @visibleForTesting
  static void resetForTesting() {
    _held = false;
    _warming = null;
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
