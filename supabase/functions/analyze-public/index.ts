// Chords and key from a recording, for somebody who has never heard of this
// app and has not signed up for anything.
//
// The site currently describes an engine nobody outside the app can try.
// Musicians search for "chords from a song" constantly, and CoLabRoom answers
// that better than most of what they will find — after a signup, an install
// and a Room. This is that answer, at a URL, in about a minute.
//
// **Three deliberate constraints, and the reasons.**
//
// *No separation.* ANALYSIS_COST.md measured chord detection with and without
// it across four songs: 93.3% exact agreement, 97.2% on the root. Skipping it
// means no GPU, which takes the cost from five to eight cents a song down to
// about six tenths of one — the difference between a free tool that is
// affordable and one that is not.
//
// *Nothing is stored.* The audio is read into memory, handed to the chord
// service, and dropped. Not a privacy gesture: it is the actual design. There
// is no bucket, no row, no id, and therefore nothing to leak, nothing to
// expire, and no monthly storage bill for music somebody uploaded once to see
// what key it was in.
//
// *A quota before any work happens.* An anonymous endpoint that spends money
// per request is a bill a stranger can run up. The quota is claimed first, in
// a single statement that both counts and checks, so two simultaneous
// requests cannot both find room.
//
// Required secrets:
//   CHORD_SERVICE_URL      the Cloud Run chord_service base URL
//   CHORD_SERVICE_API_KEY  matches chord_service's own API_KEY
//   PUBLIC_TOOL_SALT       any long random string; salts the requester hash
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically.

import { createClient } from 'jsr:@supabase/supabase-js@2';

const CHORD_SERVICE_URL = Deno.env.get('CHORD_SERVICE_URL');
const CHORD_SERVICE_API_KEY = Deno.env.get('CHORD_SERVICE_API_KEY');
const PUBLIC_TOOL_SALT = Deno.env.get('PUBLIC_TOOL_SALT');
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

// Generous for a song, small enough that a hostile upload cannot occupy the
// function's memory for long. Roughly twelve minutes of 256kbps audio.
const MAX_BYTES = 24 * 1024 * 1024;

const DAILY_LIMIT = 5;

const PITCH_CLASSES = [
  'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B',
];

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

/// A salted hash of the requester, never the address itself.
///
/// The only question the quota table is allowed to answer is "has this
/// requester had its share today". A hash answers that exactly as well as an
/// IP would, and answers nothing else — which is the point.
async function requesterHash(request: Request): Promise<string> {
  const forwarded = request.headers.get('x-forwarded-for') ?? '';
  const ip = forwarded.split(',')[0].trim() || 'unknown';
  const bytes = new TextEncoder().encode(`${PUBLIC_TOOL_SALT}:${ip}`);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest))
    .slice(0, 16)
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

/// The key, from the chords, by which root holds the most time.
///
/// The same duration-weighted estimate analyze-chords keeps as its fallback.
/// The good detector runs on separated stems, which this deliberately does not
/// produce — so this is the honest answer available here, and the page says so
/// rather than presenting a guess as a measurement.
function estimateKey(
  chords: { start: number; end: number; chord: string }[],
): string | null {
  if (chords.length === 0) return null;
  const byRoot = new Map<string, number>();
  let minorTime = 0;
  let totalTime = 0;
  for (const { start, end, chord } of chords) {
    const root = chord.split(':')[0].split('/')[0];
    if (!PITCH_CLASSES.includes(root)) continue;
    const held = Math.max(end - start, 0);
    byRoot.set(root, (byRoot.get(root) ?? 0) + held);
    totalTime += held;
    if (chord.includes('min')) minorTime += held;
  }
  if (byRoot.size === 0) return null;
  const [best] = [...byRoot.entries()].sort((a, b) => b[1] - a[1]);
  // Mostly minor chords usually means a minor key. Crude, and labelled as an
  // estimate everywhere it is shown.
  const mode = totalTime > 0 && minorTime / totalTime > 0.5 ? 'minor' : 'major';
  return `${best[0]} ${mode}`;
}

Deno.serve(async (request: Request) => {
  if (request.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS });
  }
  if (request.method !== 'POST') {
    return json({ error: 'Method not allowed' }, 405);
  }
  if (!CHORD_SERVICE_URL || !CHORD_SERVICE_API_KEY || !PUBLIC_TOOL_SALT) {
    return json({ error: 'The chord tool is not configured.' }, 503);
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  // Claimed before the file is even read. Reading a 24MB body for somebody
  // who is over their limit is work done for nothing, and doing it first is
  // how a rate limit becomes a way to waste bandwidth rather than save it.
  const requester = await requesterHash(request);
  const { data: allowed, error: quotaError } = await supabase.rpc(
    'claim_public_analysis',
    { in_requester: requester, in_daily_limit: DAILY_LIMIT },
  );
  if (quotaError) {
    return json({ error: 'Could not check the daily limit.' }, 500);
  }
  if (allowed !== true) {
    return json({
      error: `That is ${DAILY_LIMIT} songs today — the free tool's daily limit. `
        + 'The app has no limit.',
      limit_reached: true,
    }, 429);
  }

  let file: File | null = null;
  try {
    const form = await request.formData();
    const value = form.get('file');
    file = value instanceof File ? value : null;
  } catch {
    return json({ error: 'That upload could not be read.' }, 400);
  }
  if (file == null) return json({ error: 'No audio file was sent.' }, 400);
  if (file.size > MAX_BYTES) {
    return json({
      error: 'That file is larger than 24MB. A normal song is well under it.',
    }, 413);
  }
  if (file.size === 0) return json({ error: 'That file is empty.' }, 400);

  try {
    const outgoing = new FormData();
    // Passed straight through. It is never written anywhere: no bucket, no
    // row, no id. When this function returns, the only copy is the one on the
    // musician's own computer.
    outgoing.append('file', file, 'upload');
    const response = await fetch(`${CHORD_SERVICE_URL}/analyze`, {
      method: 'POST',
      headers: { 'X-API-Key': CHORD_SERVICE_API_KEY },
      body: outgoing,
    });
    if (!response.ok) {
      console.error(`Chord service ${response.status}: ${await response.text()}`);
      return json({
        error: 'The chord detector could not read that recording. '
          + 'A wav or mp3 of the whole song works best.',
      }, 502);
    }
    const body = await response.json() as {
      chords?: { start: number; end: number; chord: string }[];
    };
    const chords = body.chords ?? [];
    if (chords.length === 0) {
      return json({
        error: 'No chords were found in that recording. '
          + 'Something with instruments in it works better than a vocal alone.',
      }, 422);
    }

    return json({
      chords,
      key: estimateKey(chords),
      // Said in the response rather than only on the page, so anything built
      // on this endpoint later inherits the caveat rather than dropping it.
      key_is_estimated: true,
      seconds: chords[chords.length - 1]?.end ?? null,
      stored: false,
    });
  } catch (error) {
    console.error(`Public chord tool failed: ${error}`);
    return json({ error: 'That did not work. Try again in a moment.' }, 500);
  }
});
