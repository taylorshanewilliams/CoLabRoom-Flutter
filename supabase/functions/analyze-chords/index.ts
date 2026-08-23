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

// htdemucs_6s sources. Order matters only for display; `vocals` is called out
// separately below because the lyrics pass reads it.
const STEMS = ['vocals', 'drums', 'bass', 'guitar', 'piano', 'other'] as const;
type Stem = (typeof STEMS)[number];

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
  try {
    const body = await req.json();
    storagePath = body.storagePath;
    bucket = body.bucket ?? 'room-files';
    projectId = typeof body.projectId === 'string' && body.projectId.length > 0 ? body.projectId : null;
    draftId = typeof body.draftId === 'string' && body.draftId.length > 0 ? body.draftId : null;
    action = typeof body.action === 'string' ? body.action : 'start';
    jobId = typeof body.jobId === 'string' && body.jobId.length > 0 ? body.jobId : null;
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

  // Stems live beside the reference recording: <room>/<project>/analysis/stems/<stem>.mp3.
  // That keeps the first two path segments intact, which is what the
  // room-files storage policies match on for room and project membership.
  // Derived from storagePath rather than carried between calls, so `poll`
  // needs no server-side state to find what `start` set up.
  const analysisDir = storagePath.split('/').slice(0, -1).join('/');
  const stemPathFor = (stem: Stem) => `${analysisDir}/stems/${stem}.mp3`;

  // The harmonic mix goes through Storage rather than the job payload, for
  // every caller including ones without a projectId. Inlining it as base64
  // meant this function held the encoded string, the decoded binary string
  // and the byte array simultaneously — roughly 4x the file — which is what
  // produced WORKER_RESOURCE_LIMIT on a four-minute song. Not persisted in
  // project_stems: it's an intermediate for the chord service, not a stem
  // anyone plays.
  const mixPath = `${analysisDir}/stems/_harmonic_mix.mp3`;

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

    await adminClient.storage.from(bucket).remove([mixPath]);
    const { data: mixUploadData } = await adminClient.storage
      .from(bucket)
      .createSignedUploadUrl(mixPath);
    const mixUpload = mixUploadData?.signedUrl ?? null;

    const stemUploads: Record<string, string> = {};
    if (projectId || draftId) {
      // Re-analysis reuses the same object names; clear them first so a fresh
      // signed upload URL can't collide with a stale object.
      await adminClient.storage.from(bucket).remove(STEMS.map(stemPathFor));
      for (const stem of STEMS) {
        const { data: upload } = await adminClient.storage
          .from(bucket)
          .createSignedUploadUrl(stemPathFor(stem));
        if (upload?.signedUrl) stemUploads[stem] = upload.signedUrl;
      }
    }

    try {
      const startedJobId = await submitSeparation(
        signedUrlData.signedUrl,
        filename,
        stemUploads,
        mixUpload,
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

    const chords = await detectChords(mixBlob);
    // Reclaim the intermediate as soon as the chord service has read it;
    // nothing downstream needs it and it is the largest object in the job.
    await adminClient.storage.from(bucket).remove([mixPath]);
    const key = separation.key ?? estimateKeyFallback(chords);

    let stems: { stem: string; storagePath: string }[] = [];
    const analyzedProjectId = projectId;
    const analyzedDraftId = draftId;
    if (analyzedProjectId || analyzedDraftId) {
      stems = separation.uploadedStems
        .filter((stem): stem is Stem => (STEMS as readonly string[]).includes(stem))
        .map((stem) => ({ stem, storagePath: stemPathFor(stem) }));
    }
    // Clear first in both cases: a re-analysis where some stem failed to
    // upload this time would otherwise leave a row pointing at an object
    // deleted before the job started, i.e. a playback entry that 404s.
    // Service role throughout — neither stem table has an insert policy for
    // `authenticated` on purpose, same trust model as notifications.
    if (analyzedProjectId) {
      await adminClient.from('project_stems').delete().eq('project_id', analyzedProjectId);
      if (stems.length > 0) {
        await adminClient.from('project_stems').insert(
          stems.map((entry) => ({
            project_id: analyzedProjectId,
            stem: entry.stem,
            storage_path: entry.storagePath,
          })),
        );
      }
    } else if (analyzedDraftId) {
      await adminClient.from('studio_draft_stems').delete().eq('draft_id', analyzedDraftId);
      if (stems.length > 0) {
        await adminClient.from('studio_draft_stems').insert(
          stems.map((entry) => ({
            draft_id: analyzedDraftId,
            stem: entry.stem,
            storage_path: entry.storagePath,
          })),
        );
      }
    }

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
