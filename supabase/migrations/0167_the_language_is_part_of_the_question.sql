-- The language a transcript was heard in, kept beside the transcript.
--
-- Every Musician, Same Song, 17 September 2026, world traditions item 3.
-- Migration 0163 let a room say what language a song is sung in, and that
-- answer reached the transcriber on two paths: the fallback, and the offer to
-- listen again. It did not reach the first listen — the transcription that
-- happens inside the GPU worker during a normal analysis, which is where
-- nearly every transcript in this app actually comes from. So Whisper went on
-- guessing there, and a song in Portuguese sung over loud guitars came back
-- as Spanish, or as nothing, no matter what its room had said.
--
-- Telling the worker is the Edge Function's work. What the database has to
-- hold is the consequence: an analysis is cached by the SHA-256 of the audio
-- (0024) so the same recording is never separated twice, and a transcript
-- made in one language is not the words to a song sung in another. Without
-- somewhere to write down which language a stored transcript was heard in,
-- the first Spanish answer would be handed to every Portuguese song that ever
-- shared those bytes, for ever, and asking to hear it again would change
-- nothing.
--
-- Two columns, both nullable, nothing backfilled and nothing deleted. Null
-- means "this transcript cannot say what it was heard in", which is true of
-- every row written before today and is treated as such: a song that has
-- declared a language re-analyses once and fills it in, and a song that has
-- not declared one finds exactly the rows it always did. Filling these in
-- from the outside is not possible and not worth guessing at -- inferring a
-- language from the words is the guess this whole feature exists to refuse.

-- ---------------------------------------------------------------------
-- What a cached analysis was heard in
-- ---------------------------------------------------------------------

-- Not part of the key. Adding it to the primary key would file the same
-- recording under one row per language and pay for the GPU again for each,
-- which is the opposite of what this table is for. The key stays (audio,
-- pipeline) and this is read after the row is found: a declared language
-- makes a row a hit only when the row agrees, and no declared language asks
-- nothing of it.
alter table public.analysis_cache
  add column if not exists transcript_language text;

comment on column public.analysis_cache.transcript_language is
  'The language this row''s transcript was heard in, as the worker reports '
  'it -- the language it was told (0163) or the one it detected when it was '
  'told nothing. Null on every row written before the worker reported it, '
  'and on a worker image that predates the language reaching it. Never '
  'assumed from what the worker was asked for: a worker that ignored the '
  'language would otherwise file its guess under the right name.';

-- ---------------------------------------------------------------------
-- What the words on this song were heard in
-- ---------------------------------------------------------------------

-- The same fact, on the song itself, because the sheet asks a question of
-- it: having just been told what a song is sung in, is it worth offering to
-- listen to the recording again? Before this the answer was always yes, and
-- on a song whose first listen already used that language that offer costs
-- money to replace the words with the same words.
--
-- Not a shared decision like projects.language, which is why it is a plain
-- column rather than an RPC: nobody says this, the transcriber reports it,
-- and it is written by whoever ran the analysis under the row-level policies
-- project_audio_references already has for every other thing the analysis
-- writes there.
alter table public.project_audio_references
  add column if not exists transcript_language text;

comment on column public.project_audio_references.transcript_language is
  'The language the words on this recording were heard in, as the '
  'transcriber reports it. Null when nothing said -- an analysis from before '
  'this column, or one where the transcriber guessed -- which the app reads '
  'as "not known" rather than as any particular language.';
