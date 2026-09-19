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

/// Whether a key is written with flats.
///
/// F, B♭, E♭, A♭ and D♭ major; D, G, C, F and B♭ minor. Decided by
/// pitch, not by how the key arrived: the analyser names every key with
/// sharps, so "A# major" is B♭ major and was shown to a band as "A# major"
/// with A# and D# chords (audit, 17 September 2026, South Of Midnight). The
/// six-accidental keys stay sharp (F♯ major, D♯ minor), which is how they are
/// usually written.
bool keyUsesFlats(String? key) {
  final pitch = keyRootPitch(key);
  if (pitch == null) return false;
  return pitchUsesFlats(pitch, minor: keyIsMinor(key));
}

/// The same rule as [keyUsesFlats], asked of a root that has no name yet.
///
/// A reading that has moved a key -- fixed do naming the sounding pitch of a
/// song somebody dropped a tone -- knows the root it landed on and not what
/// to call it, which is the question this answers.
bool pitchUsesFlats(int pitch, {required bool minor}) {
  final root = ((pitch % 12) + 12) % 12;
  return minor
      ? const <int>{2, 7, 0, 5, 10}.contains(root)
      : const <int>{5, 10, 3, 8, 1}.contains(root);
}

/// The pitch class a key counts from: 0 for C up to 11 for B, or null when
/// [key] is not a key this can read.
///
/// Public so there is one table and one reading of a key's root. The numbers
/// over the words, the transpose between two keys and the syllables under
/// them all have to agree about where the 1 of a key is.
int? keyRootPitch(String? key) {
  final match = key == null
      ? null
      : RegExp(r'^([A-G][#b]?)').firstMatch(key.trim());
  return match == null ? null : _pitchValues[match.group(1)!];
}

/// Whether a key is a minor one, by the mode written after its root: "A
/// minor", "Am", "A min", "A aeolian". A bare root is major, and so is
/// anything that is not a key this can read.
bool keyIsMinor(String? key) {
  final match = key == null ? null : RegExp(r'^([A-G][#b]?)\s*(.*)$').firstMatch(key.trim());
  if (match == null) return false;
  final rest = match.group(2)!.toLowerCase();
  return rest.startsWith('min') || rest == 'm' || rest.startsWith('aeolian');
}

/// A chord or a key written the way its key writes it: B♭ rather than A♯ in
/// a flat key.
///
/// Only sharps are respelled, so a name somebody wrote with flats stays as
/// they wrote it. A minor key keeps its raised seventh sharp -- the C♯ of an
/// A7 in D minor is a C♯ -- because that is the one sharp a flat minor key
/// really has.
///
/// A slash chord's *sharp* bass is spelled from the chord it belongs to when
/// it is one of that chord's own notes. The key rule on its own read D/F♯ in D
/// minor as D/G♭, and that F♯ is the major third of D: a third is two letters
/// up from the root whatever the key is doing, so it has to be written as
/// some kind of F (Every Musician, Same Song, 17 September 2026). A bass that
/// is not a chord tone is nothing to do with the chord, and is left to the
/// key rule.
///
/// Only a sharp bass goes through it, for the same reason only sharps are
/// respelled at all: a bass somebody wrote as a G♭ is theirs, and the chord
/// rule is not allowed to correct it either (review, 17 September 2026).
String spellInKey(String written, String? key) {
  if (!keyUsesFlats(key)) return written;
  final tonic = RegExp(r'^([A-G][#b]?)').firstMatch(key!.trim())?.group(1);
  final tonicPitch = tonic == null ? null : _pitchValues[tonic];
  final rest = key.trim().substring(tonic?.length ?? 0).trim().toLowerCase();
  final minor = rest.startsWith('min') || rest == 'm' || rest.startsWith('aeolian');
  final leadingTone = minor && tonicPitch != null ? (tonicPitch + 11) % 12 : null;

  final slash = written.lastIndexOf('/');
  if (slash > 0 && written.substring(slash + 1).contains('#')) {
    // The root is spelled in the key first, because the bass is then counted
    // in letters from whatever the root ended up being called.
    final chord = _flattenSharps(written.substring(0, slash), leadingTone);
    final bass = _bassAsChordTone(chord, written.substring(slash + 1));
    if (bass != null) return '$chord/$bass';
  }
  return _flattenSharps(written, leadingTone);
}

String _flattenSharps(String written, int? leadingTone) =>
    written.replaceAllMapped(RegExp(r'([A-G])#'), (match) {
      final pitch = _pitchValues['${match.group(1)}#'];
      if (pitch == null || pitch == leadingTone) return match.group(0)!;
      return _flatNames[pitch];
    });

/// How far up the alphabet a chord tone is written from the root: a third is
/// two letters up, a fifth four, a seventh six. Flattened or sharpened, a
/// third is still a third — the flat fifth of a diminished chord is a G of
/// some kind over a C, never an F♯.
const Map<int, int> _chordToneLetters = <int, int>{
  3: 2, 4: 2,
  6: 4, 7: 4, 8: 4,
  10: 6, 11: 6,
};

const String _letters = 'CDEFGAB';
const List<int> _letterPitches = <int>[0, 2, 4, 5, 7, 9, 11];

/// The bass of a slash chord spelled as the chord tone it is, or null when
/// [bass] is not a third, fifth or seventh of [chord] and the key should
/// spell it instead.
String? _bassAsChordTone(String chord, String bass) {
  final bassPitch = _pitchValues[bass.trim()];
  final match = RegExp(r'^([A-G][#b]?)(.*)$').firstMatch(chord.trim());
  if (bassPitch == null || match == null) return null;
  final root = match.group(1)!;
  final rootPitch = _pitchValues[root];
  if (rootPitch == null) return null;
  final suffix = match.group(2)!;
  final quality = _qualities[_writtenSuffixes[suffix] ?? suffix];
  if (quality == null) return null;

  final interval = (bassPitch - rootPitch + 12) % 12;
  final letters = _chordToneLetters[interval];
  if (letters == null) return null;
  if (!quality.intervals.any((tone) => tone % 12 == interval)) return null;

  final letter = (_letters.indexOf(root[0]) + letters) % 7;
  final shift = (bassPitch - _letterPitches[letter] + 18) % 12 - 6;
  // A double flat is correct arithmetic and no help on a music stand — the
  // diminished seventh of C is a B double-flat — so those fall back to the
  // key rule and its plain A.
  if (shift < -1 || shift > 1) return null;
  return '${_letters[letter]}${shift == 1 ? '#' : shift == -1 ? 'b' : ''}';
}

/// Spelling follows the name you were given. A song in Eb should not be told
/// its fifth is A#, and a song in F# should not be told its root is Gb.
/// Whether two note names are the same pitch.
///
/// Compared as pitches rather than as text, because Bb and A# are the same
/// note — and a chart spelled one way against a key spelled the other would
/// otherwise never match.
bool samePitch(String a, String b) {
  final pa = _pitchValues[a.trim()];
  final pb = _pitchValues[b.trim()];
  return pa != null && pa == pb;
}

/// The pitch class of a note name, 0 for C up to 11 for B, or null when
/// [note] is not exactly a note name.
///
/// Public so there is one table. transposeChord kept a smaller copy without
/// E#, B#, Cb and Fb, so "C#/E#" moved its root and left its bass behind
/// (review, 17 September 2026).
int? pitchOf(String note) => _pitchValues[note];

String noteName(int pitch, {required bool flats}) {
  final index = (pitch % 12 + 12) % 12;
  return flats ? _flatNames[index] : _sharpNames[index];
}

/// A sung note written the way [key] writes it: B♭4 in a flat key, A♯4 in a
/// sharp one.
///
/// [midi] is the number the melody and the tuner both speak in, where 69 is
/// A4, so the octave comes out with the name. The accidentals are the printed
/// ones those two have always used (F♯4, not F#4), and which accidental to use
/// is [spellInKey]'s decision -- the key rule, which is what the chords go
/// through too everywhere except a slash bass. A sung note has no chord to be
/// the third of, so in D minor a D/F♯ over a word can sit above a G♭4 under
/// it: the chord names that pitch from the chord, the note from the key.
String noteInKey(int midi, String? key) {
  final spelled = spellInKey(noteName(midi, flats: false), key)
      .replaceAll('#', '♯')
      .replaceAll('b', '♭');
  return '$spelled${midi ~/ 12 - 1}';
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
  // Written on charts as often as a plain sus4, and until now it came back
  // unrecognised — which is also the answer Simpler shapes got when it went
  // looking for something plainer to draw under a G7sus4 (Every Musician,
  // Same Song, 17 September 2026).
  '7sus4': _Quality('7sus4', 'Dominant 7th suspended 4th', <int>[0, 5, 7, 10], null),
  // Two notes, no third, so it is neither major nor minor. It is here
  // because it is what is left of a chord whose triad a hand cannot make
  // yet — see [simplerShapeFor] — and because people write C5 on charts.
  '5': _Quality('5', 'Fifth', <int>[0, 7], '5'),
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
  '7sus4': '7sus4', '7sus': '7sus4',
  '5': '5',
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
  '7sus4': '7sus4', '5': '5',
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
  // The three fifths that are already under the hand at the nut. Without
  // them E5 and A5 would be drawn seven and five frets up, which is the one
  // place a beginner offered a simpler shape should never be sent.
  'E5': <int>[0, 2, 2, -1, -1, -1],
  'A5': <int>[-1, 0, 2, 2, -1, -1],
  'D5': <int>[-1, -1, 0, 2, 3, -1],
};

/// Movable shapes, written relative to their own barre. The E family is
/// rooted on the sixth string, the A family on the fifth.
const Map<String, List<int>> _eShapes = <String, List<int>>{
  'maj': <int>[1, 3, 3, 2, 1, 1],
  'min': <int>[1, 3, 3, 1, 1, 1],
  '7': <int>[1, 3, 1, 2, 1, 1],
  'min7': <int>[1, 3, 1, 1, 1, 1],
  'maj7': <int>[1, 3, 2, 2, 1, 1],
  // Two fingers and three strings, no barre: the fifth that is left of a
  // chord when the triad is out of reach.
  '5': <int>[1, 3, 3, -1, -1, -1],
};

const Map<String, List<int>> _aShapes = <String, List<int>>{
  'maj': <int>[-1, 1, 3, 3, 3, 1],
  'min': <int>[-1, 1, 3, 3, 2, 1],
  '7': <int>[-1, 1, 3, 1, 3, 1],
  'min7': <int>[-1, 1, 3, 1, 2, 1],
  'maj7': <int>[-1, 1, 3, 2, 3, 1],
  '5': <int>[-1, 1, 3, 3, -1, -1],
};

/// A chord label pulled apart into the three things every reader of one
/// wants: its root, the id of its quality, and the bass under it.
///
/// Both spellings go through here — ChordMini's `A:min7` and a person's
/// `Am7` — and the quality comes out as a key of [_qualities] whenever it is
/// one this knows. Null for a label this cannot read at all, which includes
/// ChordMini's "no chord".
({String root, String quality, String bass})? _chordParts(String label) {
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
  if (_pitchValues[rootText] == null) return null;
  return (root: rootText, quality: qualityToken, bass: bassToken);
}

/// Everything worth saying about one chord.
///
/// Returns null for a stretch with no chord — ChordMini's `N` — so a caller
/// can leave the tap doing nothing rather than opening an empty sheet.
ChordReference? chordReference(String label) {
  final parts = _chordParts(label);
  if (parts == null) return null;
  final rootText = parts.root;
  final qualityToken = parts.quality;
  final bassToken = parts.bass;

  final rootPitch = _pitchValues[rootText]!;
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

/// The three things a shape can ask of the hand, said the same way every
/// time. They are hints a person reads, and they are also what
/// [simplerShapeFor] weighs one shape against another with, so they are
/// written once rather than twice.
const String _openHint = 'Open position';
const String _fifthHint = 'Root and fifth at fret ';
const String _barreHint = 'Barre at fret ';

List<ChordShape> _shapesFor(String rootText, int rootPitch, _Quality quality) {
  final shapes = <ChordShape>[];
  final short = _shortForms[quality.id] ?? '';
  final openName = '$rootText$short';
  // The library is keyed by sharp spelling, so Eb has to ask for D# too.
  final open = _openShapes[openName] ??
      _openShapes['${noteName(rootPitch, flats: false)}$short'];
  if (open != null) {
    shapes.add(ChordShape(name: openName, frets: open, hint: _openHint));
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
        // A fifth is three strings and two fingers wherever it is put, so
        // saying "barre" over one would describe a hand nobody makes.
        hint: family == '5'
            ? '$_fifthHint$fret, root on the $rootString'
            : '$_barreHint$fret, root on the $rootString',
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

/// The triad each quality is built on, for the chords that have something
/// stacked on top of one. A quality that is already three notes — major,
/// minor, diminished, augmented, either sus — is missing from here, because
/// there is nothing to take off it.
///
/// Every Musician, Same Song, 17 September 2026: a beginner stops at the
/// first chord they cannot make, and a Cmaj7 in bar 2 ends the song. The
/// triad under it is a chord they can already play, and every note of it is
/// a note of the chord written — nothing here invents a note.
const Map<String, String> _plainTriads = <String, String>{
  '7': 'maj', 'maj7': 'maj', 'maj6': 'maj', 'add9': 'maj',
  '9': 'maj', 'maj9': 'maj', '11': 'maj', '13': 'maj',
  'min7': 'min', 'min6': 'min', 'min9': 'min',
  'dim7': 'dim', 'hdim7': 'dim',
  '7sus4': 'sus4',
};

/// The plain chord inside [label] — `Cmaj7` is a C, `Am9` an Am, `F#m7♭5` an
/// F♯°, `G7sus4` a Gsus4 — or null when the chord is already plain, or is not
/// one this can read.
///
/// The root and the quality both survive: a minor chord stays minor and a
/// half-diminished keeps the flat fifth that makes it one. What goes is
/// everything stacked above the fifth, which is why the honest line beside it
/// is "changes the sound" and never "easier".
///
/// A slash bass goes too. It is the bass player's note rather than the
/// guitar's — the chord sheet says so already — and no shape here has ever
/// been drawn from one.
String? simplerChord(String label) {
  final parts = _chordParts(label);
  if (parts == null) return null;
  final plain = _plainTriads[parts.quality];
  if (plain == null) return null;
  return '${parts.root}${_shortForms[plain] ?? ''}';
}

/// How much the easiest shape of a chord asks of the hand: an open shape,
/// then the root and fifth (two fingers on three strings), then a barre, and
/// last of all a chord with no shape stored at all.
///
/// This is a coarse order on purpose. It is not a claim about which of two
/// open shapes has more fingers in it; it is the one line a beginner's hand
/// actually stops at, which is the barre.
const int _openRank = 0;
const int _fifthRank = 1;
const int _barreRank = 2;
const int _noShapeRank = 3;

int _handRank(ChordReference? reference) {
  var best = _noShapeRank;
  for (final shape in reference?.shapes ?? const <ChordShape>[]) {
    final hint = shape.hint ?? '';
    final rank = hint == _openHint
        ? _openRank
        : hint.startsWith(_fifthHint)
            ? _fifthRank
            : _barreRank;
    if (rank < best) best = rank;
  }
  return best;
}

/// What to draw instead of [label]'s own shape for somebody reading with
/// Simpler shapes on, or null when there is nothing plainer to draw.
///
/// The triad first, and the fifth where it asks less of the hand than the
/// triad does — but only when the chord really has a plain fifth in it: a
/// power chord over an F♯m7♭5 would put a note in the room that the chord
/// does not contain, and describing a chord is the whole job (Every
/// Musician, Same Song, 17 September 2026).
///
/// Then the one rule that decides whether anything is offered at all:
/// whatever is drawn instead must ask no more of the hand than the chord as
/// written. A seventh is very often the *easier* chord — Fmaj7 is the shape
/// teachers give a beginner precisely so they can leave the F barre alone,
/// and an open B7 is a chord a beginner can play where B is not — so
/// swapping in the triad there would take a sound away and hand back a
/// harder shape for it. When nothing is easier, the chord keeps its own
/// diagram and nothing is said.
ChordReference? simplerShapeFor(String label) {
  final plain = simplerChord(label);
  if (plain == null) return null;

  final parts = _chordParts(label);
  final quality = parts == null ? null : _qualities[parts.quality];
  final triad = chordReference(plain);
  final fifth = quality != null && quality.intervals.contains(7)
      ? chordReference('${parts!.root}5')
      : null;

  final triadRank = _handRank(triad);
  final fifthRank = _handRank(fifth);
  // A tie goes to the triad, because it keeps the third: the fifth is only
  // reached for when it is genuinely the kinder hand — a Bm7 whose triad is
  // a second barre, or a sus chord no diagram exists for.
  final simpler = fifthRank < triadRank ? fifth : triad;
  final simplerRank = fifthRank < triadRank ? fifthRank : triadRank;
  if (simplerRank == _noShapeRank) return null;
  if (simplerRank > _handRank(chordReference(label))) return null;
  return simpler;
}

/// A capo worth putting on for this song, and the open shapes it makes.
class CapoThatHelps {
  const CapoThatHelps({required this.fret, required this.shapes});

  final int fret;

  /// The open shapes the capo leaves under the hand, in the order the song
  /// first reaches for them: `G, C, D`.
  final List<String> shapes;
}

/// The capo between 1 and 7 that leaves the most of [chords] on open shapes
/// and the fewest on barres, or null when no capo is worth the trouble.
///
/// The capo chart on the key sheet has always answered a different question —
/// which shapes this *key* can be played with — and answered it off five
/// major shapes, so it had nothing to say about the Bm in bar 3 or about a
/// song whose key nobody found. This counts the song's own chords (Every
/// Musician, Same Song, 17 September 2026).
///
/// It offers nothing when the song already sits open, when no capo beats no
/// capo, or when the best a capo can do is a single open shape: a song of
/// barre chords that a capo cannot help is told nothing rather than sent up
/// the neck for one chord. Seven frets, like the chart beside it — past that
/// a guitar is a mandolin.
CapoThatHelps? capoThatHelps(List<String> chords) {
  final distinct = <(int, String)>[];
  for (final label in chords) {
    final parts = _chordParts(label);
    final pitch = parts == null ? null : _pitchValues[parts.root];
    if (parts == null || pitch == null) continue;
    final entry = (pitch, parts.quality);
    if (!distinct.contains(entry)) distinct.add(entry);
  }
  // One chord is not a song, and a capo for it is a coin toss.
  if (distinct.length < 2) return null;

  var bestFret = 0;
  var bestOpen = -1;
  var bestBarres = 0;
  var bestShapes = const <String>[];
  for (var fret = 0; fret <= 7; fret += 1) {
    final shapes = <String>[];
    var barres = 0;
    for (final (pitch, quality) in distinct) {
      final open = _openShapeName(((pitch - fret) % 12 + 12) % 12, quality);
      if (open != null) {
        shapes.add(open);
      } else if (_qualities[quality]?.shapeFamily != null) {
        barres += 1;
      }
    }
    // No capo is measured first and only beaten outright, so a tie stays at
    // the nut and a song that is already open is left alone.
    final better = shapes.length > bestOpen ||
        (shapes.length == bestOpen && barres < bestBarres);
    if (better) {
      bestFret = fret;
      bestOpen = shapes.length;
      bestBarres = barres;
      bestShapes = shapes;
    }
  }
  if (bestFret == 0 || bestShapes.length < 2) return null;
  return CapoThatHelps(fret: bestFret, shapes: bestShapes);
}

/// The name of the open shape a chord falls on, or null when it has none.
String? _openShapeName(int pitch, String qualityId) {
  final short = _shortForms[qualityId];
  if (short == null) return null;
  final name = '${noteName(pitch, flats: false)}$short';
  return _openShapes.containsKey(name) ? name : null;
}

/// Where a degree sits, as (the number, the accidental in front of it).
///
/// The seven naturals are the major scale, and the five in between are named
/// the way a chart names them: ♭3 and ♭7 rather than ♯2 and ♯6, because those
/// are the borrowed chords people actually write, and ♯4 rather than ♭5
/// because the tritone chord on a chart is the one going up to the 5.
const List<(String, String)> _degreeNumbers = <(String, String)>[
  ('1', ''),
  ('2', '♭'),
  ('2', ''),
  ('3', '♭'),
  ('3', ''),
  ('4', ''),
  ('4', '♯'),
  ('5', ''),
  ('6', '♭'),
  ('6', ''),
  ('7', '♭'),
  ('7', ''),
];

/// The same twelve counted against the natural minor scale, which is how a
/// harmony class numbers a minor key and how the key sheet's own chips
/// already do (i ii° III iv v VI VII): the chords of the key carry no
/// accidental, and only what comes from outside it does. The raised 6 and 7
/// of the melodic and harmonic forms are ♯6 and ♯7 — except the leading-tone
/// chord, which every harmony textbook writes as a plain vii° (see
/// [_degreeText]).
const List<(String, String)> _minorDegreeNumbers = <(String, String)>[
  ('1', ''),
  ('2', '♭'),
  ('2', ''),
  ('3', ''),
  ('3', '♯'),
  ('4', ''),
  ('4', '♯'),
  ('5', ''),
  ('6', ''),
  ('6', '♯'),
  ('7', ''),
  ('7', '♯'),
];

/// Diminished qualities, which is what makes a chord on the raised 7 of a
/// minor key the leading-tone chord rather than something borrowed.
const Set<String> _diminishedQualityIds = <String>{'dim', 'dim7', 'hdim7'};

const Map<String, String> _romanNumerals = <String, String>{
  '1': 'I', '2': 'II', '3': 'III', '4': 'IV', '5': 'V', '6': 'VI', '7': 'VII',
};

/// A quality written after a number, Nashville style: minor is a dash, which
/// is how it is written on a chart because an "m" beside a number reads as a
/// word. Everything else keeps the glyphs [chordDisplay] and the reference
/// sheets already use, so one chord is spelled one way everywhere.
const Map<String, String> _nashvilleSuffixes = <String, String>{
  'maj': '', 'min': '-', 'dim': '°', 'aug': '+',
  '7': '7', 'maj7': 'maj7', 'min7': '-7', 'dim7': '°7', 'hdim7': '-7♭5',
  'maj6': '6', 'min6': '-6', 'sus2': 'sus2', 'sus4': 'sus4', 'add9': 'add9',
  '7sus4': '7sus4', '5': '5',
  '9': '9', 'min9': '-9', 'maj9': 'maj9', '11': '11', '13': '13',
};

/// The same qualities after a Roman numeral, where minor is already said by
/// the lower case — ii, not ii-. Half-diminished keeps its ø, which is the
/// symbol that notation uses and the one a theory reader expects.
const Map<String, String> _romanSuffixes = <String, String>{
  'maj': '', 'min': '', 'dim': '°', 'aug': '+',
  '7': '7', 'maj7': 'maj7', 'min7': '7', 'dim7': '°7', 'hdim7': 'ø7',
  'maj6': '6', 'min6': '6', 'sus2': 'sus2', 'sus4': 'sus4', 'add9': 'add9',
  '7sus4': '7sus4', '5': '5',
  '9': '9', 'min9': '9', 'maj9': 'maj9', '11': '11', '13': '13',
};

/// Qualities whose numeral is written in lower case: the ones with a minor
/// third in them. A quality this does not know is drawn upper case, which is
/// the plainer of the two guesses.
const Set<String> _minorQualityIds = <String>{
  'min', 'min7', 'min6', 'min9', 'dim', 'dim7', 'hdim7',
};

/// A chord written as its degree of [key]: `1`, `4`, `5`, `2-`, `5/7`, `4/1`
/// in Nashville numbers, or `I`, `IV`, `V`, `ii` in Roman numerals.
///
/// [written] is a chord as a musician writes it — `G`, `Am7`, `G/B` — so
/// Harte labels from the analysis go through [chordDisplay] first, which is
/// also what resolves their degree bass to a note.
///
/// Numbers are the reason Nashville charts survive a singer changing key: the
/// band drops the song a tone and the chart does not change a mark (Every
/// Musician, Same Song, 17 September 2026). So this deliberately takes the
/// song's own key and the chord as stored, and there is nowhere in it for a
/// transpose to get in.
///
/// [fromMinorTonic] picks the Nashville convention for a minor key — see
/// MinorNumbers. It is a Nashville question only: Roman numerals count a
/// minor key from its own tonic against its own scale, so A minor's Am F C G
/// is i VI III VII, which is what a theory class writes and what the key
/// sheet's chips already say (review, 17 September 2026).
///
/// Returns null when [written] or [key] is not something this can read, which
/// is a caller's cue to fall back to letters rather than print a guess.
String? chordAsDegree(
  String written,
  String key, {
  bool roman = false,
  bool fromMinorTonic = false,
}) {
  final keyMatch = RegExp(r'^([A-G][#b]?)\s*(.*)$').firstMatch(key.trim());
  if (keyMatch == null) return null;
  final tonicPitch = _pitchValues[keyMatch.group(1)!];
  if (tonicPitch == null) return null;
  final rest = keyMatch.group(2)!.toLowerCase();
  final minor =
      rest.startsWith('min') || rest == 'm' || rest.startsWith('aeolian');
  // A minor song counted from its relative major is counted from three
  // semitones up: A minor against C, so the home chord is the 6. Only in
  // Nashville numbers, which is the only system that has the choice.
  final relative = minor && !roman && !fromMinorTonic;
  final counted = relative ? tonicPitch + 3 : tonicPitch;
  // Roman numerals in a minor key are counted against the minor scale, so
  // the key's own III, VI and VII carry no flat.
  final minorScale = minor && roman;

  final raw = written.trim();
  if (raw.isEmpty || raw == 'N' || raw == 'X') return null;
  final match = RegExp(r'^([A-G][#b]?)(.*)$').firstMatch(raw);
  if (match == null) return null;
  final rootPitch = _pitchValues[match.group(1)!];
  if (rootPitch == null) return null;

  var suffix = match.group(2)!;
  String? bass;
  final slash = suffix.lastIndexOf('/');
  if (slash >= 0) {
    bass = suffix.substring(slash + 1).trim();
    suffix = suffix.substring(0, slash);
  }

  final qualityId = _writtenSuffixes[suffix];
  final head = _degreeText(
    rootPitch - counted,
    roman: roman,
    minorScale: minorScale,
    qualityId: qualityId,
  );
  // A quality nobody has a spelling for is carried through as the person
  // wrote it. Dropping it would print a different chord, and guessing at it
  // is the thing chordReference already refuses to do.
  final tail = qualityId == null
      ? suffix
      : (roman ? _romanSuffixes : _nashvilleSuffixes)[qualityId] ?? suffix;

  final bassPitch = bass == null || bass.isEmpty ? null : _pitchValues[bass];
  // The bass is a plain number in both readings, never a second numeral: the
  // bass of a slash chord is a note of the key, not a chord of its own, and
  // "5/7" is how a chart writes a V with the leading tone under it. It is
  // counted against the same scale as the chord above it, so a minor song
  // in Roman numerals does not number its bass against a major one.
  final under = bassPitch == null
      ? (bass == null || bass.isEmpty ? '' : '/$bass')
      : '/${_degreeText(bassPitch - counted, roman: false, minorScale: minorScale)}';

  return '$head$tail$under';
}

/// One degree, as a number or a numeral with its accidental in front.
///
/// [minorScale] counts against the natural minor scale rather than the major
/// one — see [_minorDegreeNumbers].
String _degreeText(
  int fromTonic, {
  required bool roman,
  bool minorScale = false,
  String? qualityId,
}) {
  final step = (fromTonic % 12 + 12) % 12;
  final (number, marked) =
      (minorScale ? _minorDegreeNumbers : _degreeNumbers)[step];
  // The leading-tone chord of a minor key is written vii°, not ♯vii°: the
  // harmonic minor's raised 7 is assumed the way every textbook assumes it.
  // Anything else on that note keeps its sharp, so it cannot be misread as
  // the key's own VII a semitone below.
  final leadingTone = minorScale &&
      step == 11 &&
      qualityId != null &&
      _diminishedQualityIds.contains(qualityId);
  final accidental = leadingTone ? '' : marked;
  if (!roman) return '$accidental$number';
  final numeral = _romanNumerals[number]!;
  final lower = qualityId != null && _minorQualityIds.contains(qualityId);
  return '$accidental${lower ? numeral.toLowerCase() : numeral}';
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
