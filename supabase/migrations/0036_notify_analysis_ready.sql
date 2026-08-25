-- Tell the person who started an analysis when it has actually finished.
--
-- Until now the only way to learn that was to sit and watch the progress
-- ring. That is the wrong shape for this app: songwriting is the reason
-- somebody opened it, and the analysis is a thing that happens *to* a song
-- they should be free to keep writing. The wait is real — a multi-minute GPU
-- job — so the fix is not to make it faster but to stop requiring anyone to
-- witness it.
--
-- Fires from the database rather than the client on purpose. The app drives
-- the analysis by polling, so it is tempting to notify from there — but then
-- the notification only exists if the same device that started the job is
-- still the one that finished it. A trigger on the row that records the
-- outcome fires whenever the outcome lands, whoever collected it.
--
-- Guarded on the transition rather than the value. `analysis_state` is
-- written repeatedly during a run (uploaded -> queued -> processing ->
-- ready), and a re-analysis of an already-ready recording sets 'ready' again
-- at the end; without `is distinct from`, every one of those writes would
-- send another notification for a song that finished once.

create or replace function public.notify_analysis_ready()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
declare
  song record;
begin
  select id, room_id, title into song
  from public.projects
  where id = new.project_id;

  perform private.notify_user(
    new.uploaded_by,
    'analysis_ready',
    coalesce(song.title, 'Your song') || ' is ready',
    'Key, tempo, chords and structure are on the song sheet.',
    song.room_id,
    new.project_id,
    null,
    -- Null rather than the uploader: notify_user returns early when the
    -- target and the actor are the same person, which is right for social
    -- notifications ("don't tell me about my own edit") and exactly wrong
    -- here, where the recipient is meant to be the person who asked.
    null
  );
  return null;
end;
$$;

revoke all on function public.notify_analysis_ready() from public, anon, authenticated;

create trigger project_audio_references_notify_ready
after update on public.project_audio_references
for each row
when (old.analysis_state is distinct from 'ready' and new.analysis_state = 'ready')
execute function public.notify_analysis_ready();
