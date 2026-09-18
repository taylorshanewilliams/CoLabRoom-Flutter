/// What somebody sings in, the way the app keeps it.
///
/// Every Musician, Same Song, 17 September 2026: the languages you sing in
/// and the traditions you work in are declared by the person and never
/// inferred, not from a recording, a name or a city. They are one list on a
/// profile rather than two, so the person decides which words matter to
/// them, and they become closeness reasons in the Open Mic ordering, never a
/// filter that hides anybody.
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
