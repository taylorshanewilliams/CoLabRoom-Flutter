/// Writing a chord the way a musician writes it.
///
/// ChordMini reports chords in Harte notation — `C:maj`, `A:min`, `G:7`,
/// `D:maj/5` — which is exact, machine-readable, and not what anybody puts on
/// a music stand. Nobody writes "C:maj". They write C.
///
/// This is cosmetic in the sense that the stored label doesn't change, and
/// not cosmetic at all in the sense that a chart nobody can read is a chart
/// nobody uses.

const List<String> _pitchNames = <String>[
  'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B',
];

const Map<String, int> _pitchValues = <String, int>{
  'C': 0, 'B#': 0,
  'C#': 1, 'Db': 1,
  'D': 2,
  'D#': 3, 'Eb': 3,
  'E': 4, 'Fb': 4,
  'F': 5, 'E#': 5,
  'F#': 6, 'Gb': 6,
  'G': 7,
  'G#': 8, 'Ab': 8,
  'A': 9,
  'A#': 10, 'Bb': 10,
  'B': 11, 'Cb': 11,
};

/// Harte quality shorthand, as it's actually written on a chart. An empty
/// string is not a missing entry — a major triad is spelled by writing
/// nothing at all after the root, which is the single most common case.
const Map<String, String> _qualityNames = <String, String>{
  'maj': '',
  'min': 'm',
  'dim': '°',
  'aug': '+',
  '7': '7',
  'maj7': 'maj7',
  'min7': 'm7',
  'dim7': '°7',
  'hdim7': 'm7♭5',
  'minmaj7': 'mMaj7',
  'maj6': '6',
  'min6': 'm6',
  '6': '6',
  '9': '9',
  'maj9': 'maj9',
  'min9': 'm9',
  '11': '11',
  '13': '13',
  'sus2': 'sus2',
  'sus4': 'sus4',
};

/// Harte writes the bass of an inversion as a scale degree relative to the
/// root — `C:maj/5` is a C chord over G. A degree is meaningless to read at
/// speed, and it's the bass player's line, so it gets resolved to a note.
const Map<String, int> _degreeSemitones = <String, int>{
  '1': 0,
  'b2': 1, '2': 2, '#2': 3,
  'b3': 3, '3': 4,
  '4': 5, '#4': 6,
  'b5': 6, '5': 7, '#5': 8,
  'b6': 8, '6': 9,
  'b7': 10, '7': 11,
  'b9': 1, '9': 2,
  '11': 5, '#11': 6,
  '13': 9,
};

/// A chord label as it should appear to a musician.
///
/// Returns an empty string for a stretch with no chord — ChordMini's `N` —
/// so a caller can render nothing rather than the letter N, which on a chart
/// would read as a chord.
///
/// Anything without a colon is passed through untouched. Chords a person
/// typed by hand are already written the way they want them, and this must
/// never "correct" somebody's own spelling.
String chordDisplay(String label) {
  final raw = label.trim();
  if (raw.isEmpty || raw == 'N' || raw == 'X') return '';
  final colon = raw.indexOf(':');
  if (colon <= 0) return raw;

  final root = raw.substring(0, colon);
  var quality = raw.substring(colon + 1);
  var bass = '';
  final slash = quality.indexOf('/');
  if (slash >= 0) {
    bass = quality.substring(slash + 1);
    quality = quality.substring(0, slash);
  }

  // An unrecognised quality is kept verbatim rather than dropped: showing
  // "C:9(11)" is ugly, showing "C" would be a different chord.
  final written = _qualityNames[quality] ?? quality;
  return '$root$written${_bassSuffix(root, bass)}';
}

String _bassSuffix(String root, String bass) {
  if (bass.isEmpty) return '';
  // Already a note name — some sources write the bass out directly.
  if (_pitchValues.containsKey(bass)) return '/$bass';
  final degree = _degreeSemitones[bass];
  final rootValue = _pitchValues[root];
  if (degree == null || rootValue == null) return '/$bass';
  return '/${_pitchNames[(rootValue + degree) % 12]}';
}
