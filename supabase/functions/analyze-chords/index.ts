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
// It also now persists the separated stems. The worker uploads each one
// directly to Storage through short-lived signed upload URLs minted here,
// so the RunPod side never needs Supabase credentials of its own and the
// stems never travel through RunPod's job-result payload (which silently
// drops large outputs — see handler.py's notes).
//
// And it no longer separates the same recording twice. `start` hashes the
// audio as it streams out of Storage and looks that hash up in
// analysis_cache; on a hit it returns the finished analysis from that first
// call, copies the stems into the caller's own folder, and never touches the
// GPU. See migration 0024 for why the key is the content rather than a file
// id.
//
// Required secrets (set via `supabase secrets set` or the dashboard):
//   RUNPOD_API_KEY        - from runpod.io Settings -> API Keys
//   RUNPOD_ENDPOINT_ID     - the separation service's endpoint id
//   CHORD_SERVICE_URL      - the Cloud Run chord_service base URL
//   CHORD_SERVICE_API_KEY  - matches chord_service's own API_KEY env var
// SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are
// already provided automatically to every Edge Function.

import { createClient } from 'jsr:@supabase/supabase-js@2';
// The platform's own crypto.subtle.digest only takes a whole buffer, which
// would mean holding an entire song in memory just to hash it — the exact
// mistake that produced WORKER_RESOURCE_LIMIT here once already. @std/crypto's
// accepts a stream and hashes it chunk by chunk.
import { crypto as stdCrypto } from 'jsr:@std/crypto@1';
import { encodeHex } from 'jsr:@std/encoding@1/hex';

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

// htdemucs_6s sources. Order matters only for display; `vocals` is called out
// separately below because the lyrics pass reads it.
const STEMS = ['vocals', 'drums', 'bass', 'guitar', 'piano', 'other'] as const;
type Stem = (typeof STEMS)[number];

// Which pipeline a cached analysis came from. Bump this whenever a change
// would make the same recording produce a different (or better) answer —
// a new separation model, a new chord model, a new beat tracker — so every
// existing cache row stops matching and is replaced by a real run. Not
// bumping it after such a change is the one way this cache can serve a stale
// answer, so it belongs next to the models it describes.
// .2 adds the all-in-one structure model, which names sections instead of
// lettering them. Every cached analysis from .1 carries the old "Part A, Part
// B" structure, and no amount of re-opening the song would have replaced it —
// bumping this is what makes the next analysis a real one.
const PIPELINE_VERSION = 'htdemucs_6s+chordmini+beat_this+allin1.2';

// The chords-and-lyrics pass. Skips section naming — the only stage that runs
// a second source separation — and keeps just the vocal stem, which the
// lyrics pass needs and which is the largest single lever on lyric accuracy.
//
// It gets its own cache key, and that is not a detail. Sharing one would let
// a quick result silently satisfy a later request for the full thing: you'd
// ask for sections, get an instant answer with none, and have no way to tell
// the difference between "cached" and "this song has no structure".
const QUICK_PIPELINE_VERSION = `${PIPELINE_VERSION}+chords-only`;

// Full is a superset of quick, so a cached full analysis is a perfectly good
// answer to a quick request — the same chords, the same beats, the same
// lyrics, plus sections nobody asked for. Worth checking first: it turns
// "analyze this quickly" into nothing at all for a song already analyzed
// properly.
function cacheVersionsFor(depth: 'full' | 'quick'): string[] {
  return depth === 'quick'
    ? [PIPELINE_VERSION, QUICK_PIPELINE_VERSION]
    : [PIPELINE_VERSION];
}

// How many separations one account may actually run in a calendar month
// before this refuses. Overridable per account in account_limits.
//
// Not a pricing tier — there is no pricing yet. This is the safety valve that
// should have existed from the first GPU job: nothing has ever stopped one
// person running three hundred analyses, and the bill for that arrives well
// before any signal that it's happening. Set high enough that a working
// musician never meets it and a runaway does.
const DEFAULT_MONTHLY_ANALYSES = 100;

/// The SHA-256 of whatever the URL serves, hex-encoded, hashed as it streams
/// rather than buffered.
///
/// Returns null instead of throwing on any failure. A hash that can't be
/// computed means "no caching this time", which costs a GPU job; a hash that
/// throws would mean an analysis the user can't run at all. The cache is an
/// optimization and is never allowed to be the reason something breaks — the
/// same reasoning applies at every call site below.
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

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

// Backed by an explicit ArrayBuffer so the result is a `Uint8Array<ArrayBuffer>`
// rather than `Uint8Array<ArrayBufferLike>` — the latter isn't assignable to
// BlobPart, since ArrayBufferLike admits SharedArrayBuffer.
function base64ToBytes(base64: string): Uint8Array<ArrayBuffer> {
  const binary = atob(base64);
  const bytes = new Uint8Array(new ArrayBuffer(binary.length));
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

interface SeparationResult {
  /// What RunPod actually billed for: milliseconds the worker spent running,
  /// excluding the queue wait. The most important number in the usage log,
  /// because separation is the dominant cost of an analysis.
  executionMs: number | null;

  // Present only on the legacy path, where the worker had nowhere to upload
  // the mix and had to inline it. Prefer mixUploaded.
  harmonicMixB64: string | null;
  mixUploaded: boolean;
  bpm: number | null;
  key: string | null;
  beatsMs: number[];
  downbeatsMs: number[];
  beatsPerBar: number | null;
  instruments: unknown;
  structure: unknown;
  uploadedStems: string[];
}

function numberArray(value: unknown): number[] {
  return Array.isArray(value) ? value.filter((n): n is number => typeof n === 'number') : [];
}

async function submitSeparation(
  audioUrl: string,
  filename: string,
  stemUploads: Record<string, string>,
  mixUpload: string | null,
  skipStructure: boolean,
): Promise<string> {
  const runResponse = await fetch(`https://api.runpod.ai/v2/${RUNPOD_ENDPOINT_ID}/run`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${RUNPOD_API_KEY}`,
      'Content-Type': 'application/json',
    },
    // A signed URL, not the audio itself — RunPod's /run endpoint caps
    // request bodies at 10MiB, which a base64-encoded full song blows
    // past easily. The separation_service worker downloads the file
    // itself from this URL instead of receiving it inline, and pushes the
    // finished stems back out through stem_uploads the same way.
    body: JSON.stringify({
      input: {
        audio_url: audioUrl,
        filename,
        stem_uploads: stemUploads,
        mix_upload: mixUpload,
        skip_structure: skipStructure,
      },
    }),
  });
  if (!runResponse.ok) {
    throw new Error(`RunPod job submission failed (${runResponse.status}): ${await runResponse.text()}`);
  }
  const { id: jobId } = await runResponse.json();
  if (typeof jobId !== 'string' || jobId.length === 0) {
    throw new Error('RunPod accepted the job but returned no id.');
  }
  return jobId;
}

/// null while the job is still queued or running.
async function readSeparation(jobId: string): Promise<SeparationResult | null> {
  const statusResponse = await fetch(`https://api.runpod.ai/v2/${RUNPOD_ENDPOINT_ID}/status/${jobId}`, {
    headers: { Authorization: `Bearer ${RUNPOD_API_KEY}` },
  });
  if (!statusResponse.ok) {
    // A transient status-endpoint blip is not a failed job; let the caller
    // ask again rather than discarding work that may well be finishing.
    return null;
  }
  const statusBody = await statusResponse.json();
  if (statusBody.status === 'FAILED') {
    throw new Error(`RunPod separation failed: ${statusBody.error ?? 'unknown error'}`);
  }
  if (statusBody.status !== 'COMPLETED') return null;

  const mixUploaded = statusBody.output?.harmonic_mix_uploaded === true;
  const mixB64 = statusBody.output?.harmonic_mix_b64 ?? null;
  if (!mixUploaded && !mixB64) {
    throw new Error('RunPod job completed but returned no harmonic mix.');
  }
  return {
    executionMs: typeof statusBody.executionTime === 'number' ? statusBody.executionTime : null,
    harmonicMixB64: mixB64,
    mixUploaded,
    // Best-effort fields the separation_service computes alongside the
    // mix (BPM, key, instrument presence, structure boundaries) — absent
    // or null here just means that detector didn't run/failed, not an
    // error worth failing the whole job over.
    bpm: typeof statusBody.output?.bpm === 'number' ? statusBody.output.bpm : null,
    key: typeof statusBody.output?.key === 'string' ? statusBody.output.key : null,
    beatsMs: numberArray(statusBody.output?.beats_ms),
    downbeatsMs: numberArray(statusBody.output?.downbeats_ms),
    beatsPerBar:
      typeof statusBody.output?.beats_per_bar === 'number' ? statusBody.output.beats_per_bar : null,
    instruments: statusBody.output?.instruments ?? null,
    structure: statusBody.output?.structure ?? [],
    uploadedStems: Array.isArray(statusBody.output?.uploaded_stems)
      ? statusBody.output.uploaded_stems.filter((s: unknown) => typeof s === 'string')
      : [],
  };
}

async function detectChords(
  audio: Blob,
): Promise<{ start: number; end: number; chord: string }[]> {
  const form = new FormData();
  form.append('file', audio, 'harmonic_mix.mp3');
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

// Fallback only. The separation worker now runs proper Krumhansl-Schmuckler
// key-profile correlation over the harmonic stems and returns a key with a
// mode ("A minor"); this duration-weighted "which root shows up most" guess
// is kept purely for the case where that detector failed and returned null,
// so the Key field degrades to a rough answer rather than going blank.
function estimateKeyFallback(chords: { start: number; end: number; chord: string }[]): string | null {
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
  let projectId: string | null;
  // A Studio idea rather than a project. Mutually exclusive with projectId;
  // both mean "somewhere to keep the stems", they just belong to different
  // owners.
  let draftId: string | null;
  let action: string;
  let jobId: string | null;
  // Whether this build understands a `start` that comes back already
  // finished. Older ones read the response for a job id and fail without
  // one, so they keep getting a real separation job — slower and dearer, but
  // working, which matters more while a band is running mixed builds.
  let acceptsCachedAnalysis: boolean;
  // How long the recording is. Sent by the client, which has already decoded
  // the file and knows — this function never does. Only used for the usage
  // log, so a missing or nonsense value costs a slightly incomplete figure
  // and nothing else.
  let audioMs: number | null;
  // 'quick' is chords and lyrics only. See QUICK_PIPELINE_VERSION.
  let depth: 'full' | 'quick';
  try {
    const body = await req.json();
    storagePath = body.storagePath;
    bucket = body.bucket ?? 'room-files';
    projectId = typeof body.projectId === 'string' && body.projectId.length > 0 ? body.projectId : null;
    draftId = typeof body.draftId === 'string' && body.draftId.length > 0 ? body.draftId : null;
    action = typeof body.action === 'string' ? body.action : 'start';
    jobId = typeof body.jobId === 'string' && body.jobId.length > 0 ? body.jobId : null;
    acceptsCachedAnalysis = body.acceptsCachedAnalysis === true;
    audioMs = typeof body.durationMs === 'number' && body.durationMs > 0
      ? Math.round(body.durationMs)
      : null;
    // Anything unrecognised means full. A build that doesn't know about
    // depths should get the whole analysis, not the abbreviated one.
    depth = body.depth === 'quick' ? 'quick' : 'full';
    if (typeof storagePath !== 'string' || storagePath.length === 0) {
      return json({ error: 'storagePath is required' }, 400);
    }
    if (action !== 'start' && action !== 'poll') {
      return json({ error: "action must be 'start' or 'poll'" }, 400);
    }
    if (action === 'poll' && jobId == null) {
      return json({ error: 'jobId is required to poll' }, 400);
    }
  } catch {
    return json({ error: 'Invalid JSON body' }, 400);
  }

  const callerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userError } = await callerClient.auth.getUser();
  if (userError || !userData?.user) return json({ error: 'Unauthorized' }, 401);

  // When the client identifies the project, confirm through the *caller's*
  // RLS-scoped client that they can actually see that project's reference
  // recording, and that storagePath is that recording rather than an
  // arbitrary object. Without this, an authenticated user could hand any
  // storage path to a service-role signed-URL mint. Older app builds don't
  // send projectId; those keep the previous behaviour minus stem persistence
  // rather than breaking mid-beta.
  if (projectId) {
    const { data: reference } = await callerClient
      .from('project_audio_references')
      .select('project_id, files(storage_path)')
      .eq('project_id', projectId)
      .maybeSingle();
    const referencePath = (reference as { files?: { storage_path?: string } } | null)?.files?.storage_path;
    if (!reference || referencePath !== storagePath) {
      return json({ error: 'That recording does not belong to this project.' }, 403);
    }
  }

  const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  // Stems live beside the reference recording:
  // <room>/<project>/analysis/stems/<recording>/<stem>.mp3. Keeping the first
  // two path segments intact is what lets the room-files storage policies
  // match on room and project membership.
  //
  // The <recording> segment is new. A project's stem directory used to be
  // one flat folder, the same for every recording the project ever held —
  // so attaching a new reference and analyzing it overwrote the previous
  // take's stems in place. Naming the folder after the recording that
  // produced it fixes that, and is what lets analysis_cache safely point at
  // a stem directory and still be right months later.
  //
  // Derived from the storage path rather than from the audio's hash on
  // purpose, so `start` and `poll` reach the same answer with no shared
  // state between them: a project's references are named
  // reference_<microseconds> and a Studio idea's folder is its own draft id,
  // so this is already unique per recording in both buckets.
  const analysisDir = storagePath.split('/').slice(0, -1).join('/');
  const recordingName = (storagePath.split('/').pop() ?? 'reference').replace(/\.[^.]+$/, '');
  const stemDir = `${analysisDir}/stems/${recordingName}`;
  // Where analyses before this change left their stems. Swept on re-analysis
  // so a project doesn't keep a permanent copy of every take it ever had.
  const legacyStemDir = `${analysisDir}/stems`;
  const stemPathIn = (dir: string, stem: Stem) => `${dir}/${stem}.mp3`;

  // The harmonic mix goes through Storage rather than the job payload, for
  // every caller including ones without a projectId. Inlining it as base64
  // meant this function held the encoded string, the decoded binary string
  // and the byte array simultaneously — roughly 4x the file — which is what
  // produced WORKER_RESOURCE_LIMIT on a four-minute song. Not persisted in
  // project_stems: it's an intermediate for the chord service, not a stem
  // anyone plays.
  const mixPath = `${stemDir}/_harmonic_mix.mp3`;

  /// Records which stems a finished analysis produced, for whichever owner
  /// this call is for. Shared by the cache-hit path and the normal one so
  /// they cannot drift apart.
  ///
  /// Clears first in both cases: a re-analysis where some stem failed to
  /// upload this time would otherwise leave a row pointing at an object
  /// deleted before the job started, i.e. a playback entry that 404s.
  /// Service role throughout — neither stem table has an insert policy for
  /// `authenticated` on purpose, same trust model as notifications.
  async function persistStems(stems: { stem: string; storagePath: string }[]) {
    if (projectId) {
      await adminClient.from('project_stems').delete().eq('project_id', projectId);
      if (stems.length > 0) {
        await adminClient.from('project_stems').insert(
          stems.map((entry) => ({
            project_id: projectId,
            stem: entry.stem,
            storage_path: entry.storagePath,
          })),
        );
      }
    } else if (draftId) {
      await adminClient.from('studio_draft_stems').delete().eq('draft_id', draftId);
      if (stems.length > 0) {
        await adminClient.from('studio_draft_stems').insert(
          stems.map((entry) => ({
            draft_id: draftId,
            stem: entry.stem,
            storage_path: entry.storagePath,
          })),
        );
      }
    }
  }

  /// Records what one vendor call consumed (migration 0028).
  ///
  /// Best-effort and never awaited for correctness: a missing usage row makes
  /// a month's figures slightly wrong, while a failed insert that took an
  /// analysis down with it would make the product wrong. Cache hits are
  /// recorded too — the money the cache saves is invisible if the runs it
  /// saved leave no trace.
  async function recordUsage(entry: {
    service: 'separation' | 'chords' | 'transcription' | 'storage';
    cached?: boolean;
    audioMs?: number | null;
    computeMs?: number | null;
    bytes?: number | null;
    sha?: string | null;
  }) {
    try {
      await adminClient.from('usage_events').insert({
        account_id: userData.user!.id,
        project_id: projectId,
        draft_id: draftId,
        service: entry.service,
        cached: entry.cached ?? false,
        audio_ms: entry.audioMs ?? null,
        compute_ms: entry.computeMs ?? null,
        bytes: entry.bytes ?? null,
        audio_sha256: entry.sha ?? null,
      });
    } catch (_) {
      // See above.
    }
  }

  /// How much storage this analysis's stems are now occupying — the cost that
  /// isn't paid once, but every month until they're deleted.
  async function stemBytesIn(dir: string): Promise<number | null> {
    try {
      const { data } = await adminClient.storage.from(bucket).list(dir);
      if (!data) return null;
      return data.reduce(
        (total, object) => total + (object.metadata?.size as number | undefined ?? 0),
        0,
      );
    } catch (_) {
      return null;
    }
  }

  /// Why this account can't start another analysis this month, or null when
  /// it can.
  ///
  /// Fails open. If the count can't be read the analysis proceeds: a limit
  /// that can't be checked is not a reason to stop somebody working, and the
  /// usage log still records what happened either way. A safety valve that
  /// blocks the product when its own bookkeeping hiccups is worse than the
  /// runaway it guards against.
  async function monthlyLimitRefusal(): Promise<string | null> {
    try {
      const { data: override } = await adminClient
        .from('account_limits')
        .select('monthly_analyses')
        .eq('account_id', userData.user!.id)
        .maybeSingle();
      const limit = (override?.monthly_analyses as number | null) ?? DEFAULT_MONTHLY_ANALYSES;

      // Counted here rather than through an RPC: the helper would have to
      // live in a schema PostgREST exposes, and a security-definer function
      // taking an account id in a schema anyone can call is a way to ask how
      // much somebody else has used.
      const now = new Date();
      const monthStart = new Date(
        Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1),
      ).toISOString();
      const { count, error } = await adminClient
        .from('usage_events')
        .select('id', { count: 'exact', head: true })
        .eq('account_id', userData.user!.id)
        .eq('service', 'separation')
        .eq('cached', false)
        .gte('created_at', monthStart);
      if (error || count == null || count < limit) return null;

      return `That's ${limit} analyses this month, which is the ceiling for now. ` +
        'It resets on the 1st. Everything you have already analysed still opens ' +
        'normally, and re-analysing those costs nothing — get in touch if you ' +
        'need the ceiling raised.';
    } catch (_) {
      return null;
    }
  }

  /// Moves a previous analysis's stems into the directory this caller needs
  /// them in. True when all of them are in place afterwards.
  ///
  /// Copies rather than pointing at the originals so every band's stems stay
  /// inside their own room's storage prefix, where the bucket policies can
  /// reach them. Storage does the copy server-side, so the audio never passes
  /// through this function.
  async function copyStems(fromBucket: string, fromDir: string, names: Stem[]): Promise<boolean> {
    if (fromBucket === bucket && fromDir === stemDir) {
      // The same project (or the same Studio idea) re-analyzing the same
      // recording: the stems are already exactly where they need to be.
      // Confirm the objects still exist rather than trusting a row that
      // could outlive them.
      const { data: listed, error } = await adminClient.storage.from(bucket).list(stemDir);
      if (error || !listed) return false;
      const present = new Set(listed.map((object) => object.name));
      return names.every((stem) => present.has(`${stem}.mp3`));
    }
    try {
      for (const stem of names) {
        const to = stemPathIn(stemDir, stem);
        await adminClient.storage.from(bucket).remove([to]);
        const { error } = await adminClient.storage
          .from(fromBucket)
          .copy(stemPathIn(fromDir, stem), to, { destinationBucket: bucket });
        if (error) return false;
      }
      return true;
    } catch {
      return false;
    }
  }

  /// A finished analyze-chords response for a recording that has been through
  /// the pipeline before, or null to say "run it for real".
  async function reuseCachedAnalysis(sha: string): Promise<Record<string, unknown> | null> {
    // Ordered best-first: a full analysis answers a quick request, but never
    // the other way round.
    const { data: rows, error } = await adminClient
      .from('analysis_cache')
      .select('*')
      .eq('audio_sha256', sha)
      .in('pipeline_version', cacheVersionsFor(depth));
    if (error || !rows || rows.length === 0) return null;
    const preferred = cacheVersionsFor(depth);
    const cached = rows.sort(
      (left, right) =>
        preferred.indexOf(left.pipeline_version as string) -
        preferred.indexOf(right.pipeline_version as string),
    )[0];

    let stems: { stem: string; storagePath: string }[] = [];
    if (projectId || draftId) {
      const names = ((cached.stems as string[] | null) ?? []).filter((stem): stem is Stem =>
        (STEMS as readonly string[]).includes(stem)
      );
      // A cached row whose stems were never kept, or whose objects have since
      // been deleted, is only half a hit. Regenerating just the stems means
      // running the separation job anyway, so there is nothing left to save —
      // fall through to a full run rather than hand back an analysis whose
      // stem player is quietly empty.
      if (names.length === 0 || !cached.stem_bucket || !cached.stem_dir) return null;
      const copied = await copyStems(
        cached.stem_bucket as string,
        cached.stem_dir as string,
        names,
      );
      if (!copied) return null;
      stems = names.map((stem) => ({ stem, storagePath: stemPathIn(stemDir, stem) }));
      await persistStems(stems);
    }

    await adminClient
      .from('analysis_cache')
      .update({
        last_used_at: new Date().toISOString(),
        hit_count: ((cached.hit_count as number | null) ?? 0) + 1,
      })
      .eq('audio_sha256', sha);

    // A hit is the cheapest outcome there is, and worth logging precisely
    // because of that: it's the evidence that the cache is earning its keep.
    // The copied stems are still real bytes somebody pays to store.
    await recordUsage({ service: 'separation', cached: true, audioMs, sha });
    await recordUsage({ service: 'chords', cached: true, sha });
    if (stems.length > 0) {
      await recordUsage({ service: 'storage', bytes: await stemBytesIn(stemDir), sha });
    }

    return {
      status: 'complete',
      // Purely informational: the app uses it to say it recognized the
      // recording instead of pretending to have done the work again.
      cached: true,
      cues: cached.cues ?? [],
      key: cached.musical_key ?? null,
      bpm: cached.bpm ?? null,
      beatsMs: cached.beats_ms ?? [],
      downbeatsMs: cached.downbeats_ms ?? [],
      beatsPerBar: cached.beats_per_bar ?? null,
      instruments: cached.instruments ?? null,
      structure: cached.structure ?? [],
      stems,
      vocalStemPath: stems.find((entry) => entry.stem === 'vocals')?.storagePath ?? null,
    };
  }

  // ── start ──────────────────────────────────────────────────────────────
  // Submits the separation job and returns immediately with its id.
  //
  // This function used to poll RunPod to completion inline, which meant one
  // request sat awaiting a multi-minute GPU job while producing no output —
  // and Supabase kills a function that goes 150s without activity
  // (IDLE_TIMEOUT). Raising the poll ceiling only moves that wall; handing
  // the job id back and letting the app do the waiting removes it. The app
  // can wait as long as it likes, and show real progress while it does.
  if (action === 'start') {
    // No need to pull the file into the function's own memory at all — the
    // separation_service worker downloads it directly from this signed URL,
    // which also sidesteps RunPod's 10MiB request-body cap entirely rather
    // than trying to squeeze under it. Long-lived because the worker may not
    // pick the job up until after a cold start.
    const { data: signedUrlData, error: signedUrlError } = await adminClient.storage
      .from(bucket)
      .createSignedUrl(storagePath, 3600);
    if (signedUrlError || !signedUrlData) {
      return json({ error: `Could not create signed URL: ${signedUrlError?.message ?? 'not found'}` }, 404);
    }
    const filename = storagePath.split('/').pop() ?? 'audio.mp3';

    // Read the whole recording once, cheaply, before spending anything on it.
    // A few seconds of streaming inside Supabase's own network is the price
    // of possibly skipping a multi-minute GPU job.
    if (acceptsCachedAnalysis) {
      const audioSha256 = await sha256OfUrl(signedUrlData.signedUrl);
      if (audioSha256) {
        const reused = await reuseCachedAnalysis(audioSha256);
        if (reused) return json(reused);
      }
    }

    // Checked only after the cache has had its chance, and only for work that
    // is actually going to run. A cache hit costs nothing, so spending quota
    // on one would penalise the exact behaviour that saves the money —
    // analysing a song a bandmate already analysed should be free in every
    // sense of the word.
    const refusal = await monthlyLimitRefusal();
    if (refusal) return json({ error: refusal }, 429);

    await adminClient.storage.from(bucket).remove([mixPath]);
    const { data: mixUploadData } = await adminClient.storage
      .from(bucket)
      .createSignedUploadUrl(mixPath);
    const mixUpload = mixUploadData?.signedUrl ?? null;

    // Quick keeps the vocal stem and nothing else. Not an oversight: the
    // lyrics pass transcribes that stem rather than the full mix, and doing
    // so is the single largest lever on lyric accuracy in the whole pipeline.
    // Dropping it to save an upload would make the fast option the inaccurate
    // one, which is not the trade being offered.
    const wantedStems: readonly Stem[] = depth === 'quick' ? (['vocals'] as const) : STEMS;
    const stemUploads: Record<string, string> = {};
    if (projectId || draftId) {
      // Re-analysis reuses the same object names; clear them first so a fresh
      // signed upload URL can't collide with a stale object.
      await adminClient.storage.from(bucket).remove(STEMS.map((stem) => stemPathIn(stemDir, stem)));
      // And sweep the flat directory analyses used before stem folders were
      // named after the recording. The rows that pointed at those objects are
      // about to be replaced by persistStems, so leaving them would be a
      // permanent copy of every stem this project ever had.
      await adminClient.storage.from(bucket).remove([
        ...STEMS.map((stem) => stemPathIn(legacyStemDir, stem)),
        `${legacyStemDir}/_harmonic_mix.mp3`,
      ]);
      // Only mint URLs for the stems this depth keeps — the worker uploads
      // exactly what it's given somewhere to put.
      for (const stem of wantedStems) {
        const { data: upload } = await adminClient.storage
          .from(bucket)
          .createSignedUploadUrl(stemPathIn(stemDir, stem));
        if (upload?.signedUrl) stemUploads[stem] = upload.signedUrl;
      }
    }

    try {
      const startedJobId = await submitSeparation(
        signedUrlData.signedUrl,
        filename,
        stemUploads,
        mixUpload,
        depth === 'quick',
      );
      return json({ status: 'started', jobId: startedJobId });
    } catch (error) {
      return json({ error: error instanceof Error ? error.message : String(error) }, 502);
    }
  }

  // ── poll ───────────────────────────────────────────────────────────────
  // Cheap while the job runs. Once separation completes, this is also the
  // call that runs chord detection and persists the stems — a few seconds of
  // work, comfortably inside the idle limit.
  try {
    const separation = await readSeparation(jobId!);
    if (separation == null) return json({ status: 'pending' });

    let mixBlob: Blob;
    if (separation.mixUploaded) {
      const { data: mixDownload, error: mixError } = await adminClient.storage
        .from(bucket)
        .download(mixPath);
      if (mixError || !mixDownload) {
        throw new Error(`Could not read the harmonic mix back: ${mixError?.message ?? 'missing'}`);
      }
      mixBlob = mixDownload;
    } else {
      // Legacy inline path — only reachable against a worker image that
      // predates mix_upload support.
      mixBlob = new Blob([base64ToBytes(separation.harmonicMixB64 ?? '')]);
    }

    const chordsStartedAt = Date.now();
    const chords = await detectChords(mixBlob);
    const chordsMs = Date.now() - chordsStartedAt;
    // Reclaim the intermediate as soon as the chord service has read it;
    // nothing downstream needs it and it is the largest object in the job.
    await adminClient.storage.from(bucket).remove([mixPath]);
    const key = separation.key ?? estimateKeyFallback(chords);

    let stems: { stem: string; storagePath: string }[] = [];
    if (projectId || draftId) {
      stems = separation.uploadedStems
        .filter((stem): stem is Stem => (STEMS as readonly string[]).includes(stem))
        .map((stem) => ({ stem, storagePath: stemPathIn(stemDir, stem) }));
    }
    await persistStems(stems);

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

    // A run that named no chords at all is the one a musician retries, and
    // caching it would make retrying pointless — the same empty answer,
    // instantly, forever. Only a result worth having gets remembered.
    const worthCaching = cues.length > 0;

    // Which recording this was. Hashed again here rather than carried over
    // from `start`, because the alternatives are worse: handing the key to
    // the app and taking it back would let a client file one song's analysis
    // under another song's hash and hand every other band the wrong chords,
    // and a table of job breadcrumbs would put `poll` back in the business of
    // remembering things. Reading the audio a second time costs a couple of
    // seconds inside Supabase's own network, once, at the end of a job that
    // just spent minutes on a GPU — and nothing depends on the result, so a
    // failure here only means this run doesn't get cached.
    const { data: rehashUrl } = worthCaching
      ? await adminClient.storage.from(bucket).createSignedUrl(storagePath, 600)
      : { data: null };
    const audioSha256 = rehashUrl ? await sha256OfUrl(rehashUrl.signedUrl) : null;

    // Remember this run so the next one doesn't have to happen. Written last,
    // after every step that could still fail, so the cache only ever holds
    // analyses that were actually delivered. Best-effort: a song that
    // analyzed successfully should reach the user whether or not it could
    // also be filed away.
    if (audioSha256) {
      // hit_count is deliberately absent — an upsert only overwrites the
      // columns it names, so a re-analysis of the same recording under the
      // same pipeline keeps the running total rather than resetting it.
      await adminClient.from('analysis_cache').upsert(
        {
          audio_sha256: audioSha256,
          // Written under this depth's own key, so a quick run can never be
          // handed back as a full one.
          pipeline_version: depth === 'quick' ? QUICK_PIPELINE_VERSION : PIPELINE_VERSION,
          cues,
          musical_key: key,
          bpm: separation.bpm,
          beats_ms: separation.beatsMs,
          downbeats_ms: separation.downbeatsMs,
          beats_per_bar: separation.beatsPerBar,
          instruments: separation.instruments,
          structure: separation.structure,
          stem_bucket: stems.length > 0 ? bucket : null,
          stem_dir: stems.length > 0 ? stemDir : null,
          stems: stems.map((entry) => entry.stem),
          last_used_at: new Date().toISOString(),
        },
        { onConflict: 'audio_sha256,pipeline_version' },
      );
    }

    // What this run consumed, recorded whether or not it was worth caching —
    // the GPU time was spent either way. After the hash so these rows can be
    // tied to the cache entry that may serve the next request for free.
    await recordUsage({
      service: 'separation',
      audioMs,
      computeMs: separation.executionMs,
      sha: audioSha256,
    });
    await recordUsage({ service: 'chords', computeMs: chordsMs, sha: audioSha256 });
    if (stems.length > 0) {
      await recordUsage({
        service: 'storage',
        bytes: await stemBytesIn(stemDir),
        sha: audioSha256,
      });
    }

    return json({
      status: 'complete',
      cues,
      key,
      bpm: separation.bpm,
      beatsMs: separation.beatsMs,
      downbeatsMs: separation.downbeatsMs,
      beatsPerBar: separation.beatsPerBar,
      instruments: separation.instruments,
      structure: separation.structure,
      stems,
      // The lyrics pass transcribes this instead of the raw mix when present.
      vocalStemPath: stems.find((entry) => entry.stem === 'vocals')?.storagePath ?? null,
    });
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : String(error) }, 502);
  }
});
