/// What somebody sings in, the way the app keeps it.
///
/// Every Musician, Same Song, 17 September 2026: the languages you sing in
/// and the traditions you work in are declared by the person and never
/// inferred, not from a recording, a name or a city. They are one list on a
/// profile rather than two, so the person decides which words matter to
/// them, and a word two people share becomes a sentence the Open Mic can
/// say on a card. It is never a filter that hides anybody, and never an
/// order: one language is most people's, so a tier built on it would lift
/// everybody who typed "english" over a neighbour who typed nothing.
///
/// No starter chips, on purpose. A row of sixteen suggested languages is a
/// choice about which languages count, and the field is free text so that
/// nobody's is second-class.

/// Spellings of one language or tradition that people type, and the word
/// they are kept as. The same table as `private.sung_in_word` (0156).
///
/// Spellings and the names a language has for itself, not varieties: a
/// person who wrote "Brazilian Portuguese" meant that, and it is kept.
const Map<String, String> _sameWord = <String, String>{
  'português': 'portuguese',
  'portugues': 'portuguese',
  'español': 'spanish',
  'espanol': 'spanish',
  'castellano': 'spanish',
  'français': 'french',
  'francais': 'french',
  'deutsch': 'german',
  'italiano': 'italian',
  'nederlands': 'dutch',
  'gaeilge': 'irish',
  'cymraeg': 'welsh',
  'kiswahili': 'swahili',
  'isizulu': 'zulu',
  'isixhosa': 'xhosa',
  'mandarin chinese': 'mandarin',
  'putonghua': 'mandarin',
  'hindustani classical': 'hindustani',
  'north indian classical': 'hindustani',
  'carnatic classical': 'carnatic',
  'karnatic': 'carnatic',
  'karnatak': 'carnatic',
  'south indian classical': 'carnatic',
};

/// A typed language or tradition as it is kept: lower case, single-spaced,
/// and one spelling for one word, the way `soundWord` keeps a sound.
String sungInWord(String typed) {
  final word = typed.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  return _sameWord[word] ?? word;
}

/// A kept word as it is shown: "portuguese" reads as "Portuguese".
///
/// Words are kept lower case so that two people's match whole, and a
/// language is a proper noun in English, so the first letter comes up when
/// it is read. Only the first: "brazilian portuguese" is somebody's own
/// phrase and the rest of it is left as they wrote it.
String sungInShown(String word) {
  final kept = sungInWord(word);
  if (kept.isEmpty) return '';
  return '${kept[0].toUpperCase()}${kept.substring(1)}';
}

/// The feed's reason line for one word you and somebody both sing in:
/// "Also sings in Portuguese". The same sentence `open_mic_feed` builds
/// (0156).
String alsoSingsIn(String word) {
  final shown = sungInShown(word);
  return shown.isEmpty ? '' : 'Also sings in $shown';
}

/// How long an ask's "what it's in" line may be, as a person counts it.
///
/// This is the `maxLength` of the field on both ask sheets, and Flutter
/// counts that in written characters: "हि" is one.
const int sungInLineLength = 80;

/// How long the same line may be as the database counts it, which is the
/// check on `project_asks.sung_in` (0156).
///
/// Postgres counts code points, and "हि" is two of them. In Devanagari,
/// Tamil or Bengali a written character is often two or three, which are
/// the scripts this line exists for, so a column that stopped at eighty
/// code points refused a Hindi line the field had just accepted and lost
/// the whole ask. Three times the field, so the same visible length fits in
/// every script.
const int sungInLineCodePoints = 240;

/// An ask's line as it is sent: trimmed, and never longer than the column.
///
/// Cut rather than refused, as `ask_musician` does on its side: a line that
/// ran long is not a reason to lose the ask. Counted in code points because
/// that is what the check counts, and cut between them so the end of the
/// line is never half of a character pair.
String sungInLine(String typed) {
  final line = typed.trim();
  if (line.runes.length <= sungInLineCodePoints) return line;
  return String.fromCharCodes(line.runes.take(sungInLineCodePoints))
      .trimRight();
}
