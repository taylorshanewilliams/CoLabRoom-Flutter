-- Replaces a fabricated accuracy number with a measured one.
--
-- ChordMini's .lab output carries chord labels and nothing else — no
-- per-segment confidence — so the pipeline stamped a flat 0.8 on every cue
-- and the app averaged those into "Chord confidence: 80%". It read 80% on
-- every song, always, regardless of how well the model did, in exactly the
-- place a musician looks to decide whether to trust the sheet.
--
-- Coverage is the honest version of the same question: what fraction of the
-- recording the model actually named a chord over, as opposed to leaving as
-- "N" (no chord). A song that comes back 95% covered was understood; one at
-- 40% was mostly guessed at, and the musician should know which they have.
--
-- chord_confidence is left in place but stops being written. Existing rows
-- keep their 0.8, distinguishable by analyzer_version.

alter table public.project_audio_references
  add column if not exists chord_coverage double precision
    check (chord_coverage is null or chord_coverage between 0 and 1);

alter table public.studio_drafts
  add column if not exists chord_coverage double precision
    check (chord_coverage is null or chord_coverage between 0 and 1);

comment on column public.project_audio_references.chord_coverage is
  'Fraction of the recording covered by a named chord. Measured, unlike the '
  'flat placeholder chord_confidence it replaces.';
