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

  /// What you call a group of them, for a sentence rather than a chip.
  ///
  /// "Bass" is a fine word on a tick box and a poor one in a line of text
  /// that has to say what you are looking at. The screen says *Bass players
  /// near you*, so the enum has to know the plural — otherwise the sentence
  /// gets assembled out of labels and reads like a database.
  String get plural => switch (this) {
        MusicalRole.vocal => 'Singers',
        MusicalRole.harmony => 'Harmony singers',
        MusicalRole.rap => 'Rappers',
        MusicalRole.lyrics => 'Lyricists',
        MusicalRole.topline => 'Topline writers',
        MusicalRole.lead => 'Lead players',
        MusicalRole.rhythm => 'Rhythm players',
        MusicalRole.bass => 'Bass players',
        MusicalRole.keys => 'Keys players',
        MusicalRole.drums => 'Drummers',
        MusicalRole.percussion => 'Percussionists',
        MusicalRole.beat => 'Beat makers',
        MusicalRole.producer => 'Producers',
        MusicalRole.engineer => 'Engineers',
        MusicalRole.mix => 'People who mix',
        MusicalRole.master => 'People who master',
        MusicalRole.other => 'People',
      };

  /// The same role from the other end: what a song is short of.
  ///
  /// The article is part of it. "Songs that need a singer" and "songs that
  /// need mixing" are both right and neither rule produces the other, so the
  /// phrase is written out rather than derived.
  String get need => switch (this) {
        MusicalRole.vocal => 'a singer',
        MusicalRole.harmony => 'harmony',
        MusicalRole.rap => 'a rapper',
        MusicalRole.lyrics => 'lyrics',
        MusicalRole.topline => 'a topline',
        MusicalRole.lead => 'lead',
        MusicalRole.rhythm => 'rhythm',
        MusicalRole.bass => 'bass',
        MusicalRole.keys => 'keys',
        MusicalRole.drums => 'drums',
        MusicalRole.percussion => 'percussion',
        MusicalRole.beat => 'a beat',
        MusicalRole.producer => 'a producer',
        MusicalRole.engineer => 'an engineer',
        MusicalRole.mix => 'mixing',
        MusicalRole.master => 'mastering',
        MusicalRole.other => 'somebody',
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

/// Four doors instead of sixteen chips.
///
/// The Open Mic laid all seventeen roles out at once in a horizontal strip
/// you could see four of at a time, which is a conveyor belt rather than a
/// choice: finding "mixing" meant scrolling past twelve things you were not
/// looking for, and nothing on screen said the list had an end.
///
/// **A phone answers this the same way every time.** One question per screen,
/// the specifics one level down, and going in costs nothing because back is
/// free. So: four rows, then three to six. Two taps reaches anything, and the
/// count on the first screen is small enough to read without scrolling.
///
/// The grouping is by what somebody is *for*, not by how the sound is made —
/// a rapper and a lyricist belong together because the person looking for
/// either is looking for words, and putting the lyricist in with the drummers
/// on the grounds that neither of them sings would be filing by accident.
enum RoleFamily {
  voices('Voices and words', <MusicalRole>[
    MusicalRole.vocal,
    MusicalRole.harmony,
    MusicalRole.rap,
    MusicalRole.topline,
    MusicalRole.lyrics,
  ]),
  instruments('Instruments', <MusicalRole>[
    MusicalRole.lead,
    MusicalRole.rhythm,
    MusicalRole.bass,
    MusicalRole.keys,
    MusicalRole.drums,
    MusicalRole.percussion,
  ]),
  production('Beats and production', <MusicalRole>[
    MusicalRole.beat,
    MusicalRole.producer,
  ]),
  finishing('Getting it finished', <MusicalRole>[
    MusicalRole.engineer,
    MusicalRole.mix,
    MusicalRole.master,
  ]);

  const RoleFamily(this.label, this.members);

  final String label;
  final List<MusicalRole> members;

  IconData get icon => switch (this) {
        RoleFamily.voices => Icons.mic_rounded,
        RoleFamily.instruments => Icons.music_note_rounded,
        RoleFamily.production => Icons.grid_view_rounded,
        RoleFamily.finishing => Icons.tune_rounded,
      };

  /// Every role has a door, and the check that says so.
  ///
  /// A role added to [MusicalRole] and forgotten here would be unreachable
  /// from the only place the app offers roles — present in the data, absent
  /// from the room, and invisible in a way no screen would show.
  static bool get coversEveryRole {
    final filed = <MusicalRole>{
      for (final family in values) ...family.members,
    };
    return filed.length == MusicalRole.offered.length;
  }

  /// The family whose members are exactly [chosen], if there is one.
  ///
  /// Lets the sentence say "Voices and words near you" after somebody picked
  /// a whole door, instead of listing five roles or saying "5 things".
  static RoleFamily? matching(Set<String> chosen) {
    for (final family in values) {
      if (family.members.length != chosen.length) continue;
      if (family.members.every((role) => chosen.contains(role.value))) {
        return family;
      }
    }
    return null;
  }
}
