-- Songs on somebody's profile that you can actually listen to.
--
-- The half of the profile that has been missing since the day it was built.
-- A profile could say who somebody is, what they play, what they have
-- recorded and where else to find them — everything except the one thing a
-- musician judges another musician by, which is the sound.
--
-- It waited on 0067. There was no such thing as a song a stranger could open,
-- so there was nothing for a profile to point at.
--
-- **Owned or played on.** Not just songs they wrote. A bass player who has
-- never written a song is exactly the person Open Mic exists to help, and an
-- owner-only definition would leave their profile permanently empty while
-- they played on twenty records. If your take is on it and the room heard it,
-- it is your work too — which is the same rule `parts_recorded_by` has
-- counted by since 0058.
--
-- **Only what is already on the Open Mic.** This grants nothing new. A song
-- appears here because its owner put it up, and it disappears when they take
-- it down. Somebody's profile is not a way around a decision their bandmate
-- made about their catalog.

create or replace function public.songs_by(target_profile uuid)
returns table (
  id uuid,
  title text,
  owner_id uuid,
  owner_name text,
  open_mic_at timestamptz,
  take_count bigint,
  asking_for text[],
  -- What this person did on it: null when it is theirs, otherwise the parts
  -- they played. A profile that said "Ladder Of Life" without saying they
  -- played the bass on it would be claiming somebody else's song.
  their_parts text[]
)
language sql
stable
security definer
set search_path = public
as $$
  select
    p.id,
    p.title,
    p.created_by,
    pr.display_name,
    p.open_mic_at,
    (select count(*) from public.song_layers l
      where l.project_id = p.id and l.shared_at is not null),
    coalesce(
      (select array_agg(distinct a.part)
         from public.project_asks a
        where a.project_id = p.id
          and a.status = 'open'
          and a.part is not null),
      '{}'::text[]
    ),
    coalesce(
      (select array_agg(distinct l.part::text)
         from public.song_layers l
        where l.project_id = p.id
          and l.recorded_by = target_profile
          and l.shared_at is not null),
      '{}'::text[]
    )
  from public.projects p
  left join public.profiles pr on pr.id = p.created_by
  where p.open_mic_at is not null
    and p.deleted_at is null
    and not private.blocked_between((select auth.uid()), target_profile)
    and (
      p.created_by = target_profile
      or exists (
        select 1 from public.song_layers l
        where l.project_id = p.id
          and l.recorded_by = target_profile
          and l.shared_at is not null
      )
    )
  order by p.open_mic_at desc
  limit 30;
$$;

revoke all on function public.songs_by(uuid) from public, anon;
grant execute on function public.songs_by(uuid) to authenticated;
