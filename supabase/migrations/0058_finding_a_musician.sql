-- Finding somebody who plays the thing you need.
--
-- The obvious version of this is a form: instrument, genre, location, search.
-- It is also the version that does not work, for a reason every musician
-- knows and no filter can express — "guitarist" tells you almost nothing. A
-- metal guitarist and a jazz guitarist are not interchangeable, and the thing
-- you are actually looking for is somebody who plays *like that*, which is a
-- judgement made with ears in about ten seconds.
--
-- So this schema supports a coarse filter and nothing more. Instrument narrows
-- thousands to dozens; listening picks one. The listening is the product and
-- the filter is only how you get to it.
--
-- **Two kinds of truth about a musician, kept apart.**
--
-- What somebody *says* they play is how they get found for work they want —
-- aspiration included, which is fine and is the point. What somebody *has*
-- played is how you decide to trust them, and it is not declared by anybody:
-- it is counted from the takes they have actually recorded and had kept. The
-- app has been recording that since 0038 without ever using it.
--
-- Both are shown. Neither is allowed to do the other's job.

-- What you would like to be asked for.
--
-- Free text in an array rather than an enum, matching song_layers.part, and
-- for the reason given there: a list that needs a migration every time a band
-- names something new is a list that will be wrong.
alter table public.profiles
  add column if not exists plays text[] not null default '{}';

-- Where you are, and who is allowed to know.
--
-- City only. Never coordinates, never an address, never anything a phone
-- offered to supply. "Roughly which city" is the entire question this app
-- needs answered, and asking for more would be collecting something for a use
-- that does not exist.
alter table public.profiles
  add column if not exists city text;

alter table public.profiles
  add column if not exists location_visibility text not null default 'nobody'
  check (location_visibility in ('nobody', 'collaborators', 'public'));

comment on column public.profiles.location_visibility is
  'nobody: never shown. collaborators: shown to people you have been on a '
  'song with — the "we are both in Glasgow" moment, after the music rather '
  'than before it. public: findable by anybody browsing that city.';

-- Whether you appear in the open at all.
--
-- Default false, and deliberately so. Everybody currently in this app joined
-- a private room to write with people they know, and none of them agreed to
-- be listed anywhere. Opting in is a decision somebody makes; opting out
-- should never be something they discover they needed to.
alter table public.profiles
  add column if not exists discoverable boolean not null default false;

create index if not exists profiles_discoverable_idx
  on public.profiles (discoverable) where discoverable;

-- ---------------------------------------------------------------------
-- What somebody has actually played
-- ---------------------------------------------------------------------

-- Counted from shared takes only. A private draft is nobody's evidence of
-- anything, and 0057 made that a real distinction rather than a wish.
create or replace function public.parts_recorded_by(target_profile uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    jsonb_object_agg(part, n),
    '{}'::jsonb
  )
  from (
    select l.part::text as part, count(*) as n
    from public.song_layers l
    where l.recorded_by = target_profile
      and l.shared_at is not null
    group by l.part
    order by count(*) desc
    limit 12
  ) counted;
$$;

revoke all on function public.parts_recorded_by(uuid) from public, anon;
grant execute on function public.parts_recorded_by(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- The search
-- ---------------------------------------------------------------------

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
    -- The city is returned only when its owner made it public. A
    -- collaborators-only city is deliberately absent here even for somebody
    -- entitled to see it: this is the open browse surface, and a value that
    -- appears for some viewers and not others is a value that will leak the
    -- day somebody caches this response.
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
    -- The declared answer and the played one both count. Somebody who has
    -- recorded four lead vocals is a lead singer whether or not they ever
    -- filled in a field, and somebody who says they sing but has not yet is
    -- exactly who a search for singers should turn up.
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
  order by
    -- People who have actually played the thing first. A declaration is a
    -- hope; a recording is a fact, and the list should lead with facts.
    (exists (
      select 1 from public.song_layers l
      where l.recorded_by = p.id and l.shared_at is not null
        and (in_part is null or l.part::text = in_part)
    )) desc,
    p.display_name asc
  limit greatest(least(in_limit, 100), 1);
$$;

revoke all on function public.find_musicians(text, text, integer) from public, anon;
grant execute on function public.find_musicians(text, text, integer) to authenticated;

-- ---------------------------------------------------------------------
-- The city you turn out to share
-- ---------------------------------------------------------------------

-- Whether somebody you have made music with is in your city.
--
-- The nicest thing this whole feature can do, and the reason
-- 'collaborators' exists as a middle setting: two people meet over a song,
-- keep working, and then find out they are twenty minutes apart. That is a
-- far better sequence than filtering strangers by postcode, and it is safer —
-- the location is revealed after a real collaboration rather than offered to
-- anybody browsing.
--
-- Returns a city only when both people allow it and both have set one.
create or replace function public.shared_city_with(other_profile uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select p.city
  from public.profiles p
  join public.profiles me on me.id = (select auth.uid())
  where p.id = other_profile
    and p.city is not null
    and me.city is not null
    and lower(trim(p.city)) = lower(trim(me.city))
    and p.location_visibility in ('collaborators', 'public')
    -- And only if you have genuinely worked together. Sharing a room is not
    -- enough: this is about people who made something, which is the only
    -- relationship that has earned a fact about where somebody lives.
    and exists (
      select 1
      from public.song_layers mine
      join public.song_layers theirs on theirs.project_id = mine.project_id
      where mine.recorded_by = (select auth.uid())
        and theirs.recorded_by = other_profile
        and mine.shared_at is not null
        and theirs.shared_at is not null
    );
$$;

revoke all on function public.shared_city_with(uuid) from public, anon;
grant execute on function public.shared_city_with(uuid) to authenticated;
