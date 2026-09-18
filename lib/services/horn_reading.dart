import 'pitch.dart';

/// Reading a song for a transposing instrument.
///
/// A trumpet player fingers a written C and a concert B♭ comes out of the
/// bell. The band's chart is in concert pitch, so a horn player either
/// transposes every chord in their head while the count-in is happening, or
/// they get handed a part somebody wrote out for them. The song already knows
/// its key and its chords, so it can be read out in the instrument's own
/// written pitch and save them the arithmetic (Every Musician, Same Song,
/// 17 September 2026).
///
/// [semitones] is how far above concert pitch the instrument is *written*: a
/// B♭ instrument reads a major second up, an E♭ one a major sixth up (the
/// same note as a minor third down, one octave apart), an F one a perfect
/// fifth up. So a concert B♭ is written C for a trumpet, a concert F is
/// written D for an alto sax, and a concert C is written G for a horn in F.
///
/// This is a *reading*, in the sense the plan uses the word: it changes what
/// one person sees and never what the song is. It is kept per device per song
/// (see SongReadingStore), never written to the room, and never carried by
/// Follow me.
enum HornReading {
  concert(0, 'Concert', ''),
  bFlat(2, 'B♭', 'Bb'),
  eFlat(9, 'E♭', 'Eb'),
  f(7, 'F', 'F');

  const HornReading(this.semitones, this.label, this.stored);

  /// How far above concert pitch this instrument's written notes are.
  final int semitones;

  /// What the choice is called on screen.
  final String label;

  /// What is written to preferences. Spelled out rather than stored as the
  /// enum's own name, so a preferences file stays readable and renaming a
  /// constant cannot silently forget everybody's choice. Concert pitch is
  /// the absence of a choice and is stored as nothing at all.
  final String stored;

  /// The reading [stored] was saved as, or [concert] for anything else —
  /// including a value written by a later version of the app.
  static HornReading fromStored(String? stored) {
    for (final reading in values) {
      if (reading != concert && reading.stored == stored) return reading;
    }
    return concert;
  }
}

/// The note a transposing instrument writes for a sounding [midi], with the
/// octave it is written in.
///
/// Spelled with sharps, like every other note name the tuner shows: there is
/// no key on a tuner to spell it against.
(String, int) writtenNote(HornReading reading, int midi) {
  final moved = midi + reading.semitones;
  return (noteNames[moved % 12], moved ~/ 12 - 1);
}
