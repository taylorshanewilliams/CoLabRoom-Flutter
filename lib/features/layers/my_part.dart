import 'package:shared_preferences/shared_preferences.dart';

import '../../services/multitrack.dart';
import '../../services/take_naming.dart';

/// Your part forward, or everyone but you.
///
/// A choir learns its alto line and a band learns a harmony, and both want
/// the same thing from the recording: their part louder than the rest, or
/// the rest without their part so they can sing it. Both come from the takes
/// the room already has, never from separation -- Demucs puts every voice in
/// one stem and cannot tell an alto from a tenor, so a part is a recorded
/// take (Every Musician, Same Song, 17 September 2026, slice 17).
///
/// Personal, like SongLevelStore. The faders on the takes screen are shared:
/// a level belongs to whoever recorded the take and everybody hears where
/// they put it. This is a way of listening, not a change to the mix, so it
/// is applied on this phone on top of those levels and never written back to
/// them. Jess turning her own part up to learn it must not turn it up for
/// the whole choir.
enum MyPartWay {
  /// That take up and every other one down.
  forward,

  /// That take left out, so its part can be sung or played over the rest.
  without,
}

/// One take, and which way it is being listened to.
class MyPart {
  const MyPart({required this.takeId, required this.way});

  final String takeId;
  final MyPartWay way;

  /// "Alto 2 — Jess forward", or "Everyone but Alto 2 — Jess". The words a
  /// chip says, given the take's name; see [TakeNaming.partAndPerson].
  String label(String name) {
    switch (way) {
      case MyPartWay.forward:
        return '$name forward';
      case MyPartWay.without:
        return 'Everyone but $name';
    }
  }

  /// A key-safe suffix: "forward_<take id>".
  String get keySuffix => '${way.name}_$takeId';

  /// The form kept on disk. The way first, so a take id that happened to
  /// contain a colon could never be mistaken for one.
  String encode() => '${way.name}:$takeId';

  static MyPart? decode(String? value) {
    if (value == null) return null;
    final colon = value.indexOf(':');
    if (colon <= 0 || colon == value.length - 1) return null;
    final wayName = value.substring(0, colon);
    for (final way in MyPartWay.values) {
      if (way.name == wayName) {
        return MyPart(takeId: value.substring(colon + 1), way: way);
      }
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is MyPart && other.takeId == takeId && other.way == way;

  @override
  int get hashCode => Object.hash(takeId, way);

  @override
  String toString() => 'MyPart(${encode()})';
}

/// The listening rule, kept apart from any screen so both of them mix the
/// same way.
abstract final class MyPartMix {
  const MyPartMix._();

  /// How far a part comes up when it is forward, and how far the rest drop
  /// behind it. Together they put the part about ten decibels ahead, which
  /// is where a rehearsal track puts the line it is teaching: clearly on
  /// top, with the rest still there to hear it against. Only the ratio
  /// matters once the mix is turned down to fit (Multitrack.mix scales the
  /// whole sum rather than clipping), but a quiet phone take against a
  /// mastered record needs the real lift as well as the real cut.
  static const double forward = 1.5;
  static const double behind = 0.4;

  /// [takes] as this listener hears them, with [choice] applied on top of
  /// the levels the room set.
  ///
  /// New takes come back; the ones handed in are not touched, and neither is
  /// anything they were read from. A choice naming a take that is no longer
  /// here -- it was deleted after the choice was kept -- changes nothing,
  /// which is what a stale preference should do.
  ///
  /// A part brought forward is heard, whatever its mute was: asking for a
  /// take on top and getting the rest turned down under silence is not what
  /// anybody meant.
  static List<Take> apply(List<Take> takes, MyPart? choice) {
    if (choice == null || !takes.any((take) => take.id == choice.takeId)) {
      return takes;
    }
    switch (choice.way) {
      case MyPartWay.forward:
        return <Take>[
          for (final take in takes)
            if (take.id == choice.takeId)
              take.copyWith(gain: take.gain * forward, enabled: true)
            else
              take.copyWith(gain: take.gain * behind),
        ];
      case MyPartWay.without:
        return <Take>[
          for (final take in takes)
            if (take.id == choice.takeId)
              take.copyWith(enabled: false)
            else
              take,
        ];
    }
  }

  /// The takes that can be somebody's part: every take somebody recorded,
  /// once there are two of them to tell apart.
  ///
  /// The song's own recording ([referenceId]) is never offered and is not
  /// counted. It is not a part and nobody's: it is what the parts are heard
  /// against, so it is one of the others when a part is forward and stays
  /// in when one is left out. A song with one take, or none, offers nothing
  /// -- not a chip that does nothing. One take over the record has nothing
  /// to be forward of but the record, and the song's own level already
  /// answers that (SongLevelStore).
  static List<Take> offered(List<Take> takes, {required String referenceId}) {
    final recorded = takes
        .where((take) => take.id != referenceId)
        .toList(growable: false);
    return recorded.length < 2 ? const <Take>[] : recorded;
  }
}

/// Which part this person is listening for on each song, on this device.
///
/// Kept the way SongLevelStore keeps the song's level and SongTransposeStore
/// keeps the key: per song, per phone, never sent to the room and never
/// carried by Follow me. A follower hearing their own part forward while the
/// leader hears the whole band is the point, not a disagreement.
///
/// Fail-safe both ways. A preferences store that will not open means the
/// song plays as the room mixed it, which is what it did before any of this.
abstract final class MyPartStore {
  static String _key(String projectId) => 'my_part_$projectId';

  static Future<MyPart?> load(String projectId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return MyPart.decode(prefs.getString(_key(projectId)));
    } catch (_) {
      return null;
    }
  }

  /// Keeps [choice], or forgets the one kept when it is null.
  static Future<void> save(String projectId, MyPart? choice) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (choice == null) {
        await prefs.remove(_key(projectId));
      } else {
        await prefs.setString(_key(projectId), choice.encode());
      }
    } catch (_) {
      // A choice that will not save is a choice for this session only.
    }
  }
}
