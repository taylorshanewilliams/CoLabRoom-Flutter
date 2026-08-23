// Transcribes a project's reference recording via OpenAI's Whisper API,
// keeping the API key server-side — it must never be shipped inside the
// mobile app, since anything embedded in a client can be extracted.
//
// The Flutter client uploads the recording to Supabase Storage first (as it
// already does to keep it as the project's reference track), then invokes
// this function with that storage path. This function verifies the caller
// is a real authenticated user, downloads the audio server-side, forwards
// it to OpenAI, and returns word-level timestamps.
//
// It also doesn't pay to transcribe a vocal it has already heard. The audio
// and the prompt are both hashed and looked up in transcript_cache before
// anything is downloaded or sent to OpenAI — see migration 0025 for why the
// prompt has to be part of that key.
//
// Required secrets (set via `supabase secrets set` or the dashboard):
//   OPENAI_API_KEY            - from platform.openai.com, billing enabled
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are already provided
// automatically to every Edge Function by the Supabase runtime.

import { createClient } from 'jsr:@supabase/supabase-js@2';
// Streams rather than buffers — see the same import in analyze-chords.
import { crypto as stdCrypto } from 'jsr:@std/crypto@1';
import { encodeHex } from 'jsr:@std/encoding@1/hex';

const OPENAI_API_KEY = Deno.env.get('OPENAI_API_KEY');
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

// Part of what a cached transcript is an answer to, so it's matched on rather
// than assumed. Changing it makes every stored transcript stale, not
// differently-keyed.
const WHISPER_MODEL = 'whisper-1';

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

/// Hex SHA-256 of whatever the URL serves, hashed as it streams.
///
/// Null on any failure, which means "don't cache this run" and never "fail
/// this run" — the cache is an optimization and is not allowed to be the
/// reason a musician can't transcribe their song.
async function sha256OfUrl(url: string): Promise<string | null> {
  try {
    const response = await fetch(url);
    if (!response.ok || !response.body) return null;
    const digest = await stdCrypto.subtle.digest('SHA-256', response.body);
    return encodeHex(new Uint8Array(digest));
  } catch {
    return null;
  }
}

async function sha256OfText(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return encodeHex(new Uint8Array(digest));
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
  if (!OPENAI_API_KEY) return json({ error: 'OPENAI_API_KEY is not configured' }, 500);

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) return json({ error: 'Missing Authorization header' }, 401);

  let storagePath: string;
  let bucket: string;
  let lyricsHint: string;
  try {
    const body = await req.json();
    storagePath = body.storagePath;
    bucket = body.bucket ?? 'room-files';
    lyricsHint = typeof body.lyricsHint === 'string' ? body.lyricsHint.trim() : '';
    if (typeof storagePath !== 'string' || storagePath.length === 0) {
      return json({ error: 'storagePath is required' }, 400);
    }
  } catch {
    return json({ error: 'Invalid JSON body' }, 400);
  }

  // Confirm the caller is a real signed-in user before touching storage or
  // spending API credit on their behalf.
  const callerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userError } = await callerClient.auth.getUser();
  if (userError || !userData?.user) return json({ error: 'Unauthorized' }, 401);

  // Download with the service role key so this works regardless of the
  // storage bucket's RLS shape, now that the caller is confirmed
  // authenticated above.
  const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  // Nudges Whisper toward expecting sung vocals rather than defaulting to
  // "no speech" on recordings with unusual vocal timbre (e.g. AI-generated
  // singers), reverb-heavy mixes, or ambiguous instrumental intros.
  //
  // When the song already has typed lyrics they're appended: Whisper resolves
  // ambiguous audio toward words it has been primed with, and what the writer
  // actually wrote is the strongest available prior for what they sang. On a
  // live take — room reverb, crowd, an off-mic vocal — this does more for
  // accuracy than swapping the model would.
  //
  // The trade is real and worth knowing: priming also makes Whisper likelier
  // to *agree* with the hint. A verse rewritten since the recording may come
  // back as the old words. That's why the hint is only the song's own lyrics
  // and never a generic phrase list, and why the transcript stays separate
  // from the typed lyrics rather than overwriting them.
  const prompt = lyricsHint.length > 0
    ? `Song lyrics, sung vocals. ${lyricsHint}`.slice(0, 900)
    : 'Song lyrics, sung vocals.';

  // Both hashes before anything is downloaded or spent: this is the same
  // vocal stem, primed with the same words, so it is the same transcript.
  // Hashed from a signed URL rather than the downloaded blob so a hit costs
  // one streamed read and no memory.
  const { data: signedUrlData } = await adminClient.storage
    .from(bucket)
    .createSignedUrl(storagePath, 600);
  const audioSha256 = signedUrlData ? await sha256OfUrl(signedUrlData.signedUrl) : null;
  const promptSha256 = await sha256OfText(prompt);

  if (audioSha256) {
    const { data: cached } = await adminClient
      .from('transcript_cache')
      .select('transcript_text, words, hit_count')
      .eq('audio_sha256', audioSha256)
      .eq('prompt_sha256', promptSha256)
      .eq('model', WHISPER_MODEL)
      .maybeSingle();
    if (cached) {
      await adminClient
        .from('transcript_cache')
        .update({
          last_used_at: new Date().toISOString(),
          hit_count: ((cached.hit_count as number | null) ?? 0) + 1,
        })
        .eq('audio_sha256', audioSha256)
        .eq('prompt_sha256', promptSha256);
      return json({
        text: (cached.transcript_text as string | null) ?? '',
        words: cached.words ?? [],
        // Informational only; the app reads text and words exactly as before.
        cached: true,
      });
    }
  }

  // Download with the service role key so this works regardless of the
  // storage bucket's RLS shape, now that the caller is confirmed
  // authenticated above.
  const { data: audioBlob, error: downloadError } = await adminClient.storage
    .from(bucket)
    .download(storagePath);
  if (downloadError || !audioBlob) {
    return json({ error: `Could not download audio: ${downloadError?.message ?? 'not found'}` }, 404);
  }

  const openAiForm = new FormData();
  const fileName = storagePath.split('/').pop() ?? 'audio';
  openAiForm.append('file', audioBlob, fileName);
  openAiForm.append('model', WHISPER_MODEL);
  openAiForm.append('response_format', 'verbose_json');
  openAiForm.append('timestamp_granularities[]', 'word');
  openAiForm.append('prompt', prompt);

  let openAiResponse: Response;
  try {
    openAiResponse = await fetch('https://api.openai.com/v1/audio/transcriptions', {
      method: 'POST',
      headers: { Authorization: `Bearer ${OPENAI_API_KEY}` },
      body: openAiForm,
    });
  } catch (error) {
    return json({ error: `Could not reach OpenAI: ${error instanceof Error ? error.message : String(error)}` }, 502);
  }

  if (!openAiResponse.ok) {
    const errorBody = await openAiResponse.text();
    return json({ error: `OpenAI transcription failed (${openAiResponse.status}): ${errorBody}` }, 502);
  }

  const result = await openAiResponse.json();
  type OpenAiWord = { word: string; start: number; end: number };
  const words = ((result.words ?? []) as OpenAiWord[]).map((w) => ({
    word: w.word,
    start_ms: Math.round(w.start * 1000),
    end_ms: Math.round(w.end * 1000),
  }));

  const text = result.text ?? '';

  // An empty transcription is the result a musician re-runs — an instrumental
  // intro that swallowed the vocal, a take Whisper decided had no speech in
  // it. Remembering that answer would make re-running it pointless, so only a
  // transcript with words in it is kept.
  if (audioSha256 && words.length > 0) {
    // hit_count is deliberately absent: an upsert overwrites only the columns
    // it names, so re-transcribing keeps the running total.
    await adminClient.from('transcript_cache').upsert(
      {
        audio_sha256: audioSha256,
        prompt_sha256: promptSha256,
        model: WHISPER_MODEL,
        transcript_text: text,
        words,
        last_used_at: new Date().toISOString(),
      },
      { onConflict: 'audio_sha256,prompt_sha256' },
    );
  }

  return json({ text, words });
});
