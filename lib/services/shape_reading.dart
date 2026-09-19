/// Which instrument a chord is drawn for.
///
/// The diagrams have always been a right-handed six-string guitar in standard
/// tuning. A uke player, a bass player and a pianist read the same chord and
/// need a different picture of it, and a left-handed guitarist needs the same
/// picture the other way round (Every Musician, Same Song, 17 September 2026).
///
/// This is a *reading*, in the sense the plan uses the word: it changes what
/// one person sees of a chord the whole room agrees on. Nothing here moves a
/// note, and nothing here is written to the room or carried by Follow me.
///
/// One choice for the whole app rather than one per song, like Simpler shapes
/// beside it: the instrument in somebody's hands is the same instrument in the
/// next song, and asking again on every song would be asking them what they
/// play, which they already answered.
enum ShapeReading {
  guitar('Guitar', ''),
  ukulele('Ukulele', 'uke'),
  bass('Bass', 'bass'),
  piano('Piano', 'piano');

  const ShapeReading(this.label, this.stored);

  /// What the choice is called on screen.
  final String label;

  /// What is written to preferences. Spelled out rather than stored as the
  /// enum's own name, so renaming a constant cannot silently forget
  /// everybody's choice. The guitar is the absence of a choice and is stored
  /// as nothing at all.
  final String stored;

  /// Whether a capo means anything to this instrument.
  ///
  /// A capo moves the shapes under a fretting hand and changes nothing the
  /// room hears. It says nothing at all to a pianist, and a bass has no capo
  /// on it — so for those two the chords are read as they sound, which is the
  /// same rule the horn reading has followed since it landed.
  bool get takesACapo => this == guitar || this == ukulele;

  /// How far up the neck a capo is still worth suggesting.
  ///
  /// Seven on a guitar, the same as [highestCapoOnTheChart] beside it — past
  /// that a guitar is a mandolin. A ukulele is a shorter instrument and the
  /// number cannot be the guitar's: a soprano meets its body at the twelfth
  /// fret where a guitar runs to nineteen or twenty, so seven leaves a
  /// guitarist about two thirds of the neck and a ukulele player is left with
  /// five frets and a suggestion nobody would take. Four leaves the same two
  /// thirds of the shorter neck.
  ///
  /// Scored against the guitar's seven a ukulele was sent to the 7th fret for
  /// a blues in G — three chords a uke class teaches in its first hour, two
  /// of them already open (review, 19 September 2026). Zero for the two
  /// instruments [takesACapo] has already turned away.
  int get highestCapo => switch (this) {
        guitar => 7,
        ukulele => 4,
        bass || piano => 0,
      };

  /// How far up the neck the capo chart's rows are still worth printing.
  ///
  /// One fret higher than [highestCapo] on a ukulele, because the two are
  /// different acts. [highestCapo] is where an offer stops: the app reads
  /// this song's own chords and puts a fret forward as advice, and past the
  /// 4th fret of a soprano that is advice nobody would take. The chart
  /// advises nothing — it is the arithmetic laid out for somebody to pick
  /// from — and the 5th fret is the one that puts a song in B♭ on F shapes,
  /// which is the chord a ukulele player has when the band is in the key they
  /// dread. Stopped at four, the chart would carry an F row it could never
  /// show from the one key that wants it most (#405, 19 September 2026).
  ///
  /// Seven on a guitar, which is what the chart has printed since the Toolbox
  /// shipped, and zero for the two instruments [takesACapo] turns away.
  int get highestCapoOnTheChart => switch (this) {
        guitar => 7,
        ukulele => 5,
        bass || piano => 0,
      };

  /// Whether the diagram is a neck that a left-handed player reads mirrored.
  /// A keyboard is not: a left-handed pianist plays the same keyboard.
  ///
  /// The bass is one too. Left-handed bass players restring or buy a
  /// left-handed instrument exactly as guitarists do, and leaving it out made
  /// the chip vanish for the person who had just turned it on (review, 19
  /// September 2026).
  bool get mirrors => this != piano;

  /// The reading [stored] was saved as, or [guitar] for anything else —
  /// including a value written by a later version of the app.
  static ShapeReading fromStored(String? stored) {
    for (final reading in values) {
      if (reading != guitar && reading.stored == stored) return reading;
    }
    return guitar;
  }
}
