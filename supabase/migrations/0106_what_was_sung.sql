-- The sung melody, as notes.
--
-- The pipeline has separated the vocal, timed every word and named every
-- chord since the first sheet, and never once heard a *note*. "What works
-- here" (#203) says out loud that its harmony notes come from the chord and
-- not from the tune, because there was no tune to read. The worker now runs
-- a pitch tracker (pyin) over the isolated vocal stem and groups the curve
-- into notes: start, end, MIDI number, cents from it.
--
-- Two homes, same as every other analysis result. The cache row, so a
-- recognised recording does not pay to be heard again; and the reference
-- row, which is what the app reads. The low and high notes get their own
-- columns on the reference so a vocal range across an account's songs is
-- one aggregate rather than a JSON walk.
--
-- Nullable everywhere. An instrumental has no melody; an analysis from an
-- older worker has no melody; both are the answer "none", not an error.

alter table public.analysis_cache
  add column if not exists melody jsonb;

comment on column public.analysis_cache.melody is
  'The sung melody from the vocal stem: {notes: [{start_ms, end_ms, midi, '
  'cents}], low_midi, high_midi, voiced_ratio}. Null for an instrumental or '
  'a worker that predates it.';

alter table public.project_audio_references
  add column if not exists melody jsonb,
  add column if not exists melody_low_midi integer
    check (melody_low_midi is null or melody_low_midi between 0 and 127),
  add column if not exists melody_high_midi integer
    check (melody_high_midi is null or melody_high_midi between 0 and 127);

comment on column public.project_audio_references.melody is
  'What was sung, as notes. Same shape as analysis_cache.melody.';
comment on column public.project_audio_references.melody_low_midi is
  'The lowest sung note that lasted; with melody_high_midi, the vocal range '
  'of this recording.';
