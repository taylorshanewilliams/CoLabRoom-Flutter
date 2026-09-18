/// Reading a song in numbers instead of letters.
///
/// A Nashville session bassist handed a chart reads 1 4 5, not G C D. The
/// numbers are the same whatever key the singer needs, which is the whole
/// point of them: the band drops a song a tone for somebody's voice and the
/// chart does not change a mark. Roman numerals say the same thing in the
/// language a theory class uses, with the quality in the case — I, IV, V, ii.
///
/// This is a *reading*, in the sense the plan uses the word: it changes what
/// one person sees and never what the song is. It is kept per device per song
/// (see SongNumbersStore), never written to the room, and never carried by
/// Follow me (Every Musician, Same Song, 17 September 2026).
library;

/// Letters, Nashville numbers, or Roman numerals.
enum NumberStyle {
  letters(''),
  nashville('numbers'),
  roman('roman');

  const NumberStyle(this.stored);

  /// What is written to preferences, spelled out rather than stored as the
  /// enum's own name so renaming a constant cannot silently forget
  /// everybody's choice. Letters are the absence of a choice and are stored
  /// as nothing at all.
  final String stored;

  /// What the choice is called on screen. Listed flat and in a fixed order,
  /// the way the plan asks readings to be listed: three languages for the
  /// same song, never a ladder from easy to advanced.
  String get label => switch (this) {
        NumberStyle.letters => 'Letters',
        NumberStyle.nashville => 'Numbers',
        NumberStyle.roman => 'Roman',
      };

  static NumberStyle fromStored(String? stored) {
    for (final style in values) {
      if (style != letters && style.stored == stored) return style;
    }
    return letters;
  }
}

/// Which note a minor song counts from.
///
/// A minor song can be numbered two ways and both are in daily use. Chas
/// Williams' *The Nashville Number System* (1988) — the book the system is
/// written down in — builds every chart on the major scale, so a song in A
/// minor is counted against C and its home chord is written 6-. A lot of
/// players who mostly read minor material count from the minor tonic
/// instead, where the same song reads 1- ♭7 ♭6 ♭3.
///
/// [relativeMajor] is the default because it is the convention the written
/// system describes, and because a song that steps into its relative major
/// for a chorus — which minor songs do constantly — keeps one set of numbers
/// instead of changing language halfway down the page. The other is one tap
/// away for anybody who reads the other way, and it is a personal choice
/// like every other reading here.
enum MinorNumbers {
  relativeMajor('relative'),
  minorTonic('tonic');

  const MinorNumbers(this.stored);

  final String stored;

  String get label => switch (this) {
        MinorNumbers.relativeMajor => 'Minor songs count from 6-',
        MinorNumbers.minorTonic => 'Minor songs count from 1-',
      };

  static MinorNumbers fromStored(String? stored) {
    for (final convention in values) {
      if (convention.stored == stored) return convention;
    }
    return relativeMajor;
  }
}

/// The whole of one person's number reading: which language, and which note a
/// minor song counts from.
///
/// One object rather than two parameters because the two are only ever
/// meaningful together, and because the widgets that draw chords should carry
/// one reading and not a growing list of switches — the next readings in the
/// plan (do-re-mi, sargam, jianpu) belong in here beside these.
class NumberReading {
  const NumberReading({
    this.style = NumberStyle.letters,
    this.minor = MinorNumbers.relativeMajor,
  });

  /// The reading a song opens in until somebody chooses otherwise.
  static const NumberReading letters = NumberReading();

  final NumberStyle style;
  final MinorNumbers minor;

  /// Whether chords are drawn as numbers at all.
  bool get on => style != NumberStyle.letters;

  NumberReading withStyle(NumberStyle style) =>
      NumberReading(style: style, minor: minor);

  NumberReading withMinor(MinorNumbers minor) =>
      NumberReading(style: style, minor: minor);

  @override
  bool operator ==(Object other) =>
      other is NumberReading && other.style == style && other.minor == minor;

  @override
  int get hashCode => Object.hash(style, minor);

  @override
  String toString() => 'NumberReading(${style.name}, ${minor.name})';
}
