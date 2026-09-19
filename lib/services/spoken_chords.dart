/// Saying a chord out loud.
///
/// A chord on the page is a symbol — `F♯m7`, `♭6`, `vii°`, `5/7` — and a
/// symbol read straight into a voice is noise: a screen reader spells `Gm7`
/// letter by letter, and a beat-ahead call has to be a thing somebody shouts
/// across a stage. So each reading gets the words a musician actually says
/// (Every Musician, Same Song, 17 September 2026, "feel the beat, hear the
/// chords coming").
///
/// Whatever reading the chord arrived in. This takes what [chordAsRead] gives
/// the page — letters in this person's key, their instrument's written pitch,
/// their capo's shapes, or the number the chord is of the song's key — and
/// says that, so what is heard is what is printed and never a second opinion
/// about the chord.
///
/// A plain major triad is said as its bare name: "C", not "C major". That is
/// what somebody calling a band through a song says out loud, and it is the
/// whole of the name for the commonest chord there is — a beat is not long
/// enough to spend two words on the ordinary case. Everything else carries
/// its quality, because what else a chord might be is the thing the player
/// needs to hear. The chord diagrams say "G major" instead (#357), and they
/// are right to: there a screen reader is describing a picture nobody is
/// playing along to, with a whole sentence of strings and frets behind it.
library;

/// A sharp or a flat, however the page happened to spell it: the chord names
/// come through with ASCII accidentals and the degree numbers with the
/// typographer's ones.
const Map<String, String> _accidentals = <String, String>{
  '#': 'sharp',
  '♯': 'sharp',
  'b': 'flat',
  '♭': 'flat',
};

/// Degrees as they are counted out loud, which is the same handful of words
/// for a Nashville number and for a Roman numeral: a player reading IV says
/// "four", the same as the one reading 4.
const Map<String, String> _degreeWords = <String, String>{
  '1': 'one', '2': 'two', '3': 'three', '4': 'four',
  '5': 'five', '6': 'six', '7': 'seven',
  'I': 'one', 'II': 'two', 'III': 'three', 'IV': 'four',
  'V': 'five', 'VI': 'six', 'VII': 'seven',
};

/// What a chord's quality is called, piece by piece, longest spelling first.
///
/// Read left to right off the front of whatever follows the root, so the
/// pieces add up rather than needing a row per combination: `m7♭5` is minor,
/// then seven, then flat five — which is exactly how it is said. Case is
/// carried because case is meaning: `m` is minor and `M` is major, and
/// `mMaj7` is both.
const List<(String, String)> _qualityWords = <(String, String)>[
  ('maj7', 'major seven'),
  ('Maj7', 'major seven'),
  ('maj9', 'major nine'),
  ('Maj9', 'major nine'),
  ('maj6', 'major six'),
  ('min7', 'minor seven'),
  ('min9', 'minor nine'),
  ('min6', 'minor six'),
  ('dim7', 'diminished seven'),
  ('sus2', 'sus two'),
  ('sus4', 'sus four'),
  ('add9', 'add nine'),
  ('maj', 'major'),
  ('Maj', 'major'),
  ('min', 'minor'),
  ('dim', 'diminished'),
  ('aug', 'augmented'),
  ('sus', 'sus'),
  ('add', 'add'),
  ('11', 'eleven'),
  ('13', 'thirteen'),
  ('°', 'diminished'),
  ('ø', 'half diminished'),
  ('Δ', 'major'),
  ('+', 'augmented'),
  ('-', 'minor'),
  ('m', 'minor'),
  ('M', 'major'),
  ('♭', 'flat'),
  ('b', 'flat'),
  ('♯', 'sharp'),
  ('#', 'sharp'),
  ('2', 'two'),
  ('3', 'three'),
  ('4', 'four'),
  ('5', 'five'),
  ('6', 'six'),
  ('7', 'seven'),
  ('9', 'nine'),
  ('1', 'one'),
];

/// The qualities that already say there is a minor third in the chord, so a
/// lower-case numeral beside one does not say it twice: `vii°` is "seven
/// diminished", never "seven minor diminished".
const Set<String> _saysMinorAlready = <String>{'°', 'ø'};

final RegExp _letterChord = RegExp(r'^([A-G])([#♯b♭]?)');
final RegExp _numberChord = RegExp(r'^([#♯b♭]?)([1-7])');
final RegExp _romanChord =
    RegExp(r'^([#♯b♭]?)(VII|VI|V|IV|III|II|I|vii|vi|v|iv|iii|ii|i)');
final RegExp _runsOfSpace = RegExp(r'\s+');

/// A chord said out loud: "F sharp minor seven", "flat six", "G over B".
///
/// [written] is the chord as it appears on the page, in whichever reading the
/// person has chosen — letters, a Nashville number or a Roman numeral. An
/// empty string for a stretch with no chord in it, so a caller says nothing
/// rather than saying "N".
///
/// A spelling this cannot read comes back as it was written. A voice reading
/// a symbol awkwardly is a poor call; a voice confidently saying a different
/// chord is a wrong one, and this never guesses.
String speakableChord(String written) {
  final raw = written.trim();
  if (raw.isEmpty || raw == 'N' || raw == 'X') return '';

  // The bass of a slash chord, which is said the way it is written: "G over
  // B", "five over seven". Counted after the chord above it, and in the same
  // reading, because that is how it reached the page.
  final slash = raw.lastIndexOf('/');
  if (slash > 0) {
    final chord = speakableChord(raw.substring(0, slash));
    if (chord.isEmpty) return '';
    final bass = speakableChord(raw.substring(slash + 1));
    return bass.isEmpty ? chord : '$chord over $bass';
  }

  final letter = _letterChord.firstMatch(raw);
  if (letter != null) {
    final accidental = _accidentals[letter.group(2)!];
    final head = accidental == null
        ? letter.group(1)!
        : '${letter.group(1)!} $accidental';
    return _tidy('$head ${_quality(raw.substring(letter.end))}');
  }

  final number = _numberChord.firstMatch(raw);
  if (number != null) {
    return _tidy('${_degree(number)} ${_quality(raw.substring(number.end))}');
  }

  final roman = _romanChord.firstMatch(raw);
  if (roman != null) {
    final numeral = roman.group(2)!;
    final rest = raw.substring(roman.end);
    // A lower-case numeral is how a Roman reading writes minor, so it has to
    // be said: "ii" is a two minor, and a voice saying "two" would be naming
    // the wrong chord.
    final minor = numeral == numeral.toLowerCase() &&
            !_saysMinorAlready.contains(rest.isEmpty ? '' : rest[0])
        ? ' minor'
        : '';
    return _tidy('${_degree(roman)}$minor ${_quality(rest)}');
  }

  return raw;
}

/// A degree with its accidental in front of it, the way both number readings
/// write one: "flat six", "sharp four".
String _degree(RegExpMatch match) {
  final accidental = _accidentals[match.group(1)!];
  final number = _degreeWords[match.group(2)!.toUpperCase()] ?? match.group(2)!;
  return accidental == null ? number : '$accidental $number';
}

/// Everything after the root, in words.
String _quality(String suffix) {
  final said = StringBuffer();
  var at = 0;
  while (at < suffix.length) {
    final word = _wordAt(suffix, at);
    if (word == null) {
      // Not a spelling this knows — a quality somebody typed by hand, or a
      // bracket the analysis carried through. Kept as it was written rather
      // than dropped, because dropping it would name a different chord.
      said.write(suffix[at]);
      at += 1;
      continue;
    }
    said.write(' ${word.$2}');
    at += word.$1.length;
  }
  return said.toString();
}

(String, String)? _wordAt(String suffix, int at) {
  for (final (spelling, word) in _qualityWords) {
    if (suffix.startsWith(spelling, at)) return (spelling, word);
  }
  return null;
}

String _tidy(String said) => said.replaceAll(_runsOfSpace, ' ').trim();
