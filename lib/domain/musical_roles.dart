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
///
/// **And it will never be complete.** Somebody plays the sitar, somebody
/// runs front of house, somebody writes string arrangements. A fixed list is
/// a promise this cannot keep — so the profile takes whatever gets typed,
/// exactly as `sounds_like` does, and these are the starting points that save
/// typing rather than the whole world.
///
/// Not everything here is a *part* on a song either. Producing and mastering
/// are things done to a record rather than played on it, and they belong on
/// the same list because the question people ask is "who could help with
/// this", not "who can I record onto bar four".
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
  producer,
  engineer,
  mix,
  master,
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
        MusicalRole.producer => 'Producer',
        MusicalRole.engineer => 'Engineer',
        MusicalRole.mix => 'Mixing',
        MusicalRole.master => 'Mastering',
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
        // Three different jobs that get called one thing. Somebody looking
        // for a producer is not looking for somebody to mix it, and telling
        // them apart is the difference between the right person and a
        // conversation that goes nowhere.
        MusicalRole.producer =>
          'Shaping the whole record — arrangement, sound, direction',
        MusicalRole.engineer => 'Getting it recorded properly',
        MusicalRole.mix => 'Balancing the parts into one thing',
        MusicalRole.master => 'The last pass, so it holds up anywhere',
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
        MusicalRole.producer => Icons.auto_awesome_motion_rounded,
        MusicalRole.engineer => Icons.settings_input_component_rounded,
        MusicalRole.mix => Icons.tune_rounded,
        MusicalRole.master => Icons.equalizer_rounded,
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
