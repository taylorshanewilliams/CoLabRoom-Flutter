-- Your people have pages.
--
-- The audit of 17 September 2026 found musician_profile open to three kinds
-- of person: yourself, anybody listed in Open Mic, and anybody you share a
-- room with. Not your connections. So the person you met at a gig and added
-- by scanning codes (0130) -- not listed, no room together yet, which is the
-- ordinary case -- had no page: "There is no profile here to show you." from
-- Your people, from "You and Sam are connected", and from Home's "Wants to
-- connect · See who", where the answer to their request now lives.
--
-- A connection is somebody you chose, or somebody who chose you and is
-- waiting on your answer, so either direction and either state opens the
-- page. Deciding whether to add somebody back is exactly when you need to see
-- who they are; the card their code opened (0130) already showed the name,
-- picture and parts. Settings stay private as before, the city still follows
-- location_visibility, and a block still closes everything.
--
-- The return shape is unchanged, so this is create or replace. Everything
-- except the last `or exists` is exactly as 0107 left it.

create or replace function public.musician_profile(target uuid)
returns table (
  id uuid,
  display_name text,
  avatar_path text,
  city text,
  plays text[],
  sounds_like text[],
  bio text,
  parts_recorded jsonb,
  songs_played_on bigint,
  people_worked_with bigint,
  discoverable boolean,
  location_visibility text,
  vocal_low_midi integer,
  vocal_high_midi integer,
  vocal_range_songs integer
)
language sql
stable
security definer
set search_path = public
as $$
  select
    p.id,
    p.display_name,
    p.avatar_path,
    case
      when p.id = (select auth.uid()) then p.city
      when p.location_visibility = 'public' then p.city
      else null
    end,
    p.plays,
    p.sounds_like,
    p.bio,
    public.parts_recorded_by(p.id),
    (select count(distinct l.project_id) from public.song_layers l
      where l.recorded_by = p.id and l.shared_at is not null),
    (select count(distinct other.recorded_by)
       from public.song_layers mine
       join public.song_layers other on other.project_id = mine.project_id
      where mine.recorded_by = p.id
        and mine.shared_at is not null
        and other.shared_at is not null
        and other.recorded_by <> p.id),
    case when p.id = (select auth.uid()) then p.discoverable else null end,
    case when p.id = (select auth.uid()) then p.location_visibility else null end,
    case when sings.yes then sung.low end,
    case when sings.yes then sung.high end,
    case when sings.yes then sung.songs else 0 end
  from public.profiles p
  cross join lateral (
    select coalesce(p.plays, array[]::text[]) && array['vocal', 'harmony', 'rap']::text[] as yes
  ) sings
  cross join lateral (
    select
      min(r.melody_low_midi)::integer as low,
      max(r.melody_high_midi)::integer as high,
      count(*)::integer as songs
    from public.project_audio_references r
    join public.projects pj on pj.id = r.project_id and pj.deleted_at is null
    where r.uploaded_by = p.id
      and r.melody_low_midi is not null
      and r.melody_high_midi is not null
  ) sung
  where p.id = target
    -- A blocked profile has no page, the same way a profile that never opted
    -- in has no page. Returning nothing is the honest answer and it is also
    -- the one that says least.
    and not private.blocked_between((select auth.uid()), p.id)
    and (
      p.id = (select auth.uid())
      or p.discoverable
      or exists (
        select 1 from public.room_members rm
        where rm.user_id = p.id and private.is_room_member(rm.room_id)
      )
      -- 0137: one of your people, or somebody asking to be, either way round.
      or exists (
        select 1 from public.connections c
        where (c.requester_id = (select auth.uid()) and c.addressee_id = p.id)
           or (c.requester_id = p.id and c.addressee_id = (select auth.uid()))
      )
    );
$$;

revoke all on function public.musician_profile(uuid) from public, anon;
grant execute on function public.musician_profile(uuid) to authenticated;
