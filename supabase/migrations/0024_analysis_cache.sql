-- Never separate the same recording twice.
--
-- Every analysis runs a Demucs job on a RunPod GPU. It is by far the slowest
-- step and the only genuinely expensive one, and it is entirely
-- deterministic: the same bytes in produce the same stems, the same chords,
-- the same beat grid. Re-analyzing a song after a failed lyrics pass, or
-- analyzing the same take in a Studio idea and again in the project it grows
-- into, has been paying for that job over and over to be told what we
-- already knew.
--
-- So the analysis is keyed by the SHA-256 of the audio itself. The Edge
-- Function hashes the recording as it streams out of Storage — no upload
-- change, no client involvement, and it works for recordings uploaded long
-- before this migration.
--
-- Content-addressed rather than keyed on a file or project id on purpose:
-- the same recording uploaded twice under different names, into a different
-- project, by a different member of the band is the case that matters most,
-- and an id-based key would miss all of it.

create table public.analysis_cache (
  audio_sha256 text primary key,

  -- What produced this row. A cache entry is only reusable by the pipeline
  -- that would have produced the identical answer, so a change to the
  -- separation model, the chord model or the beat tracker bumps this
  -- constant in the Edge Function and every older row simply stops matching
  -- (and is replaced on the next real run rather than accumulating).
  pipeline_version text not null,

  -- The analyze-chords response, field for field, so a hit can be returned
  -- without reconstructing anything. cues is ChordMini's output in the
  -- app's shape: [{startMs, endMs, chord, confidence}].
  cues jsonb not null,
  musical_key text,
  bpm double precision,
  beats_ms jsonb,
  downbeats_ms jsonb,
  beats_per_bar integer,
  instruments jsonb,
  structure jsonb,

  -- Where this recording's separated stems were left, so a hit can copy them
  -- into the caller's own room or draft folder instead of regenerating them.
  -- Null when the analysis that filled this row kept no stems — the chords
  -- are still reusable, the stems just have to be remade.
  --
  -- Safe to point at only because stem directories now name the recording
  -- that produced them (see the Edge Function's stemDirFor). They used to be
  -- one flat folder per project, which meant attaching a new reference and
  -- analyzing it overwrote the previous recording's stems in place — a bug
  -- in its own right, and one that would have made every one of these
  -- pointers a lie waiting to happen.
  stem_bucket text,
  stem_dir text,
  stems jsonb,

  created_at timestamptz not null default now(),
  -- Not read by anything yet. They are what will answer "is this cache
  -- earning its storage" and "what can be evicted" when it matters, and
  -- neither question is answerable retroactively.
  last_used_at timestamptz not null default now(),
  hit_count integer not null default 0
);

-- Written and read exclusively by the analyze-chords Edge Function with the
-- service role. No policies at all, deliberately: a client that could write
-- here could hand every band in the app the wrong chords for a song, and a
-- client that could read here could confirm whether a given recording exists
-- anywhere in the system from its hash alone. Same trust model as
-- project_stems.
alter table public.analysis_cache enable row level security;
