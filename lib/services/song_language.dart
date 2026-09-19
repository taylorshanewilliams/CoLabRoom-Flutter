/// What language a song is sung in, and what that does to the page.
///
/// Every Musician, Same Song, 17 September 2026, world traditions item 3: a
/// song in Arabic was laid out left to right with its chords over the wrong
/// end of every line, and a song in Chinese put every chord in the line over
/// its first character, because a line with no spaces in it is one word to a
/// `split(RegExp(r'\s+'))`. Both are the same bug seen twice — the sheet
/// assumed one way of writing words down.
///
/// **Declared, never inferred.** The language is a shared fact about the
/// song, said by the room's owner or an editor (migration 0163), exactly as
/// the band's key (0144) and where bar 1 is (0161) are. Nothing here reads
/// it off the characters, off the recording or off anybody's profile: a song
/// nobody has said anything about is laid out the way it always was, and
/// that is the honest answer rather than a guess that is right most of the
/// time. The plan rules out inferring a person's language by name.
///
/// **A tag, because a tag is what a transcriber takes.** The language also
/// goes to the transcriber as a hint, and Whisper wants an ISO code rather
/// than a word, so this is kept as a BCP-47 tag. That means a list of
/// languages this app can name — which is a choice about which languages it
/// can name, and nothing else: [languageTagTyped] takes a tag nobody's list
/// has, so a language missing from [songLanguages] is still a language.
library;

import 'package:colabroom/domain/sung_in.dart';
// For `String.characters`, which is what splits a line of Thai or Chinese
// into the pieces a chord sits over. Flutter re-exports package:characters
// from widgets.dart, and nothing else here needs a widget.
import 'package:flutter/widgets.dart';

/// A language the app can name, for the list somebody picks from.
///
/// [endonym] is the name the language has for itself, beside the English
/// one. Somebody looking for their own language should not have to know what
/// English calls it.
class SongLanguage {
  const SongLanguage(this.tag, this.name, this.endonym);

  /// The BCP-47 tag as it is stored: 'ar', 'pt', 'zh'.
  final String tag;

  /// What English calls it.
  final String name;

  /// What it calls itself, or '' where that is the same word.
  final String endonym;

  /// The name on one line: "Arabic · العربية".
  String get shown => endonym.isEmpty ? name : '$name · $endonym';
}

/// The languages offered by name, in English alphabetical order.
///
/// Not a ranking and not a claim about which languages matter: it is the set
/// this app can put a name beside a tag for. Anything else is typed in as a
/// tag and stored exactly the same way.
const List<SongLanguage> songLanguages = <SongLanguage>[
  SongLanguage('af', 'Afrikaans', ''),
  SongLanguage('sq', 'Albanian', 'Shqip'),
  SongLanguage('am', 'Amharic', 'አማርኛ'),
  SongLanguage('ar', 'Arabic', 'العربية'),
  SongLanguage('hy', 'Armenian', 'Հայերեն'),
  SongLanguage('bn', 'Bengali', 'বাংলা'),
  SongLanguage('bs', 'Bosnian', 'Bosanski'),
  SongLanguage('bg', 'Bulgarian', 'Български'),
  SongLanguage('my', 'Burmese', 'မြန်မာ'),
  SongLanguage('yue', 'Cantonese', '廣東話'),
  SongLanguage('ca', 'Catalan', 'Català'),
  SongLanguage('zh', 'Chinese', '中文'),
  SongLanguage('hr', 'Croatian', 'Hrvatski'),
  SongLanguage('cs', 'Czech', 'Čeština'),
  SongLanguage('da', 'Danish', 'Dansk'),
  SongLanguage('nl', 'Dutch', 'Nederlands'),
  SongLanguage('en', 'English', ''),
  SongLanguage('et', 'Estonian', 'Eesti'),
  SongLanguage('fil', 'Filipino', ''),
  SongLanguage('fi', 'Finnish', 'Suomi'),
  SongLanguage('fr', 'French', 'Français'),
  SongLanguage('ka', 'Georgian', 'ქართული'),
  SongLanguage('de', 'German', 'Deutsch'),
  SongLanguage('el', 'Greek', 'Ελληνικά'),
  SongLanguage('gu', 'Gujarati', 'ગુજરાતી'),
  SongLanguage('ha', 'Hausa', ''),
  SongLanguage('he', 'Hebrew', 'עברית'),
  SongLanguage('hi', 'Hindi', 'हिन्दी'),
  SongLanguage('hu', 'Hungarian', 'Magyar'),
  SongLanguage('is', 'Icelandic', 'Íslenska'),
  SongLanguage('ig', 'Igbo', ''),
  SongLanguage('id', 'Indonesian', 'Bahasa Indonesia'),
  SongLanguage('ga', 'Irish', 'Gaeilge'),
  SongLanguage('it', 'Italian', 'Italiano'),
  SongLanguage('ja', 'Japanese', '日本語'),
  SongLanguage('kn', 'Kannada', 'ಕನ್ನಡ'),
  SongLanguage('km', 'Khmer', 'ភាសាខ្មែរ'),
  SongLanguage('ko', 'Korean', '한국어'),
  SongLanguage('ckb', 'Kurdish (Sorani)', 'کوردی'),
  SongLanguage('lo', 'Lao', 'ລາວ'),
  SongLanguage('lv', 'Latvian', 'Latviešu'),
  SongLanguage('lt', 'Lithuanian', 'Lietuvių'),
  SongLanguage('mk', 'Macedonian', 'Македонски'),
  SongLanguage('ms', 'Malay', 'Bahasa Melayu'),
  SongLanguage('ml', 'Malayalam', 'മലയാളം'),
  SongLanguage('mt', 'Maltese', 'Malti'),
  SongLanguage('mr', 'Marathi', 'मराठी'),
  SongLanguage('ne', 'Nepali', 'नेपाली'),
  SongLanguage('nb', 'Norwegian', 'Norsk'),
  SongLanguage('ps', 'Pashto', 'پښتو'),
  SongLanguage('fa', 'Persian', 'فارسی'),
  SongLanguage('pl', 'Polish', 'Polski'),
  SongLanguage('pt', 'Portuguese', 'Português'),
  SongLanguage('pa', 'Punjabi', 'ਪੰਜਾਬੀ'),
  SongLanguage('ro', 'Romanian', 'Română'),
  SongLanguage('ru', 'Russian', 'Русский'),
  SongLanguage('gd', 'Scottish Gaelic', 'Gàidhlig'),
  SongLanguage('sr', 'Serbian', 'Српски'),
  SongLanguage('si', 'Sinhala', 'සිංහල'),
  SongLanguage('sk', 'Slovak', 'Slovenčina'),
  SongLanguage('sl', 'Slovenian', 'Slovenščina'),
  SongLanguage('so', 'Somali', 'Soomaali'),
  SongLanguage('es', 'Spanish', 'Español'),
  SongLanguage('sw', 'Swahili', 'Kiswahili'),
  SongLanguage('sv', 'Swedish', 'Svenska'),
  SongLanguage('ta', 'Tamil', 'தமிழ்'),
  SongLanguage('te', 'Telugu', 'తెలుగు'),
  SongLanguage('th', 'Thai', 'ไทย'),
  SongLanguage('bo', 'Tibetan', 'བོད་སྐད'),
  SongLanguage('tr', 'Turkish', 'Türkçe'),
  SongLanguage('uk', 'Ukrainian', 'Українська'),
  SongLanguage('ur', 'Urdu', 'اردو'),
  SongLanguage('vi', 'Vietnamese', 'Tiếng Việt'),
  SongLanguage('cy', 'Welsh', 'Cymraeg'),
  SongLanguage('xh', 'Xhosa', 'isiXhosa'),
  SongLanguage('yi', 'Yiddish', 'ייִדיש'),
  SongLanguage('yo', 'Yoruba', 'Yorùbá'),
  SongLanguage('zu', 'Zulu', 'isiZulu'),
];

/// The shape a stored tag has: a language, optionally a script, optionally a
/// region. The same expression migration 0163 checks the column with, so a
/// tag this app will store is a tag the database will take.
final RegExp _tagShape =
    RegExp(r'^([A-Za-z]{2,3})(?:-([A-Za-z]{4}))?(?:-([A-Za-z]{2}|[0-9]{3}))?$');

/// A typed or stored tag in the one spelling everything else here expects:
/// language lower case, script capitalised, region upper case — 'zh-Hans-CN'
/// however it arrived. Null for anything that is not a tag at all, and for
/// nothing, which is what a song nobody has answered for has.
///
/// The app only ever sends tags it took from [songLanguages], so this is
/// mostly for what somebody types by hand and for what comes back from a
/// server that was written by an older build.
String? languageTagTyped(String? raw) {
  final typed = (raw ?? '').trim();
  if (typed.isEmpty) return null;
  final match = _tagShape.firstMatch(typed);
  if (match == null) return null;
  final script = match.group(2);
  final region = match.group(3);
  return <String>[
    match.group(1)!.toLowerCase(),
    if (script != null)
      '${script[0].toUpperCase()}${script.substring(1).toLowerCase()}',
    if (region != null) region.toUpperCase(),
  ].join('-');
}

/// Tags the transcriber spells differently from this list.
///
/// The same map as `WHISPER_ALIASES` in
/// supabase/functions/_shared/whisper_languages.ts, which is where the tag
/// actually becomes what Whisper is told — this copy exists only so the app
/// can tell whether two answers are the same instruction. Norwegian is the
/// one that matters in practice: this list stores the Bokmål tag and the
/// transcriber only knows 'no', so without this a Norwegian song would be
/// offered a re-listen that heard it in the language it was already heard in.
const Map<String, String> _transcriberSpells = <String, String>{
  'nb': 'no',
  'nn': 'no',
  'fil': 'tl',
  'yue': 'zh',
  'iw': 'he',
  'ji': 'yi',
  'in': 'id',
  'mo': 'ro',
};

/// The language part of a tag as the transcriber hears it: 'ar' from 'ar-EG',
/// 'zh' from 'zh-Hans', 'no' from 'nb'.
///
/// What a transcriber is given, because Whisper's `language` takes an ISO
/// code and nothing after it — so this is also the only honest way to ask
/// whether two answers mean the same thing to it.
String? languageOf(String? tag) {
  final base = languageTagTyped(tag)?.split('-').first;
  if (base == null) return null;
  return _transcriberSpells[base] ?? base;
}

/// The language named, for a sheet or a sentence: "Arabic", "Chinese", or
/// the tag itself when it is one the list has no name for.
String languageNamed(String? tag) {
  final clean = languageTagTyped(tag);
  if (clean == null) return '';
  for (final language in songLanguages) {
    if (language.tag == clean) return language.name;
  }
  final base = clean.split('-').first;
  for (final language in songLanguages) {
    if (language.tag == base) return language.name;
  }
  return clean;
}

/// Scripts written from the right, whatever language is written in them.
const Set<String> _rightToLeftScripts = <String>{
  'Arab',
  'Hebr',
  'Syrc',
  'Thaa',
  'Nkoo',
  'Adlm',
};

/// Languages written from the right in their usual script.
const Set<String> _rightToLeftLanguages = <String>{
  'ar', // Arabic
  'arc', // Aramaic
  'ckb', // Sorani Kurdish
  'dv', // Dhivehi
  'fa', // Persian
  'he', // Hebrew
  'iw', // Hebrew, the old tag
  'ji', // Yiddish, the old tag
  'ks', // Kashmiri
  'ps', // Pashto
  'sd', // Sindhi
  'ug', // Uyghur
  'ur', // Urdu
  'yi', // Yiddish
};

/// Whether a song in this language is read from the right.
///
/// The script decides it where one is written down, because the same
/// language can be written both ways — Punjabi in Gurmukhi runs left to
/// right and the same Punjabi in Shahmukhi runs right to left, and only the
/// tag says which.
bool readsRightToLeft(String? tag) {
  final clean = languageTagTyped(tag);
  if (clean == null) return false;
  final parts = clean.split('-');
  if (parts.length > 1 && _rightToLeftScripts.contains(parts[1])) return true;
  if (parts.length > 1 && parts[1].length == 4) {
    // A script was named and it is not one of the six above, so the language
    // is being written left to right whatever it usually does.
    return false;
  }
  return _rightToLeftLanguages.contains(parts.first);
}

/// Scripts that put nothing between one word and the next, and that this app
/// can safely cut into pieces.
///
/// Khmer, Burmese and Tibetan are deliberately not here, and neither are
/// their languages below. They are written without spaces too, but a piece of
/// one of them is an orthographic syllable and not a grapheme cluster: Dart
/// cuts ស្រឡាញ់ into ស្ រ ឡា ញ់, which separates the coeng from the consonant
/// it subjoins and draws marks on dotted circles, and Burmese comes apart the
/// same way at its stacked consonants. Cutting a line into broken glyphs is
/// worse than leaving it whole, so a song in those languages is laid out the
/// way it was before anybody said anything — every chord on the first word,
/// which is wrong but at least readable. Getting them right needs somebody
/// who reads them (review, 18 September 2026).
const Set<String> _spacelessScripts = <String>{
  'Hans',
  'Hant',
  'Hani',
  'Jpan',
  'Hira',
  'Kana',
  'Thai',
  'Laoo',
};

/// Languages usually written with no spaces between words.
///
/// Korean is deliberately not here: it is written in its own script and
/// spaces its words, so it splits like English does. See the scripts above
/// for why Khmer, Burmese and Tibetan are not here either.
const Set<String> _spacelessLanguages = <String>{
  'zh', // Chinese
  'yue', // Cantonese
  'ja', // Japanese
  'th', // Thai
  'lo', // Lao
};

/// Whether a chord in this language sits over a character rather than over a
/// word.
///
/// In a script with no spaces the whole line is one "word", so every chord
/// in it landed over the first character. A character is the unit a singer
/// reads in these languages and the unit a chord is written over in every
/// printed songbook in them.
bool anchorsByCharacter(String? tag) {
  final clean = languageTagTyped(tag);
  if (clean == null) return false;
  final parts = clean.split('-');
  if (parts.length > 1 && parts[1].length == 4) {
    return _spacelessScripts.contains(parts[1]);
  }
  return _spacelessLanguages.contains(parts.first);
}

/// The pieces of a line a chord can sit over: its words, or — in a script
/// that does not space them — its characters.
///
/// The one place a sheet line is broken up, so the sheet, Perform, the
/// printed chart, the ChordPro file and the chord editor cannot disagree
/// about which piece a chord belongs to. Chord placement is by index into
/// this list (see chordPlacementsForLine), and two lists of different
/// lengths would put the same chord over two different words on two pages
/// of the same song.
///
/// Characters are grapheme clusters, not code units: a Thai vowel sign and
/// the consonant it is written on are one thing to read and one thing to
/// hang a chord over, and an emoji somebody typed into a lyric is one
/// character rather than two halves of a surrogate pair.
List<String> lyricUnits(String body, {String? language}) {
  if (anchorsByCharacter(language)) return _unitsByCharacter(body);
  return body
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .toList(growable: false);
}

/// Characters written without spaces between them: the CJK ideographs and
/// their punctuation, kana, the fullwidth forms, Thai and Lao.
///
/// Used both to decide what gets a piece of its own and to decide whether two
/// pieces need a space between them when the line is written back out.
bool _writtenWithoutSpaces(int rune) =>
    (rune >= 0x2E80 && rune <= 0x303F) || // CJK radicals, symbols, punctuation
    (rune >= 0x3040 && rune <= 0x30FF) || // Hiragana and katakana
    (rune >= 0x3400 && rune <= 0x4DBF) || // CJK, extension A
    (rune >= 0x4E00 && rune <= 0x9FFF) || // CJK
    (rune >= 0xF900 && rune <= 0xFAFF) || // CJK compatibility
    (rune >= 0xFF01 && rune <= 0xFF9F) || // Fullwidth forms, halfwidth kana
    (rune >= 0x20000 && rune <= 0x2FA1F) || // CJK, the later extensions
    (rune >= 0x0E00 && rune <= 0x0E7F) || // Thai
    (rune >= 0x0E80 && rune <= 0x0EFF); // Lao

/// Characters that belong in front of whatever comes after them: an opening
/// bracket or quote, and the Thai and Lao vowels that are typed before the
/// consonant they are read after.
///
/// เ in เขา is a piece of that syllable and not a syllable, so it must not be
/// drawn on its own with a chord of its own above it (review, 18 September
/// 2026).
const Set<int> _leadsTheNext = <int>{
  0x0E40, 0x0E41, 0x0E42, 0x0E43, 0x0E44, // Thai, the vowels written first
  0x0EC0, 0x0EC1, 0x0EC2, 0x0EC3, 0x0EC4, // Lao, the same five
  0x28, 0x5B, 0x7B, // ( [ {
  0x201C, 0x2018, // “ ‘
  0xFF08, 0xFF3B, 0xFF5B, // （ ［ ｛
  0x300C, 0x300E, 0x300A, 0x3008, 0x3010, 0x3014, // 「 『 《 〈 【 〔
};

/// Characters that belong to whatever came before them: closing brackets and
/// quotes, the punctuation that ends a phrase, the Thai and Lao vowels that
/// are written after their consonant but are part of its syllable, and the
/// Japanese marks that only ever extend the character in front of them.
const Set<int> _trailsThePrevious = <int>{
  0x0E30, 0x0E32, 0x0E33, 0x0E45, 0x0E46, // Thai ะ า ำ ๅ ๆ
  0x0E2F, 0x0E4F, 0x0E5A, 0x0E5B, // Thai ฯ ๏ ๚ ๛
  0x0EB0, 0x0EB2, 0x0EB3, 0x0EC6, // Lao ະ າ ຳ ໆ
  0x21, 0x2C, 0x2E, 0x29, 0x3A, 0x3B, 0x3F, 0x5D, 0x7D, // ! , . ) : ; ? ] }
  0x201D, 0x2019, 0x2026, // ” ’ …
  0x3001, 0x3002, 0x3005, 0x309D, 0x309E, // 、 。 々 ゝ ゞ
  0x30FB, 0x30FC, 0x30FD, 0x30FE, // ・ ー ヽ ヾ
  0x300D, 0x300F, 0x300B, 0x3009, 0x3011, 0x3015, // 」 』 》 〉 】 〕
  0xFF01, 0xFF0C, 0xFF0E, 0xFF09, 0xFF1A, 0xFF1B, 0xFF1F, // ！ ， ． ） ： ； ？
  0xFF3D, 0xFF5D, // ］ ｝
};

/// The pieces of a line in a script that does not space its words.
///
/// A character of that script is a piece of its own, which is what puts one
/// chord over one character. Everything else is not: a run of Latin letters
/// or digits stays one piece, because English inside a Chinese, Japanese or
/// Thai lyric is ordinary and drawing "baby" as b a b y with a chord slot
/// over each letter is not a page anybody has seen; punctuation joins the
/// piece it belongs to rather than standing on its own and taking a chord
/// with it; and white space is a boundary between pieces rather than a piece
/// (review, 18 September 2026).
List<String> _unitsByCharacter(String body) {
  final units = <String>[];
  // Characters waiting to lead whatever piece comes next.
  var leading = '';
  // A run of letters or digits from a script that does space its words.
  final run = StringBuffer();

  void closeRun() {
    if (run.isEmpty) return;
    units.add('$leading$run');
    leading = '';
    run.clear();
  }

  for (final cluster in body.characters) {
    if (cluster.trim().isEmpty) {
      closeRun();
      continue;
    }
    final rune = cluster.runes.first;
    if (_leadsTheNext.contains(rune)) {
      closeRun();
      leading = '$leading$cluster';
    } else if (_trailsThePrevious.contains(rune)) {
      if (run.isNotEmpty) {
        run.write(cluster);
      } else if (leading.isEmpty && units.isNotEmpty) {
        units[units.length - 1] = '${units.last}$cluster';
      } else {
        // Nothing to trail — it opens the line, so it leads instead.
        leading = '$leading$cluster';
      }
    } else if (_writtenWithoutSpaces(rune)) {
      closeRun();
      units.add('$leading$cluster');
      leading = '';
    } else {
      run.write(cluster);
    }
  }
  closeRun();
  if (leading.isNotEmpty) {
    if (units.isEmpty) {
      units.add(leading);
    } else {
      units[units.length - 1] = '${units.last}$leading';
    }
  }
  return List<String>.unmodifiable(units);
}

/// What goes between two units when the line is written back out as one
/// string.
///
/// A space between two words, and nothing between two characters of a script
/// that is written without them — but a space where the two sides are not
/// both such characters, because "baby" and "you" run together into one word
/// otherwise, and that would be a worse line than the one this fixes.
String unitGapBetween(String before, String after, String? language) {
  if (!anchorsByCharacter(language)) return ' ';
  if (before.isEmpty || after.isEmpty) return '';
  return _writtenWithoutSpaces(before.runes.last) &&
          _writtenWithoutSpaces(after.runes.first)
      ? ''
      : ' ';
}

/// A line's pieces, written back out as one string.
///
/// The one thing that knows the loss in this: a space somebody put between
/// two phrases of a Chinese line is a boundary between pieces and is not
/// written back out, because a piece does not remember what followed it. It
/// costs a phrase break in an exported file and nothing on the page, where
/// the pieces are set apart anyway.
String joinLyricUnits(List<String> units, String? language) {
  final out = StringBuffer();
  for (var index = 0; index < units.length; index += 1) {
    if (index > 0) {
      out.write(unitGapBetween(units[index - 1], units[index], language));
    }
    out.write(units[index]);
  }
  return out.toString();
}

/// Words somebody may have written on their own profile that name a
/// language this app has a tag for, where the word is not simply the English
/// name (which is matched directly below).
///
/// Kept in the folded spelling `sungInWord` stores (0156), so 'Português'
/// on a profile finds Portuguese here the same way it finds another singer.
const Map<String, String> _sungInTags = <String, String>{
  'mandarin': 'zh',
  'putonghua': 'zh',
  'farsi': 'fa',
  'castilian': 'es',
  'tagalog': 'fil',
  'bahasa indonesia': 'id',
  'bahasa melayu': 'ms',
  'flemish': 'nl',
  'castellano': 'es',
};

/// The tags a writer's own declared languages suggest, in the order they
/// declared them (0156).
///
/// Offered as a default when somebody says what a song is sung in, never
/// applied: a person who sings in three languages has not told this app
/// which one this song is, and nothing about a song is inferred from a
/// profile. A word that is a tradition rather than a language — 'carnatic',
/// 'hindustani' — matches nothing here and is simply not offered.
List<String> languageTagsSuggestedBy(Iterable<String> singsIn) {
  final found = <String>[];
  for (final raw in singsIn) {
    final word = sungInWord(raw);
    if (word.isEmpty) continue;
    final alias = _sungInTags[word];
    if (alias != null) {
      if (!found.contains(alias)) found.add(alias);
      continue;
    }
    for (final language in songLanguages) {
      if (language.name.toLowerCase() == word ||
          language.endonym.toLowerCase() == word) {
        if (!found.contains(language.tag)) found.add(language.tag);
        break;
      }
    }
  }
  return List<String>.unmodifiable(found);
}
