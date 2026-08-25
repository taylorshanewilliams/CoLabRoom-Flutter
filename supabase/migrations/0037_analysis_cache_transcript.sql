-- Remember the lyrics along with everything else the analysis produced.
--
-- Transcription used to be a separate step: separation ran on the GPU, and
-- then a second call sent the vocal stem to OpenAI's Whisper API. Only the
-- first half was cached, because only the first half came back from this
-- pipeline — so a cache hit still paid a per-minute API call to hear words
-- the same recording had already been transcribed for.
--
-- The GPU worker now transcribes the stem itself, in the job that separated
-- it, on a model that is already resident in the image. That makes the
-- transcript part of the analysis result rather than a step after it, and
-- something a cached analysis has to carry or lose.
--
-- jsonb rather than two columns, because it stores the shape the worker
-- returns and every consumer already reads: {"text": "...", "words": [{word,
-- start_ms, end_ms}, ...]}. Nullable: an instrumental recording, or a
-- transcript the hallucination guard rejected, legitimately has none, and
-- that absence is itself the cached answer.

alter table public.analysis_cache
  add column if not exists transcript jsonb;
