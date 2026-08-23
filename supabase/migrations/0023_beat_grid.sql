-- Beat and downbeat times, so the analysis has a musical grid rather than
-- just a tempo number.
--
-- BPM alone says how fast a song is and nothing about where anything sits in
-- it. Downbeats — the first beat of each bar — are what turn "this chord
-- starts at 1.847 seconds" into "this chord starts on bar 12", and they're
-- the prerequisite for bar lines, a count-in, snapping chords to the grid,
-- and any notation later on.
--
-- Stored as plain millisecond arrays rather than a table of rows: a
-- four-minute song at 120bpm is about 480 beats, always read and written
-- whole, and never queried by individual beat. A row per beat would be
-- hundreds of rows per song bought nothing.

alter table public.project_audio_references
  add column if not exists beats_ms jsonb,
  add column if not exists downbeats_ms jsonb,
  -- Beats per bar, counted from the gaps between downbeats rather than
  -- assumed to be four. Null when the recording gave no confident answer,
  -- which is honest — the UI has been showing "Time signature: not
  -- available yet" since it shipped, and sometimes that stays true.
  add column if not exists beats_per_bar integer
    check (beats_per_bar is null or beats_per_bar between 2 and 12);

alter table public.studio_drafts
  add column if not exists beats_ms jsonb,
  add column if not exists downbeats_ms jsonb,
  add column if not exists beats_per_bar integer
    check (beats_per_bar is null or beats_per_bar between 2 and 12);
