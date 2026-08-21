// Runs a project's reference recording through the self-hosted chord
// detection pipeline: RunPod (Demucs source separation) -> Cloud Run
// (ChordMini chord detection). Replaces the old on-device chroma/FFT
// heuristic in song_analysis_service.dart's _analyzeChords, which never
// broke 15-17% confidence because it wasn't a trained model at all.
//
// Mirrors transcribe-audio's shape: client uploads the recording to
// Supabase Storage first, then invokes this function with that storage
// path. This function verifies the caller, downloads the audio
// server-side, and keeps both inference services' keys out of the app.
//
// Required secrets (set via `supabase secrets set` or the dashboard):
//   RUNPOD_API_KEY        - from runpod.io Settings -> API Keys
//   RUNPOD_ENDPOINT_ID     - the separation service's endpoint id
//   CHORD_SERVICE_URL      - the Cloud Run chord_service base URL
//   CHORD_SERVICE_API_KEY  - matches chord_service's own API_KEY env var
// SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are
// already provided automatically to every Edge Function.

import { createClient } from 'jsr:@supabase/supabase-js@2';

const RUNPOD_API_KEY = Deno.env.get('RUNPOD_API_KEY');
const RUNPOD_ENDPOINT_ID = Deno.env.get('RUNPOD_ENDPOINT_ID');
const CHORD_SERVICE_URL = Deno.env.get('CHORD_SERVICE_URL');
const CHORD_SERVICE_API_KEY = Deno.env.get('CHORD_SERVICE_API_KEY');
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

// RunPod cold start (image pull + model load) can run past a minute; poll
// generously rather than giving up early on what's still a normal wait.
const RUNPOD_POLL_INTERVAL_MS = 4000;
const RUNPOD_MAX_POLLS = 45; // ~3 minutes

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = '';
  const chunkSize = 0x8000;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
  }
  return btoa(binary);
}

function base64ToBytes(base64: string): Uint8Array {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

async function separateAudio(audioBytes: Uint8Array, filename: string): Promise<Uint8Array> {
  const runResponse = await fetch(`https://api.runpod.ai/v2/${RUNPOD_ENDPOINT_ID}/run`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${RUNPOD_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      input: { audio_b64: bytesToBase64(audioBytes), filename },
    }),
  });
  if (!runResponse.ok) {
    throw new Error(`RunPod job submission failed (${runResponse.status}): ${await runResponse.text()}`);
  }
  const { id: jobId } = await runResponse.json();

  for (let poll = 0; poll < RUNPOD_MAX_POLLS; poll++) {
    await new Promise((resolve) => setTimeout(resolve, RUNPOD_POLL_INTERVAL_MS));
    const statusResponse = await fetch(`https://api.runpod.ai/v2/${RUNPOD_ENDPOINT_ID}/status/${jobId}`, {
      headers: { Authorization: `Bearer ${RUNPOD_API_KEY}` },
    });
    if (!statusResponse.ok) continue;
    const statusBody = await statusResponse.json();
    if (statusBody.status === 'COMPLETED') {
      const mixB64 = statusBody.output?.harmonic_mix_b64;
      if (!mixB64) throw new Error('RunPod job completed but returned no harmonic_mix_b64.');
      return base64ToBytes(mixB64);
    }
    if (statusBody.status === 'FAILED') {
      throw new Error(`RunPod separation failed: ${statusBody.error ?? 'unknown error'}`);
    }
  }
  throw new Error('RunPod separation timed out.');
}

async function detectChords(
  audioBytes: Uint8Array,
): Promise<{ start: number; end: number; chord: string }[]> {
  const form = new FormData();
  form.append('file', new Blob([audioBytes]), 'harmonic_mix.mp3');
  const response = await fetch(`${CHORD_SERVICE_URL}/analyze`, {
    method: 'POST',
    headers: { 'X-API-Key': CHORD_SERVICE_API_KEY ?? '' },
    body: form,
  });
  if (!response.ok) {
    throw new Error(`Chord service failed (${response.status}): ${await response.text()}`);
  }
  const body = await response.json();
  return body.chords ?? [];
}

const PITCH_CLASSES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];

// ChordMini's .lab output doesn't carry a song-wide key estimate, only
// per-segment chords — this derives a simple duration-weighted "which
// root shows up most" guess. Real key detection would weigh scale
// membership too, not just raw root duration; this is intentionally the
// cheap version, good enough for the UI's "Key / center" field without
// standing up a third model just for it.
function estimateKey(chords: { start: number; end: number; chord: string }[]): string | null {
  if (chords.length === 0) return null;
  const durationByRoot = new Map<string, number>();
  for (const { start, end, chord } of chords) {
    const root = chord.split(':')[0].split('/')[0];
    const index = PITCH_CLASSES.indexOf(root);
    if (index === -1) continue; // "N" (no chord) and anything unparsed
    const duration = Math.max(0, end - start);
    durationByRoot.set(root, (durationByRoot.get(root) ?? 0) + duration);
  }
  let best: string | null = null;
  let bestDuration = -1;
  for (const [root, duration] of durationByRoot) {
    if (duration > bestDuration) {
      best = root;
      bestDuration = duration;
    }
  }
  return best;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
  if (!RUNPOD_API_KEY || !RUNPOD_ENDPOINT_ID) {
    return json({ error: 'RUNPOD_API_KEY / RUNPOD_ENDPOINT_ID is not configured' }, 500);
  }
  if (!CHORD_SERVICE_URL || !CHORD_SERVICE_API_KEY) {
    return json({ error: 'CHORD_SERVICE_URL / CHORD_SERVICE_API_KEY is not configured' }, 500);
  }

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

  const callerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userError } = await callerClient.auth.getUser();
  if (userError || !userData?.user) return json({ error: 'Unauthorized' }, 401);

  const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const { data: audioBlob, error: downloadError } = await adminClient.storage
    .from(bucket)
    .download(storagePath);
  if (downloadError || !audioBlob) {
    return json({ error: `Could not download audio: ${downloadError?.message ?? 'not found'}` }, 404);
  }
  const audioBytes = new Uint8Array(await audioBlob.arrayBuffer());
  const filename = storagePath.split('/').pop() ?? 'audio.mp3';

  try {
    const harmonicMix = await separateAudio(audioBytes, filename);
    const chords = await detectChords(harmonicMix);
    const key = estimateKey(chords);
    // ChordMini's .lab output doesn't expose per-segment confidence, only
    // the chord label itself — flat placeholder rather than fabricating
    // false precision. Worth revisiting if chord_service is ever extended
    // to surface the model's actual per-frame logits.
    const cues = chords.map((c) => ({
      startMs: Math.round(c.start * 1000),
      endMs: Math.round(c.end * 1000),
      chord: c.chord,
      confidence: 0.8,
    }));
    return json({ cues, key });
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : String(error) }, 502);
  }
});
