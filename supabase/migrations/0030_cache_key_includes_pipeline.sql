-- One cached analysis per recording *per pipeline*, not per recording.
--
-- analysis_cache was keyed on the audio hash alone, which was right while
-- there was exactly one way to analyze a song. There are now two: the full
-- pass, and the chords-and-lyrics pass that skips section naming.
--
-- With the old key those two collide. A quick run would overwrite the full
-- row it should have sat beside — and since a full request only matches the
-- full pipeline_version, the next full analysis would miss, re-run, overwrite
-- the quick row, and the two would take turns evicting each other forever.
-- Every analysis a cache miss, on a table whose entire purpose is to prevent
-- that.
--
-- pipeline_version was already stored and already checked on read. It just
-- wasn't part of the key, which made the read a filter over a row that might
-- be the wrong one rather than a lookup of the right one.

alter table public.analysis_cache
  drop constraint analysis_cache_pkey;

alter table public.analysis_cache
  add constraint analysis_cache_pkey primary key (audio_sha256, pipeline_version);
