-- Nobody is ranked.
--
-- `find_musicians` sorted people who had *recorded* a part above people who
-- had only said they play it. The reasoning was that a declaration is a hope
-- and a recording is a fact, and a list should lead with facts.
--
-- The effect is that the newest person in the app is always last. Somebody
-- who joined this morning, who plays perfectly well and has simply not
-- recorded here yet, is below everybody — every search, every time, until
-- they have built up a record they cannot build without first being found.
-- That is a ladder, and this app should not have one.
--
-- **Rotation instead of ranking.** Everybody who plays the thing is shuffled,
-- deterministically per day: the order is stable while somebody is looking,
-- and different tomorrow. A beginner appears above a session player about
-- half the time, which is roughly how often it should happen in a room where
-- the point is finding somebody who fits rather than somebody who scores.
--
-- The record is still on the profile. It is evidence for anybody who wants
-- it, and it is not a position in a queue.
--
-- The same principle applies everywhere and is worth writing down once: the
-- feed is newest-first and must never become most-liked; there are no badges,
-- no levels and no streaks. Every one of those is a way of telling somebody
-- they are not good enough yet, in an app whose whole purpose is that they
-- get to be part of it anyway.

create or replace function public.find_musicians(
  in_part text default null,
  in_city text default null,
  in_limit integer default 30
)
returns table (
  id uuid,
  display_name text,
  avatar_path text,
  city text,
  plays text[],
  parts_recorded jsonb,
  songs_played_on bigint,
  people_worked_with bigint
)
language sql
security definer
set search_path = public
as $$
  select
    p.id,
    p.display_name,
    p.avatar_path,
    case when p.location_visibility = 'public' then p.city else null end,
    p.plays,
    public.parts_recorded_by(p.id),
    (select count(distinct l.project_id) from public.song_layers l
      where l.recorded_by = p.id and l.shared_at is not null),
    (select count(distinct other.recorded_by)
       from public.song_layers mine
       join public.song_layers other on other.project_id = mine.project_id
      where mine.recorded_by = p.id
        and mine.shared_at is not null
        and other.shared_at is not null
        and other.recorded_by <> p.id)
  from public.profiles p
  where p.discoverable
    and not private.blocked_between((select auth.uid()), p.id)
    and (
      in_part is null
      or in_part = any(p.plays)
      or exists (
        select 1 from public.song_layers l
        where l.recorded_by = p.id
          and l.shared_at is not null
          and l.part::text = in_part
      )
    )
    and (
      in_city is null
      or (p.location_visibility = 'public'
          and lower(trim(p.city)) = lower(trim(in_city)))
    )
  -- Stable while you look, different tomorrow. Seeded on the day rather than
  -- on random() so scrolling does not reshuffle the list under somebody's
  -- thumb, and on the id as well so two people do not see the same order.
  order by md5(p.id::text || current_date::text)
  limit greatest(least(in_limit, 100), 1);
$$;

revoke all on function public.find_musicians(text, text, integer) from public, anon;
grant execute on function public.find_musicians(text, text, integer) to authenticated;
