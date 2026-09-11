-- Somebody played on your song, and the app never said so.
--
-- Checked in production on 2026-09-11: `project_events` holds 13 `edited`
-- rows and 5 `message` rows, and **not one `recording`**. The kind has been
-- allowed since 0032 and nothing has ever written it. So the single most
-- exciting thing that can happen in this app -- a person recording a part on
-- your song while you were asleep -- has never appeared in "what happened"
-- at all. It produced a notification and then vanished.
--
-- Two things here, and the second is the one worth having.
--
-- A trigger writes the event when a take lands, so a recording is finally
-- news like anything else.
--
-- And `recent_activity` returns where the audio is, so it can be **played
-- from the strip at the top of Your music** without opening anything. That is
-- the difference between being told somebody added a bass part and hearing
-- the bass part.

-- What the event is about, when it is about a row somewhere else.
--
-- Nullable and untyped on purpose: project_events is a stream of different
-- kinds and a foreign key per kind would be five columns that are null four
-- times out of five. The kind says how to read it.
alter table public.project_events
  add column if not exists ref_id uuid;

create or replace function public.remember_layer_as_event()
returns trigger
language plpgsql
security definer set search_path = ''
as $fn$
begin
  -- Shared takes only. A private take is a person practising; it is not news
  -- and putting it in somebody else's feed would publish a thing they did
  -- not publish. See 0057, where recording stopped meaning publishing.
  if new.shared_at is null then
    return new;
  end if;

  insert into public.project_events (project_id, actor_id, kind, body, ref_id)
  values (
    new.project_id,
    new.recorded_by,
    'recording',
    -- The part, when they named one. Read by the app as "added bass" rather
    -- than "added a recording", which is the difference between a fact and a
    -- reason to listen.
    coalesce(nullif(trim(new.part), ''), ''),
    new.id
  );
  return new;
end;
$fn$;

drop trigger if exists song_layers_remember_event on public.song_layers;
create trigger song_layers_remember_event
after insert on public.song_layers
for each row execute function public.remember_layer_as_event();

-- Also when a take is shared later rather than at the moment it is recorded.
drop trigger if exists song_layers_remember_event_on_share on public.song_layers;
create trigger song_layers_remember_event_on_share
after update of shared_at on public.song_layers
for each row
when (old.shared_at is null and new.shared_at is not null)
execute function public.remember_layer_as_event();

-- Where the audio is, so the feed can play it.
--
-- Left join, because most events are not recordings and an event whose layer
-- has since been deleted is still a true thing that happened.
create or replace function public.recent_activity(max_rows integer default 20)
returns table (
  id uuid,
  project_id uuid,
  project_title text,
  kind text,
  body text,
  created_at timestamptz,
  actor_id uuid,
  actor_name text,
  actor_avatar_path text,
  audio_path text,
  audio_ms integer
)
language sql
security invoker
set search_path = public
as $$
  select
    e.id,
    e.project_id,
    p.title as project_title,
    e.kind,
    e.body,
    e.created_at,
    e.actor_id,
    a.display_name as actor_name,
    a.avatar_path as actor_avatar_path,
    l.storage_path as audio_path,
    l.duration_ms as audio_ms
  from public.project_events e
  join public.projects p on p.id = e.project_id
  left join public.profiles a on a.id = e.actor_id
  -- Only for a take that is still shared. Un-sharing a recording has to take
  -- it out of everybody's feed, not just out of the song.
  left join public.song_layers l
    on l.id = e.ref_id
   and e.kind = 'recording'
   and l.shared_at is not null
  where p.deleted_at is null
    and (e.actor_id is null or e.actor_id <> auth.uid())
    and not exists (
      select 1 from public.activity_dismissals d
      where d.event_id = e.id and d.profile_id = auth.uid()
    )
  order by e.created_at desc
  limit greatest(1, least(max_rows, 100));
$$;

revoke all on function public.recent_activity(integer) from public, anon;
grant execute on function public.recent_activity(integer) to authenticated;
