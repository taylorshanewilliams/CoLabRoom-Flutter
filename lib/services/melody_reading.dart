/// Reading the notes the recording heard, in the language you read notes in.
///
/// The pipeline has heard the tune since 0106 and the app has only ever said
/// it back in letters — G4, A4, B4 — which is one of several ways the world
/// writes a melody and not the most widely taught one. A singer in a solfège
/// class reads do re mi; a student of Hindustani or Carnatic music reads Sa
/// Re Ga; a great many people in China, Indonesia and Japan read jianpu's
/// numbers with their octave dots. None of them could read this song.
///
/// Like every other reading here, this is *a reading*: it changes what one
/// person sees and never what the song is. It is kept per device per song
/// (see MelodyReadingStore), never written to the room, never carried by
/// Follow me, and never printed on a chart somebody hands to a stranger
/// (Every Musician, Same Song, 17 September 2026).
library;

import '../domain/song_analysis_models.dart';
import 'music_reference.dart';

/// The language the sung notes are read in.
enum MelodyReading {
  letters(''),
  movableDo('movable_do'),
  fixedDo('fixed_do'),
  sargam('sargam'),
  jianpu('jianpu');

  const MelodyReading(this.stored);

  /// What is written to preferences, spelled out rather than stored as the
  /// enum's own name so renaming a constant cannot silently forget
  /// everybody's choice. Letters are the absence of a choice and are stored
  /// as nothing at all.
  final String stored;

  /// What the choice is called on screen. Listed flat and in a fixed order,
  /// the way the plan asks readings to be listed: five languages for the
  /// same tune, never a ladder from easy to advanced.
  String get label => switch (this) {
        MelodyReading.letters => 'Letters',
        MelodyReading.movableDo => 'Do-re-mi',
        MelodyReading.fixedDo => 'Fixed do',
        MelodyReading.sargam => 'Sargam',
        MelodyReading.jianpu => 'Jianpu',
      };

  /// Whether this reading is counted from the 1.
  ///
  /// Movable do, sargam and jianpu all name a note by where it sits in the
  /// scale, so all three need to be told where the scale starts and none of
  /// them moves when somebody transposes the song — exactly like the
  /// Nashville numbers over the words. Fixed do names the sounding pitch, so
  /// it needs no 1 and it does move.
  bool get countsFromTheOne =>
      this == movableDo || this == sargam || this == jianpu;

  /// The reading [stored] was saved as, or [letters] for anything else —
  /// including a value written by a later version of the app.
  static MelodyReading fromStored(String? stored) {
    for (final reading in values) {
      if (reading != letters && reading.stored == stored) return reading;
    }
    return letters;
  }
}

/// Chromatic solfège counted from do, on the sharp side and the flat side.
///
/// Which side is used follows the key the song is written in rather than the
/// direction the tune is moving: the app knows what key a song is in and does
/// not know whether a note is a passing tone on the way up, and guessing at
/// that would be inventing something the analysis never heard.
const List<String> _movableDoSharp = <String>[
  'do', 'di', 're', 'ri', 'mi', 'fa', 'fi', 'sol', 'si', 'la', 'li', 'ti',
];
const List<String> _movableDoFlat = <String>[
  'do', 'ra', 're', 'me', 'mi', 'fa', 'se', 'sol', 'le', 'la', 'te', 'ti',
];

/// Fixed do: the sounding pitch, named the way Spain, Italy, France and most
/// of Latin America name it. Capitalised, and the movable syllables above
/// are not, so the two can never be mistaken for each other on screen.
const List<String> _fixedDoSharp = <String>[
  'Do', 'Do♯', 'Re', 'Re♯', 'Mi', 'Fa', 'Fa♯', 'Sol', 'Sol♯', 'La', 'La♯',
  'Si',
];
const List<String> _fixedDoFlat = <String>[
  'Do', 'Re♭', 'Re', 'Mi♭', 'Mi', 'Fa', 'Sol♭', 'Sol', 'La♭', 'La', 'Si♭',
  'Si',
];

/// Combining marks, one per letter so the line runs under or over the whole
/// syllable the way it is printed rather than under its first letter.
const String _komalMark = '̲';
const String _tivraMark = '̅';

String _marked(String syllable, String mark) =>
    syllable.split('').map((letter) => '$letter$mark').join();

/// Sargam counted from Sa, with the marks it is printed with.
///
/// Sa and Pa have no variants; Re, Ga, Dha and Ni are komal when lowered,
/// written with a line under the syllable; Ma is tivra when raised, written
/// with a line over it (Bhatkhande's notation, which is what a student is
/// handed).
final List<String> _sargam = <String>[
  'Sa',
  _marked('Re', _komalMark),
  'Re',
  _marked('Ga', _komalMark),
  'Ga',
  'Ma',
  _marked('Ma', _tivraMark),
  'Pa',
  _marked('Dha', _komalMark),
  'Dha',
  _marked('Ni', _komalMark),
  'Ni',
];

/// Jianpu: 1 to 7 for the scale, with the accidental written before the
/// digit the way it is printed.
const List<String> _jianpuSharp = <String>[
  '1', '♯1', '2', '♯2', '3', '4', '♯4', '5', '♯5', '6', '♯6', '7',
];
const List<String> _jianpuFlat = <String>[
  '1', '♭2', '2', '♭3', '3', '4', '♭5', '5', '♭6', '6', '♭7', '7',
];

/// Jianpu's octave dots, above the digit for the octave up and below it for
/// the octave down. Combining marks, so they sit on the digit itself — which
/// is why they are appended: the digit is the last character of the cell and
/// the accidental in front of it does not take a dot.
const String _dotAbove = '̇';
const String _dotBelow = '̣';

/// The mark for a note that is still sounding, in jianpu. See
/// [MelodySpelling.of] for what "still sounding" can honestly mean in a row
/// laid out by words.
const String _held = '–';

/// One person's way of reading one song's notes, worked out once.
///
/// Holds everything the spelling needs that is not the note: which language,
/// where the 1 is, which octave counts as the middle one, and which side of
/// the circle the accidentals are written on.
class MelodySpelling {
  const MelodySpelling({
    required this.reading,
    required this.tonicPitch,
    required this.baseMidi,
    this.transpose = 0,
    this.flats = false,
  });

  /// How this person reads the notes of [melody], or null when there is
  /// nothing to read: letters (which is what the sheet already did), no tune,
  /// a tune too thin to read out (see [Melody.worthReading]), or no 1 to
  /// count from on a reading that is counted from one.
  ///
  /// [key] is the song's own key — the band's answer first and the analysis's
  /// second, which is what SongProject.songKey already decides — and [sa] is
  /// this device's own 1 when somebody has picked one, as a pitch class.
  /// Picking a Sa moves what this person reads and nothing else: the song's
  /// key belongs to the room and is set from "Where the 1 is".
  ///
  /// [transpose] is how far this person has moved the song, instrument's part
  /// included. Only fixed do uses it, because only fixed do names a sounding
  /// pitch; the three readings counted from the 1 are the same syllables in
  /// every key, which is the entire reason people read them.
  static MelodySpelling? forSong({
    required MelodyReading reading,
    required Melody? melody,
    required String? key,
    int transpose = 0,
    int? sa,
  }) {
    if (reading == MelodyReading.letters) return null;
    if (melody == null || !melody.worthReading) return null;
    final root = keyRootPitch(key);
    if (root == null && reading.countsFromTheOne && sa == null) return null;
    final tonic = (((sa ?? root ?? 0) % 12) + 12) % 12;
    final moved = reading == MelodyReading.fixedDo ? transpose : 0;
    return MelodySpelling(
      reading: reading,
      tonicPitch: tonic,
      baseMidi: _middleOctaveFrom(melody, tonic),
      transpose: moved,
      flats: pitchUsesFlats((root ?? tonic) + moved, minor: keyIsMinor(key)),
    );
  }

  /// The 1 of the middle octave: the highest one at or below the lowest note
  /// the singer really sang.
  ///
  /// Jianpu's dots are counted from somewhere, and that somewhere has to be
  /// the singer rather than middle C — a bass and a soprano singing the same
  /// tune should read the same page. Melody.lowMidi is already the bottom of
  /// where the voice lives with the tracker's octave errors trimmed off it,
  /// so starting there puts nearly all of a normal tune in the middle octave
  /// with no dots at all, and marks the notes that really do sit outside it.
  static int _middleOctaveFrom(Melody melody, int tonic) {
    var low = melody.lowMidi;
    if (low == null) {
      for (final note in melody.notes) {
        if (low == null || note.midi < low) low = note.midi;
      }
    }
    final lowest = low ?? tonic;
    return lowest - ((((lowest - tonic) % 12) + 12) % 12);
  }

  final MelodyReading reading;

  /// The 1, as a pitch class: the song's key, or the Sa this person picked.
  final int tonicPitch;

  /// The 1 of the octave jianpu draws without dots.
  final int baseMidi;

  /// Semitones the sounding pitch has moved for this person. Zero for every
  /// reading counted from the 1.
  final int transpose;

  /// Whether the accidentals are written flat.
  final bool flats;

  /// One sung note, in this reading.
  ///
  /// [held] says the note is the same one the word before was sung on. Only
  /// jianpu does anything with it, where a dash means the note is still
  /// sounding. A dash there is not a beat: this row is laid out by words and
  /// the app has no honest way to put a word on a beat, so the dash says the
  /// word is still on the note the last word was on, which is what a reader
  /// of the row needs from it and all the word grid can truthfully say.
  ///
  /// The note's cents are deliberately not shown and not read. pyin rounds to
  /// the nearest semitone and hands back how far off it sat; that is enough
  /// to name the nearest note and nowhere near enough to name a sruti or a
  /// gamaka, and a confident wrong one of those is worse than none (Every
  /// Musician, Same Song, 17 September 2026).
  String of(MelodyNote note, {bool held = false}) {
    final midi = note.midi + transpose;
    switch (reading) {
      case MelodyReading.letters:
        return noteInKey(midi, null);
      case MelodyReading.fixedDo:
        final names = flats ? _fixedDoFlat : _fixedDoSharp;
        return names[((midi % 12) + 12) % 12];
      case MelodyReading.movableDo:
        final names = flats ? _movableDoFlat : _movableDoSharp;
        return names[_degreeOf(midi)];
      case MelodyReading.sargam:
        return _sargam[_degreeOf(midi)];
      case MelodyReading.jianpu:
        if (held) return _held;
        final steps = midi - baseMidi;
        final octave = (steps / 12).floor();
        final cell = (flats ? _jianpuFlat : _jianpuSharp)[steps - octave * 12];
        if (octave == 0) return cell;
        return '$cell${(octave > 0 ? _dotAbove : _dotBelow) * octave.abs()}';
    }
  }

  int _degreeOf(int midi) => (((midi - tonicPitch) % 12) + 12) % 12;
}
