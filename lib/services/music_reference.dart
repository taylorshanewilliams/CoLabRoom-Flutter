/// Reference material for the chord you are looking at and the key you are
/// in — derived, not looked up.
///
/// The Toolbox shipped six static sheets: open chord shapes, a capo chart,
/// scale formulas, bass tuning and root-note patterns. Every one of them was
/// keyed to *a chord* or *a key*, and asked the reader to do the transposing
/// themselves. A song already knows both, so the same material belongs on the
/// chord and on the key badge, already answered for this song.
///
/// Nothing here reads the network or the database; it is arithmetic on note
/// names, which is why it can be unit-tested on a machine with no device.
library;

const List<String> _sharpNames = <String>[
  'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B',
];

const List<String> _flatNames = <String>[
  'C', 'Db', 'D', 'Eb', 'E', 'F', 'Gb', 'G', 'Ab', 'A', 'Bb', 'B',
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

/// Spelling follows the name you were given. A song in Eb should not be told
/// its fifth is A#, and a song in F# should not be told its root is Gb.
String noteName(int pitch, {required bool flats}) {
  final index = (pitch % 12 + 12) % 12;
  return flats ? _flatNames[index] : _sharpNames[index];
}

bool _prefersFlats(String root) {
  if (root.contains('b')) return true;
  // F is the one natural that belongs to the flat side of the circle.
  return root == 'F';
}

/// A note of the chord, with the name a player would say out loud.
class ChordTone {
  const ChordTone(this.degree, this.note);

  final String degree;
  final String note;
}

/// A six-string shape, low string to high. -1 muted, 0 open, N = fret N
/// counting from [baseFret].
class ChordShape {
  const ChordShape({
    required this.name,
    required this.frets,
    this.baseFret = 1,
    this.hint,
  });

  final String name;
  final List<int> frets;
  final int baseFret;

  /// What the shape asks of the hand when the dots do not show it — a barre
  /// is one finger flattened across six strings, which a diagram cannot draw.
  final String? hint;
}

class ChordReference {
  const ChordReference({
    required this.display,
    required this.root,
    required this.qualityName,
    required this.tones,
    required this.shapes,
    required this.bassMoves,
    required this.pentatonic,
    this.bassNote,
  });

  final String display;
  final String root;
  final String qualityName;
  final List<ChordTone> tones;
  final List<ChordShape> shapes;

  /// Root-note patterns from the old bass sheet, spelled in this chord's own
  /// notes rather than as "the 5th, seven half-steps up".
  final List<(String, String)> bassMoves;

  /// Five notes that sit right over this chord — the pentatonic rooted on
  /// it, major or minor to match the third.
  ///
  /// This is the "what can I play here" half of the question. A shape says
  /// where to put the hand for the chord; these say what to reach for
  /// between them, and it is the same five notes whatever the rest of the
  /// song is doing.
  final List<String> pentatonic;

  /// The note under the chord when it is an inversion — the G of `C/G`.
  final String? bassNote;

  /// False when the quality was not one this knows how to spell, which is a
  /// state the sheet shows rather than papers over.
  bool get recognised => tones.isNotEmpty;
}

class _Quality {
  const _Quality(this.id, this.name, this.intervals, this.shapeFamily);

  final String id;
  final String name;
  final List<int> intervals;

  /// Which movable barre shape spells this quality. Null when there is no
  /// simple one, which is the honest answer for a 13th.
  final String? shapeFamily;
}

const Map<String, _Quality> _qualities = <String, _Quality>{
  'maj': _Quality('maj', 'Major', <int>[0, 4, 7], 'maj'),
  'min': _Quality('min', 'Minor', <int>[0, 3, 7], 'min'),
  'dim': _Quality('dim', 'Diminished', <int>[0, 3, 6], null),
  'aug': _Quality('aug', 'Augmented', <int>[0, 4, 8], null),
  '7': _Quality('7', 'Dominant 7th', <int>[0, 4, 7, 10], '7'),
  'maj7': _Quality('maj7', 'Major 7th', <int>[0, 4, 7, 11], 'maj7'),
  'min7': _Quality('min7', 'Minor 7th', <int>[0, 3, 7, 10], 'min7'),
  'dim7': _Quality('dim7', 'Diminished 7th', <int>[0, 3, 6, 9], null),
  'hdim7': _Quality('hdim7', 'Half-diminished', <int>[0, 3, 6, 10], null),
  'maj6': _Quality('maj6', 'Major 6th', <int>[0, 4, 7, 9], null),
  'min6': _Quality('min6', 'Minor 6th', <int>[0, 3, 7, 9], null),
  'sus2': _Quality('sus2', 'Suspended 2nd', <int>[0, 2, 7], null),
  'sus4': _Quality('sus4', 'Suspended 4th', <int>[0, 5, 7], null),
  'add9': _Quality('add9', 'Added 9th', <int>[0, 4, 7, 14], null),
  '9': _Quality('9', 'Dominant 9th', <int>[0, 4, 7, 10, 14], '7'),
  'min9': _Quality('min9', 'Minor 9th', <int>[0, 3, 7, 10, 14], 'min7'),
  'maj9': _Quality('maj9', 'Major 9th', <int>[0, 4, 7, 11, 14], 'maj7'),
  '11': _Quality('11', 'Dominant 11th', <int>[0, 4, 7, 10, 14, 17], '7'),
  '13': _Quality('13', 'Dominant 13th', <int>[0, 4, 7, 10, 14, 21], '7'),
};

/// Both spellings reach the same chord: ChordMini writes Harte (`A:min7`),
/// a person editing a chart writes `Am7` — and the chart itself is drawn in
/// chordDisplay's glyphs, so `C°` has to come back in too.
const Map<String, String> _writtenSuffixes = <String, String>{
  '': 'maj', 'maj': 'maj', 'M': 'maj',
  'm': 'min', 'min': 'min', '-': 'min',
  'dim': 'dim', 'o': 'dim', '°': 'dim',
  'aug': 'aug', '+': 'aug',
  '7': '7',
  'maj7': 'maj7', 'M7': 'maj7', 'Δ7': 'maj7',
  'm7': 'min7', 'min7': 'min7', '-7': 'min7',
  'dim7': 'dim7', '°7': 'dim7',
  'm7b5': 'hdim7', 'm7♭5': 'hdim7', 'ø': 'hdim7',
  '6': 'maj6', 'maj6': 'maj6',
  'm6': 'min6', 'min6': 'min6',
  'sus2': 'sus2', 'sus4': 'sus4', 'sus': 'sus4',
  'add9': 'add9', 'add2': 'add9',
  '9': '9', 'm9': 'min9', 'min9': 'min9', 'maj9': 'maj9', 'M9': 'maj9',
  '11': '11', '13': '13',
};

const Map<int, String> _degreeNames = <int, String>{
  0: 'root',
  2: '9th',
  3: 'flat 3rd',
  4: '3rd',
  5: '4th',
  6: 'flat 5th',
  7: '5th',
  8: 'sharp 5th',
  9: '6th',
  10: 'flat 7th',
  11: '7th',
  14: '9th',
  17: '11th',
  21: '13th',
};

/// Written form of a quality, for looking an open shape up by name — and for
/// the sheet's own title, which has to read as the same chord that was
/// tapped, so these are chordDisplay's glyphs rather than a second spelling.
const Map<String, String> _shortForms = <String, String>{
  'maj': '', 'min': 'm', '7': '7', 'maj7': 'maj7', 'min7': 'm7',
  'dim': '°', 'aug': '+', 'dim7': '°7', 'hdim7': 'm7♭5',
  'maj6': '6', 'min6': 'm6', 'sus2': 'sus2', 'sus4': 'sus4',
  'add9': 'add9', '9': '9', 'min9': 'm9', 'maj9': 'maj9',
  '11': '11', '13': '13',
};

/// Open shapes worth knowing, by written chord name. These beat any movable
/// shape when they exist — an open G rings, a barred one does not.
const Map<String, List<int>> _openShapes = <String, List<int>>{
  'C': <int>[-1, 3, 2, 0, 1, 0],
  'C7': <int>[-1, 3, 2, 3, 1, 0],
  'Cmaj7': <int>[-1, 3, 2, 0, 0, 0],
  'D': <int>[-1, -1, 0, 2, 3, 2],
  'Dm': <int>[-1, -1, 0, 2, 3, 1],
  'D7': <int>[-1, -1, 0, 2, 1, 2],
  'Dm7': <int>[-1, -1, 0, 2, 1, 1],
  'Dmaj7': <int>[-1, -1, 0, 2, 2, 2],
  'Dsus2': <int>[-1, -1, 0, 2, 3, 0],
  'Dsus4': <int>[-1, -1, 0, 2, 3, 3],
  'E': <int>[0, 2, 2, 1, 0, 0],
  'Em': <int>[0, 2, 2, 0, 0, 0],
  'E7': <int>[0, 2, 0, 1, 0, 0],
  'Em7': <int>[0, 2, 0, 0, 0, 0],
  'Emaj7': <int>[0, 2, 1, 1, 0, 0],
  'Esus4': <int>[0, 2, 2, 2, 0, 0],
  'G': <int>[3, 2, 0, 0, 0, 3],
  'G7': <int>[3, 2, 0, 0, 0, 1],
  'Gmaj7': <int>[3, 2, 0, 0, 0, 2],
  'A': <int>[-1, 0, 2, 2, 2, 0],
  'Am': <int>[-1, 0, 2, 2, 1, 0],
  'A7': <int>[-1, 0, 2, 0, 2, 0],
  'Am7': <int>[-1, 0, 2, 0, 1, 0],
  'Amaj7': <int>[-1, 0, 2, 1, 2, 0],
  'Asus2': <int>[-1, 0, 2, 2, 0, 0],
  'Asus4': <int>[-1, 0, 2, 2, 3, 0],
  'B7': <int>[-1, 2, 1, 2, 0, 2],
  'Fmaj7': <int>[-1, -1, 3, 2, 1, 0],
};

/// Movable shapes, written relative to their own barre. The E family is
/// rooted on the sixth string, the A family on the fifth.
const Map<String, List<int>> _eShapes = <String, List<int>>{
  'maj': <int>[1, 3, 3, 2, 1, 1],
  'min': <int>[1, 3, 3, 1, 1, 1],
  '7': <int>[1, 3, 1, 2, 1, 1],
  'min7': <int>[1, 3, 1, 1, 1, 1],
  'maj7': <int>[1, 3, 2, 2, 1, 1],
};

const Map<String, List<int>> _aShapes = <String, List<int>>{
  'maj': <int>[-1, 1, 3, 3, 3, 1],
  'min': <int>[-1, 1, 3, 3, 2, 1],
  '7': <int>[-1, 1, 3, 1, 3, 1],
  'min7': <int>[-1, 1, 3, 1, 2, 1],
  'maj7': <int>[-1, 1, 3, 2, 3, 1],
};

/// Everything worth saying about one chord.
///
/// Returns null for a stretch with no chord — ChordMini's `N` — so a caller
/// can leave the tap doing nothing rather than opening an empty sheet.
ChordReference? chordReference(String label) {
  final raw = label.trim();
  if (raw.isEmpty || raw == 'N' || raw == 'X') return null;

  final String rootText;
  final String qualityToken;
  final String bassToken;

  final colon = raw.indexOf(':');
  if (colon > 0) {
    rootText = raw.substring(0, colon);
    var rest = raw.substring(colon + 1);
    final slash = rest.indexOf('/');
    bassToken = slash >= 0 ? rest.substring(slash + 1) : '';
    if (slash >= 0) rest = rest.substring(0, slash);
    qualityToken = rest;
  } else {
    final match = RegExp(r'^([A-G][#b]?)(.*)$').firstMatch(raw);
    if (match == null) return null;
    rootText = match.group(1)!;
    var rest = match.group(2)!;
    final slash = rest.indexOf('/');
    bassToken = slash >= 0 ? rest.substring(slash + 1) : '';
    if (slash >= 0) rest = rest.substring(0, slash);
    qualityToken = _writtenSuffixes[rest] ?? rest;
  }

  final rootPitch = _pitchValues[rootText];
  if (rootPitch == null) return null;
  final flats = _prefersFlats(rootText);

  final quality = _qualities[qualityToken];
  final short = _shortForms[qualityToken] ?? qualityToken;
  final display = '$rootText$short${bassToken.isEmpty ? '' : '/$bassToken'}';

  if (quality == null) {
    // An unrecognised quality is not guessed at. Showing a major triad's
    // notes under a chord name that isn't major would be worse than saying
    // nothing, so the sheet renders its "no shape stored" state instead.
    return ChordReference(
      display: display,
      root: rootText,
      qualityName: qualityToken,
      tones: const <ChordTone>[],
      shapes: const <ChordShape>[],
      bassMoves: const <(String, String)>[],
      pentatonic: const <String>[],
      bassNote: bassToken.isEmpty ? null : bassToken,
    );
  }

  return ChordReference(
    display: display,
    root: rootText,
    qualityName: quality.name,
    tones: <ChordTone>[
      for (final interval in quality.intervals)
        ChordTone(
          _degreeNames[interval] ?? '+$interval',
          noteName(rootPitch + interval, flats: flats),
        ),
    ],
    shapes: _shapesFor(rootText, rootPitch, quality),
    bassMoves: _bassMovesFor(rootPitch, quality, flats),
    pentatonic: <String>[
      // The third decides it: a flat third takes the minor pentatonic, and
      // a chord with no third at all (sus, fifths) is left on the major one,
      // which is the safer guess over an ambiguous chord.
      for (final step
          in quality.intervals.contains(3) ? _minorPentatonic : _majorPentatonic)
        noteName(rootPitch + step, flats: flats),
    ],
    bassNote: bassToken.isEmpty ? null : bassToken,
  );
}

List<ChordShape> _shapesFor(String rootText, int rootPitch, _Quality quality) {
  final shapes = <ChordShape>[];
  final short = _shortForms[quality.id] ?? '';
  final openName = '$rootText$short';
  // The library is keyed by sharp spelling, so Eb has to ask for D# too.
  final open = _openShapes[openName] ??
      _openShapes['${noteName(rootPitch, flats: false)}$short'];
  if (open != null) {
    shapes.add(ChordShape(name: openName, frets: open, hint: 'Open position'));
  }

  final family = quality.shapeFamily;
  if (family != null) {
    final eFret = ((rootPitch - 4) % 12 + 12) % 12;
    final aFret = ((rootPitch - 9) % 12 + 12) % 12;
    final movable = <(int, String, List<int>)>[
      if (eFret >= 1 && _eShapes[family] != null)
        (eFret, 'sixth string', _eShapes[family]!),
      if (aFret >= 1 && _aShapes[family] != null)
        (aFret, 'fifth string', _aShapes[family]!),
    ]..sort((a, b) => a.$1.compareTo(b.$1));

    for (final (fret, rootString, frets) in movable) {
      if (shapes.length >= 2) break;
      shapes.add(ChordShape(
        name: openName,
        frets: frets,
        baseFret: fret,
        hint: 'Barre at fret $fret, root on the $rootString',
      ));
    }
  }
  return shapes;
}

List<(String, String)> _bassMovesFor(int rootPitch, _Quality quality, bool flats) {
  final root = noteName(rootPitch, flats: flats);
  final minor = quality.intervals.contains(3);
  final third = noteName(rootPitch + (minor ? 3 : 4), flats: flats);
  final fourth = noteName(rootPitch + 5, flats: flats);
  final fifth = noteName(rootPitch + 7, flats: flats);
  final sixth = noteName(rootPitch + 9, flats: flats);
  return <(String, String)>[
    ('Root–fifth', '$root  $fifth'),
    ('Root–octave', '$root  $root'),
    if (minor)
      ('Walking', '$root  $third  $fourth  $fifth')
    else
      ('Walking', '$root  $third  $fifth  $sixth'),
  ];
}

class KeyReference {
  const KeyReference({
    required this.display,
    required this.tonic,
    required this.minor,
    required this.scale,
    required this.degrees,
    required this.diatonic,
    required this.pentatonic,
    required this.relative,
    required this.capo,
  });

  final String display;
  final String tonic;
  final bool minor;

  /// The seven notes, tonic first.
  final List<String> scale;

  /// Roman numerals lined up with [diatonic].
  final List<String> degrees;

  /// The chords built on each degree — the ones this song is likely made of.
  final List<String> diatonic;

  final List<String> pentatonic;

  /// The relative minor of a major key, or the relative major of a minor one.
  final String relative;

  /// (fret, the key you play in) — the capo chart's arithmetic, already done
  /// for this key.
  final List<(int, String)> capo;
}

const List<int> _majorSteps = <int>[0, 2, 4, 5, 7, 9, 11];
const List<int> _minorSteps = <int>[0, 2, 3, 5, 7, 8, 10];
const List<String> _majorDegrees = <String>['I', 'ii', 'iii', 'IV', 'V', 'vi', 'vii°'];
const List<String> _minorDegrees = <String>['i', 'ii°', 'III', 'iv', 'v', 'VI', 'VII'];
const List<String> _majorQualities = <String>['', 'm', 'm', '', '', 'm', 'dim'];
const List<String> _minorQualities = <String>['m', 'dim', '', 'm', 'm', '', ''];
const List<int> _majorPentatonic = <int>[0, 2, 4, 7, 9];
const List<int> _minorPentatonic = <int>[0, 3, 5, 7, 10];

/// Open-chord keys a capo is used to reach, and the pitch they sound at.
const Map<String, int> _capoMajorShapes = <String, int>{
  'G': 7, 'C': 0, 'D': 2, 'A': 9, 'E': 4,
};
const Map<String, int> _capoMinorShapes = <String, int>{'Em': 4, 'Am': 9, 'Dm': 2};

/// The key as the analyzer reports it — `A minor`, `C# major`, or a bare root
/// when key detection fell back to "which chord lasted longest".
///
/// A bare root is read as major, which is what a bare letter means on a
/// chart: the scale shown is then the one that name implies, and no more.
KeyReference? keyReference(String label) {
  final raw = label.trim();
  if (raw.isEmpty) return null;
  final match = RegExp(r'^([A-G][#b]?)\s*(.*)$').firstMatch(raw);
  if (match == null) return null;
  final tonic = match.group(1)!;
  final rest = match.group(2)!.toLowerCase();
  final tonicPitch = _pitchValues[tonic];
  if (tonicPitch == null) return null;

  final minor = rest.startsWith('min') || rest == 'm' || rest.startsWith('aeolian');
  final flats = _prefersFlats(tonic);
  final steps = minor ? _minorSteps : _majorSteps;
  final qualities = minor ? _minorQualities : _majorQualities;

  final scale = <String>[
    for (final step in steps) noteName(tonicPitch + step, flats: flats),
  ];

  final shapes = minor ? _capoMinorShapes : _capoMajorShapes;
  final capo = <(int, String)>[];
  for (final entry in shapes.entries) {
    final fret = ((tonicPitch - entry.value) % 12 + 12) % 12;
    if (fret >= 1 && fret <= 7) capo.add((fret, entry.key));
  }
  capo.sort((a, b) => a.$1.compareTo(b.$1));

  return KeyReference(
    display: '$tonic ${minor ? 'minor' : 'major'}',
    tonic: tonic,
    minor: minor,
    scale: scale,
    degrees: minor ? _minorDegrees : _majorDegrees,
    diatonic: <String>[
      for (var i = 0; i < steps.length; i += 1) '${scale[i]}${qualities[i]}',
    ],
    pentatonic: <String>[
      for (final step in minor ? _minorPentatonic : _majorPentatonic)
        noteName(tonicPitch + step, flats: flats),
    ],
    relative: minor
        ? '${noteName(tonicPitch + 3, flats: flats)} major'
        : '${noteName(tonicPitch + 9, flats: flats)} minor',
    capo: capo,
  );
}
