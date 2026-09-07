import 'package:flutter/material.dart';

/// What somebody does on a song, in one place.
///
/// This list lived in three: the takes enum, the Open Mic filter chips, and
/// the profile sheet's tick boxes. All three carried a comment warning that
/// they had to agree — which is what you write instead of putting the list
/// somewhere they can all read.
///
/// **And all three were a rock band.** Vocal, harmony, lead, rhythm, bass,
/// drums, keys, percussion. A rapper looking for a beat maker, a beat maker
/// looking for somebody to rap over it, a lyricist who does not record
/// anything at all, somebody who only mixes — none of them could say what
/// they do, so none of them could be found for it. An app that means to be
/// for musicians at any level was quietly for one kind of band.
///
/// The values are the strings already in the database: `song_layers.part`,
/// `profiles.plays` and `project_asks.part` are all free text, so adding to
/// this list needs no migration and takes effect everywhere at once.
enum MusicalRole {
  // What the older list had. The strings are unchanged, because they are in
  // production data.
  vocal,
  harmony,
  rap,
  lyrics,
  topline,
  lead,
  rhythm,
  bass,
  keys,
  drums,
  percussion,
  beat,
  mix,
  other;

  /// The word this is stored as. Never changed once shipped: it is in
  /// `plays` arrays and `song_layers.part` rows already written.
  String get value => name;

  /// What a person is called when they do it.
  ///
  /// A role, not an instrument, wherever the two differ — somebody looking
  /// for help wants "a singer", not "vocal".
  String get label => switch (this) {
        MusicalRole.vocal => 'Singer',
        MusicalRole.harmony => 'Harmony',
        MusicalRole.rap => 'Rapper',
        MusicalRole.lyrics => 'Lyricist',
        MusicalRole.topline => 'Topline',
        MusicalRole.lead => 'Lead',
        MusicalRole.rhythm => 'Rhythm',
        MusicalRole.bass => 'Bass',
        MusicalRole.keys => 'Keys',
        MusicalRole.drums => 'Drums',
        MusicalRole.percussion => 'Percussion',
        MusicalRole.beat => 'Beats',
        MusicalRole.mix => 'Mixing',
        MusicalRole.other => 'Something else',
      };

  /// A sentence for the ones whose name does not carry the whole meaning.
  ///
  /// Only where it earns its place: "Bass" needs no explanation and
  /// "Topline" is meaningless to somebody who has never worked over a beat.
  String? get note => switch (this) {
        MusicalRole.lyrics => 'Words, without having to record anything',
        MusicalRole.topline => 'The melody over somebody else’s track',
        MusicalRole.beat => 'Making the track somebody else writes to',
        MusicalRole.mix => 'Making the finished thing sound finished',
        _ => null,
      };

  IconData get icon => switch (this) {
        MusicalRole.vocal => Icons.mic_rounded,
        MusicalRole.harmony => Icons.groups_rounded,
        MusicalRole.rap => Icons.record_voice_over_rounded,
        MusicalRole.lyrics => Icons.edit_note_rounded,
        MusicalRole.topline => Icons.timeline_rounded,
        MusicalRole.lead => Icons.electric_bolt_rounded,
        MusicalRole.rhythm => Icons.music_note_rounded,
        MusicalRole.bass => Icons.waves_rounded,
        MusicalRole.keys => Icons.piano_rounded,
        MusicalRole.drums => Icons.album_rounded,
        MusicalRole.percussion => Icons.grain_rounded,
        MusicalRole.beat => Icons.grid_view_rounded,
        MusicalRole.mix => Icons.tune_rounded,
        MusicalRole.other => Icons.more_horiz_rounded,
      };

  /// Everything somebody can be asked for or say they do.
  ///
  /// `other` is left out: it is what an unrecognised value becomes, not
  /// something to offer as a choice. "Something else" as a tick box tells
  /// nobody anything and cannot be searched for.
  static List<MusicalRole> get offered =>
      values.where((role) => role != MusicalRole.other).toList(growable: false);

  static MusicalRole parse(String? value) {
    for (final role in values) {
      if (role.name == value) return role;
    }
    return MusicalRole.other;
  }

  /// The label for a stored string, for drawing something written before
  /// this list existed.
  static String labelFor(String value) => parse(value).label;
}
