-- The same idea as analysis_cache (migration 0024), for the other half of
-- the pipeline: don't pay OpenAI to transcribe a vocal it has already heard.
--
-- Transcription is the remaining per-run cost once separation is cached, and
-- it is the step a musician re-runs most often — analysis gets retried
-- because the *words* came back wrong far more than because the chords did.
--
-- Keyed on two hashes, and it has to be both:
--
--   audio_sha256  the vocal stem actually sent to Whisper, not the original
--                 recording. A cache hit on the chord side copies the stem
--                 rather than regenerating it, so those bytes are identical
--                 across projects and this hits alongside it.
--
--   prompt_sha256 the prompt Whisper was primed with, which since migration
--                 0019's lyrics work contains the song's own typed lyrics.
--                 Priming changes the transcript, so a transcript produced
--                 under a different prompt is a different answer to a
--                 different question. Editing your lyrics and re-analyzing
--                 has to actually re-transcribe, and this is what makes that
--                 true rather than something to remember.

create table public.transcript_cache (
  audio_sha256 text not null,
  prompt_sha256 text not null,

  -- Not part of the key: a model change makes every stored transcript the
  -- wrong answer rather than a differently-keyed one, so the row is matched
  -- on it and replaced when it changes.
  model text not null,

  transcript_text text not null,
  -- Word-level timings, exactly as the Edge Function returns them:
  -- [{word, start_ms, end_ms}]. The timings are the expensive part — plain
  -- text could be retyped, but nobody can hand-align 400 words.
  words jsonb not null,

  created_at timestamptz not null default now(),
  last_used_at timestamptz not null default now(),
  hit_count integer not null default 0,

  primary key (audio_sha256, prompt_sha256)
);

-- Service role only, no policies — same reasoning as analysis_cache: a
-- client that could write here could put words in another band's song, and a
-- client that could read here could ask whether a given recording exists
-- anywhere in the system from its hash alone.
alter table public.transcript_cache enable row level security;
