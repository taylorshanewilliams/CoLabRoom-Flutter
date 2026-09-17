/// Words for what somebody sounds like, the way the app offers them.
///
/// One list, used by the first-run tour and by Open Mic settings. There were
/// two, and they spelled the same music two ways -- "hip-hop" in the tour,
/// "hip hop" in settings -- while `sounds_like` matches whole words, so the
/// two people never counted as sounding alike (audit, 17 September 2026).
/// Still free text: these save typing, they do not close the vocabulary.
const List<String> soundStarters = <String>[
  'indie', 'folk', 'rock', 'pop', 'singer-songwriter', 'hip-hop',
  'r&b', 'soul', 'country', 'jazz', 'blues', 'metal',
  'punk', 'electronic', 'worship', 'acoustic', 'lo-fi', 'americana',
  'bluegrass', 'gospel', 'ambient', 'house', 'reggae', 'afrobeats',
  'latin', 'k-pop', 'classical', 'experimental',
];

/// Spellings of one sound that people type, and the word they are kept as.
/// The same table as `private.one_sound_word` (0135).
const Map<String, String> _sameSound = <String, String>{
  'hip hop': 'hip-hop',
  'hiphop': 'hip-hop',
  'lo fi': 'lo-fi',
  'lofi': 'lo-fi',
  'rnb': 'r&b',
  'r and b': 'r&b',
  'r & b': 'r&b',
  'r n b': 'r&b',
  'k pop': 'k-pop',
  'kpop': 'k-pop',
  'singer songwriter': 'singer-songwriter',
  'alt country': 'alt-country',
  'altcountry': 'alt-country',
};

/// A typed sound as it is kept: lower case, single-spaced, and one spelling
/// for one sound.
String soundWord(String typed) {
  final word = typed.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  return _sameSound[word] ?? word;
}
