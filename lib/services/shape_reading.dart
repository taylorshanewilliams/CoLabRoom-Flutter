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
