// What the transcriber is told a song is sung in, and when a transcript it
// already made is an answer to that question.
//
// Every Musician, Same Song, 17 September 2026, world traditions item 3. The
// song carries the language its room declared (migration 0163) and that fact
// has two consumers now: `transcribe-audio`, which is the fallback and the
// "listen again" path, and `analyze-chords`, which is the first listen and
// where nearly every transcript in the app actually comes from. They have to
// cut a BCP-47 tag down to a code the same way, or the same song would be
// heard in two different languages depending on which path ran — so the
// mapping lives here rather than in either of them.

/// The codes Whisper itself knows, which is the list the API validates
/// `language` against. Anything else comes back as a 400, and a 400 there is
/// a failed transcription — so a language Whisper has never heard of has to
/// be left out rather than forwarded. faster-whisper knows the same set and
/// refuses an unknown code before it decodes anything, so one list serves
/// both.
const WHISPER_LANGUAGES = new Set<string>([
  'af', 'am', 'ar', 'as', 'az', 'ba', 'be', 'bg', 'bn', 'bo', 'br', 'bs',
  'ca', 'cs', 'cy', 'da', 'de', 'el', 'en', 'es', 'et', 'eu', 'fa', 'fi',
  'fo', 'fr', 'gl', 'gu', 'ha', 'haw', 'he', 'hi', 'hr', 'ht', 'hu', 'hy',
  'id', 'is', 'it', 'ja', 'jw', 'ka', 'kk', 'km', 'kn', 'ko', 'la', 'lb',
  'ln', 'lo', 'lt', 'lv', 'mg', 'mi', 'mk', 'ml', 'mn', 'mr', 'ms', 'mt',
  'my', 'ne', 'nl', 'nn', 'no', 'oc', 'pa', 'pl', 'ps', 'pt', 'ro', 'ru',
  'sa', 'sd', 'si', 'sk', 'sl', 'sn', 'so', 'sq', 'sr', 'su', 'sv', 'sw',
  'ta', 'te', 'tg', 'th', 'tk', 'tl', 'tr', 'tt', 'uk', 'ur', 'uz', 'vi',
  'yi', 'yo', 'zh',
]);

/// Tags the app can store that Whisper spells differently.
///
/// Norwegian is the one that matters in practice: the language list stores
/// the Bokmål tag, and Whisper only knows 'no'. Cantonese is not a separate
/// language to Whisper at all, and asking for Chinese is much closer than
/// asking for nothing.
const WHISPER_ALIASES: Record<string, string> = {
  nb: 'no',
  nn: 'no',
  fil: 'tl',
  yue: 'zh',
  iw: 'he',
  ji: 'yi',
  in: 'id',
  mo: 'ro',
};

/// The language a song is sung in, as Whisper wants it, or '' when the room
/// has not said (migration 0163).
///
/// Whisper's `language` takes an ISO-639-1 code and nothing after it, so the
/// BCP-47 tag the song carries is cut back to its first subtag: 'ar' from
/// 'ar-EG', 'zh' from 'zh-Hans', 'pt' from 'pt-BR'. Anything that is not a
/// code Whisper knows is dropped rather than forwarded, so the request goes
/// out exactly as it did before anybody said anything and the transcription
/// still happens with the language detected. Saying what a song is sung in
/// must never be the reason it stops working.
///
/// This is worth passing on. Left to guess, Whisper decides the language
/// from the first few seconds, and a sung vocal over an instrumental intro is
/// exactly where it guesses wrong: a song in Portuguese over loud guitars
/// comes back as Spanish, or as nothing. Being told removes the guess.
export function whisperLanguage(raw: unknown): string {
  if (typeof raw !== 'string') return '';
  const first = raw.trim().split('-')[0].toLowerCase();
  if (!/^[a-z]{2,3}$/.test(first)) return '';
  const code = WHISPER_ALIASES[first] ?? first;
  return WHISPER_LANGUAGES.has(code) ? code : '';
}

/// Whether a transcript already on file answers the question this song is
/// asking.
///
/// [declared] is what this song says it is sung in, as [whisperLanguage]
/// returns it, and '' when nobody has said. [heardIn] is the language the
/// stored transcript was actually made in — declared to the worker, or
/// detected by it — and null on everything transcribed before the worker
/// started reporting that.
///
/// The rule is deliberately thin. With nothing declared, every stored
/// transcript is as good an answer as it ever was, so the cache behaves
/// exactly as it did before this existed: same key, same rows, nothing
/// thrown away. With a language declared, a transcript made in a different
/// language is the wrong words for this song, and a transcript that cannot
/// say which language it was made in cannot be shown to be the right ones —
/// so both are re-heard, once, and the answer is filed with its language
/// beside it so the next request is a hit.
export function cachedTranscriptFits(declared: string, heardIn: unknown): boolean {
  if (declared.length === 0) return true;
  return typeof heardIn === 'string' && whisperLanguage(heardIn) === declared;
}
