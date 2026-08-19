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
// Required secrets (set via `supabase secrets set` or the dashboard):
//   OPENAI_API_KEY            - from platform.openai.com, billing enabled
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are already provided
// automatically to every Edge Function by the Supabase runtime.

import { createClient } from 'jsr:@supabase/supabase-js@2';

const OPENAI_API_KEY = Deno.env.get('OPENAI_API_KEY');
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
  if (!OPENAI_API_KEY) return json({ error: 'OPENAI_API_KEY is not configured' }, 500);

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) return json({ error: 'Missing Authorization header' }, 401);

  let storagePath: string;
  let bucket: string;
  try {
    const body = await req.json();
    storagePath = body.storagePath;
    bucket = body.bucket ?? 'room-files';
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
  const { data: audioBlob, error: downloadError } = await adminClient.storage
    .from(bucket)
    .download(storagePath);
  if (downloadError || !audioBlob) {
    return json({ error: `Could not download audio: ${downloadError?.message ?? 'not found'}` }, 404);
  }

  const openAiForm = new FormData();
  const fileName = storagePath.split('/').pop() ?? 'audio';
  openAiForm.append('file', audioBlob, fileName);
  openAiForm.append('model', 'whisper-1');
  openAiForm.append('response_format', 'verbose_json');
  openAiForm.append('timestamp_granularities[]', 'word');

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

  return json({ text: result.text ?? '', words });
});
