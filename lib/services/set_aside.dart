import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Things somebody has said no to.
///
/// Taylor, on two cards at the top of Your music: "I've had this
/// notification of sorts at the top of my screen for awhlie, it says i left
/// this 2 weeks ago... no way of removing this notification, im not sure what
/// the purpose is and its just a neucance at this point... i like the
/// notifications and app asking if you wanna do something, but this should be
/// able to do, or close out of."
///
/// He is describing the difference between a suggestion and a nag, and it is
/// entirely whether "no" is a thing you can say. Both cards offered one verb —
/// open the song — and no way to decline, so a song somebody had deliberately
/// stopped working on sat at the top of the app forever, asking again every
/// time they opened it.
///
/// Kept on the device rather than in the database, deliberately. This is not
/// a fact about the song; it is a fact about one person's patience on one
/// phone, and a table of "things Taylor scrolled past" is a table nobody
/// should have to reason about when they delete their account.
abstract final class SetAside {
  /// The card that says what you left behind.
  static const String pickItBackUp = 'pick_it_back_up';

  /// The card that offers to make a song sheet.
  static const String songSheet = 'song_sheet';

  /// Hints somebody has read and does not need again.
  ///
  /// A hint is a suggestion like any other, and the rule is the same: it has
  /// to be possible to say no. The difference is that a hint answers itself —
  /// once you have tapped the thing it points at, it has done its whole job
  /// and should never appear again.
  static const String hint = 'hint';

  static String _key(String kind) => 'set_aside_$kind';

  /// Held in memory so a list can be drawn without waiting for a disk read,
  /// and reloaded once at startup.
  static final Map<String, Set<String>> _held = <String, Set<String>>{};

  /// What has been set aside for [kind], as far as this session knows.
  static Set<String> of(String kind) =>
      Set<String>.unmodifiable(_held[kind] ?? const <String>{});

  static bool has(String kind, String id) => _held[kind]?.contains(id) ?? false;

  /// Reads everything back, once, at startup.
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final kind in <String>[pickItBackUp, songSheet, hint]) {
        _held[kind] = prefs.getStringList(_key(kind))?.toSet() ?? <String>{};
      }
    } catch (_) {
      // A preferences store that will not open means nothing is remembered as
      // dismissed, which shows one card too many rather than losing anything.
    }
  }

  /// Not this one.
  ///
  /// Kept rather than expired. A suggestion somebody has explicitly closed is
  /// one they have answered, and asking again in a fortnight is the same nag
  /// with a delay on it. The song is still in their library; it has only
  /// stopped being volunteered.
  static Future<void> add(String kind, String id) async {
    final held = _held.putIfAbsent(kind, () => <String>{});
    if (!held.add(id)) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      // A ceiling, because this is a list of ids that only ever grows and it
      // lives in a preferences file. Two hundred dismissals is far past any
      // real library and far short of anything that would matter.
      final trimmed = held.length > 200
          ? held.toList(growable: false).sublist(held.length - 200)
          : held.toList(growable: false);
      _held[kind] = trimmed.toSet();
      await prefs.setStringList(_key(kind), trimmed);
    } catch (_) {
      // Dismissed for this session either way.
    }
  }

  @visibleForTesting
  static void resetForTesting() => _held.clear();
}
