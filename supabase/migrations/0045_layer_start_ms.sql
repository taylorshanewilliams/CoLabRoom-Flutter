-- Where a take begins, as opposed to how much of its front to throw away.
--
-- Every take has been mixed from song time zero. offset_ms exists already and
-- looks like it should cover this, but it means the opposite thing: it is the
-- latency trim, how many milliseconds to drop off the front of the recording
-- so the first sample kept is the one that was playing when the backing track
-- started. Both numbers are milliseconds and both sit at the front of a take,
-- which is exactly why they need different names.
--
-- Without this, punching in at 2:40 records a harmony over the last chorus
-- and then mixes it in over the intro. There is no way to express "this take
-- belongs here" with a trim.
alter table public.song_layers
  add column if not exists start_ms integer not null default 0
    check (start_ms >= 0);

comment on column public.song_layers.start_ms is
  'Milliseconds into the song where this take begins. Zero for a take '
  'recorded from the top, which is every take recorded before punch-in '
  'existed — which is why the default is what it is rather than nullable.';

comment on column public.song_layers.offset_ms is
  'Latency trim: milliseconds dropped from the FRONT of the recording, '
  'because a phone records a moment behind what it plays. Not to be confused '
  'with start_ms, which is where the take sits on the song.';
