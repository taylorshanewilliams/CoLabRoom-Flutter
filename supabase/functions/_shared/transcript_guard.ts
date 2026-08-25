// The check that stands between a stuck decoder and somebody's lyric sheet.
//
// It lived inside transcribe-audio while that function was the only way a
// transcript could reach a song. It isn't any more: the separation worker now
// transcribes the vocal stem in the job that produced it, and that transcript
// arrives through analyze-chords instead. Both paths run the same Whisper
// architecture and fail the same way, so both need this — and a copy in each
// would drift, which on a guard means one path quietly stopping protecting
// anything.

/// Why a transcript looks like a hallucination rather than a song, or null
/// when nothing is obviously wrong with it.
///
/// Deliberately conservative. A false positive costs one re-run; a false
/// negative puts invented words in somebody's song and lets them be sung.
/// Every rule here has to hold for a real lyric sheet — which is why none of
/// them look at language or vocabulary. Songs are written in every language,
/// repeat themselves on purpose, and use words no dictionary has.
export function hallucinationSuspicion(text: string): string | null {
  const cleaned = (text ?? '').replace(/\s+/g, ' ').trim();
  if (cleaned.length === 0) return null;

  // Phrases the model emits from its own training data when it has nothing to
  // work with. The Chinese one translates as "the lyrics of this song were
  // written in collaboration by…" and is a known Whisper artefact; the rest
  // come from the video captions it was trained on. Matched anywhere, not
  // just at the start, because the repeated form buries them mid-string.
  const artefacts = [
    '这首歌的歌词是由',
    '字幕由',
    'thanks for watching',
    'thank you for watching',
    'please subscribe',
    'subscribe to my channel',
    'amara.org',
  ];
  const lowered = cleaned.toLowerCase();
  for (const phrase of artefacts) {
    if (lowered.includes(phrase)) return `known hallucination phrase: "${phrase}"`;
  }

  // A stuck decoder repeats itself far past anything a chorus does. Counted
  // over word windows rather than lines because the API returns one
  // unbroken string, and compared as a share of the transcript so a long
  // song is not judged by the same absolute number as a short one.
  const words = cleaned.split(' ').filter((word) => word.length > 0);
  const window = 6;
  if (words.length >= window * 4) {
    let repeats = 0;
    for (let i = 0; i + window * 2 <= words.length; i += 1) {
      const a = words.slice(i, i + window).join(' ');
      const b = words.slice(i + window, i + window * 2).join(' ');
      if (a === b) {
        repeats += 1;
        i += window - 1;
      }
    }
    // A real song might repeat a six-word run a handful of times across a
    // chorus. Ten separate places, or a third of the whole transcript, is a
    // decoder that stopped listening.
    const share = repeats / Math.max(1, Math.floor(words.length / window));
    if (repeats >= 10 || share > 0.34) {
      return `repeated the same phrase ${repeats} times`;
    }
  }

  return null;
}
