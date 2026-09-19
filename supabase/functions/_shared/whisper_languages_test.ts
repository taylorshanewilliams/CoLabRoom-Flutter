// The two decisions the Edge Functions make about a song's language, tested
// where they are made.
//
// Neither fails loudly when it is wrong. A tag cut badly is simply dropped,
// and the song is transcribed by guesswork exactly as it was before anybody
// said anything — which is the failure this whole feature exists to remove,
// and nothing downstream can tell the difference. A cache rule that is too
// generous hands a Spanish transcript to a Portuguese song for ever; one
// that is too strict pays for a GPU on every open. So both are asserted.
//
// Run by `deno test` in the Verify workflow. These are pure functions with
// no network and no Supabase behind them, which is exactly why they are in
// _shared rather than inside either function.

import { assertEquals } from 'jsr:@std/assert@1';

import { cachedTranscriptFits, whisperLanguage } from './whisper_languages.ts';

Deno.test('a tag becomes the code the transcriber takes', () => {
  assertEquals(whisperLanguage('ar'), 'ar');
  // A region and a script are not part of what Whisper is asked for: a song
  // in Brazilian Portuguese is sung in Portuguese.
  assertEquals(whisperLanguage('pt-BR'), 'pt');
  assertEquals(whisperLanguage('zh-Hans'), 'zh');
  assertEquals(whisperLanguage('zh-Hans-CN'), 'zh');
  // However it was typed. The app folds tags to one spelling before storing
  // them, but this is also reached by anything written by an older build.
  assertEquals(whisperLanguage(' AR '), 'ar');
  assertEquals(whisperLanguage('PT-br'), 'pt');
});

Deno.test('a language Whisper spells differently is spelled its way', () => {
  // The app's list stores the Bokmål tag; Whisper only knows 'no'. Without
  // this, Norwegian would be dropped and transcribed by guesswork.
  assertEquals(whisperLanguage('nb'), 'no');
  assertEquals(whisperLanguage('nb-NO'), 'no');
  // Cantonese is not a separate language to Whisper at all, and asking for
  // Chinese is much closer than asking for nothing.
  assertEquals(whisperLanguage('yue'), 'zh');
  assertEquals(whisperLanguage('fil'), 'tl');
});

Deno.test('anything that is not a language it knows is left out', () => {
  // Not forwarded: an unknown code is a 400 from OpenAI and a refusal from
  // faster-whisper, and saying what a song is sung in must never be the
  // reason it stops being transcribed. Dropped means "detect it yourself",
  // which is what every song did before this.
  assertEquals(whisperLanguage('zz'), '');
  assertEquals(whisperLanguage('Arabic'), '');
  assertEquals(whisperLanguage('ar-EG-cairo'), 'ar');
  assertEquals(whisperLanguage(''), '');
  assertEquals(whisperLanguage(null), '');
  assertEquals(whisperLanguage(undefined), '');
  assertEquals(whisperLanguage(42), '');
});

Deno.test('a song nobody has answered for finds the rows it always did', () => {
  // The thin rule. With nothing declared there is no basis on which to
  // refuse a stored transcript, so the cache behaves exactly as it did
  // before this existed and nothing already cached is thrown away.
  assertEquals(cachedTranscriptFits('', null), true);
  assertEquals(cachedTranscriptFits('', 'es'), true);
  assertEquals(cachedTranscriptFits('', undefined), true);
});

Deno.test('a song that has answered is only served words heard in it', () => {
  assertEquals(cachedTranscriptFits('pt', 'pt'), true);
  // Whatever the row recorded it as: a worker reporting a tag rather than a
  // bare code is the same answer.
  assertEquals(cachedTranscriptFits('pt', 'pt-BR'), true);
  // Heard in something else. Re-heard, once, and filed with its language.
  assertEquals(cachedTranscriptFits('pt', 'es'), false);
  // And a transcript that cannot say what it was heard in cannot be shown to
  // be the right words — every row written before this, and every worker
  // image that predates the language reaching it.
  assertEquals(cachedTranscriptFits('pt', null), false);
  assertEquals(cachedTranscriptFits('pt', ''), false);
  assertEquals(cachedTranscriptFits('pt', 42), false);
});
