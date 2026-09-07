-- A crowd to test with.
--
-- Almost everything built this week is invisible at four users. A feed that
-- orders itself towards people like you, a wildcard every fourth card, taste
-- matching, a list of musicians that rotates daily — none of it can be seen,
-- let alone judged, against 28 songs and three other people. Neither can the
-- things that only break at size: signing twelve URLs at once, a list that
-- has to scroll, a query with no index behind it.
--
-- So: seeded accounts, in bulk, that can be told apart from real ones and
-- removed completely.
--
-- **Labelled, not disguised.** This flag is read by the app and drawn on the
-- profile and on every card. Seeded accounts that looked real would deceive
-- the people already using this — and an app whose reviewers find unlabelled
-- invented users has a different and worse problem. The point is to test the
-- machinery at scale, and a visible "demo" chip costs none of that.
--
-- **And it must be removable in one call.** Seed data that outlives its
-- purpose becomes the data: it lands in every count, every screenshot and
-- every judgement about how the app is doing. `purge_demo()` is written
-- first, deliberately, and tested by the smoke file before anything is
-- allowed to depend on it.

alter table public.profiles
  add column if not exists is_demo boolean not null default false;

comment on column public.profiles.is_demo is
  'Seeded for testing, never a real person. Drawn as a "demo" chip in the '
  'app, and excluded from any count of how the app is actually doing.';

-- Partial, because the interesting set is always the small one.
create index if not exists profiles_demo_idx
  on public.profiles (id) where is_demo;

-- ---------------------------------------------------------------------
-- Taking it all away again
-- ---------------------------------------------------------------------

-- **Explicit deletes rather than a trust in cascades.**
--
-- 0065 had to make three foreign keys nullable so that deleting an account
-- would work at all — `song_layers.recorded_by` among them, because somebody
-- who recorded on another person's song used to make deletion fail outright.
-- Those loosened keys are exactly why cascading from `auth.users` cannot be
-- relied on here: a nulled `recorded_by` leaves a take standing, on a song in
-- a room whose owner is gone.
--
-- So this walks down from the demo accounts and removes what they made, in
-- the order the keys allow, and only then the accounts themselves.
--
-- Returns what it deleted, because a purge that reports nothing is one nobody
-- can check ran.
create or replace function public.purge_demo()
returns table (what text, removed bigint)
language plpgsql
security definer
set search_path = public
as $fn$
declare
  people uuid[];
  rooms_hit uuid[];
  projects_hit uuid[];
  n bigint;
begin
  select coalesce(array_agg(id), '{}'::uuid[]) into people
  from public.profiles where is_demo;

  if array_length(people, 1) is null then
    return query select 'nothing was seeded'::text, 0::bigint;
    return;
  end if;

  select coalesce(array_agg(id), '{}'::uuid[]) into rooms_hit
  from public.rooms where account_id = any(people);

  select coalesce(array_agg(id), '{}'::uuid[]) into projects_hit
  from public.projects where room_id = any(rooms_hit);

  -- Storage rows first: once a project is gone there is nothing left to say
  -- which objects belonged to it, and the bytes would be unreferenced
  -- forever. The paths are '{room}/{project}/...', so the room prefix finds
  -- every one of them.
  delete from storage.objects o
  where o.bucket_id = 'room-files'
    and exists (
      select 1 from unnest(rooms_hit) r
      where o.name like r::text || '/%'
    );
  get diagnostics n = row_count;
  what := 'files'; removed := n; return next;

  delete from storage.objects o
  where o.bucket_id = 'avatars'
    and exists (
      select 1 from unnest(people) p where o.name like p::text || '/%'
    );
  get diagnostics n = row_count;
  what := 'avatars'; removed := n; return next;

  delete from public.song_layers where project_id = any(projects_hit);
  get diagnostics n = row_count;
  what := 'takes'; removed := n; return next;

  delete from public.project_asks where project_id = any(projects_hit);
  get diagnostics n = row_count;
  what := 'asks'; removed := n; return next;

  delete from public.projects where id = any(projects_hit);
  get diagnostics n = row_count;
  what := 'songs'; removed := n; return next;

  delete from public.rooms where id = any(rooms_hit);
  get diagnostics n = row_count;
  what := 'rooms'; removed := n; return next;

  -- Anything a demo account did inside somebody else's room. Rare, and the
  -- reason this is not simply "delete their rooms": a seeded account that
  -- accepted an invitation is a member of a real room.
  delete from public.room_members where user_id = any(people);
  get diagnostics n = row_count;
  what := 'memberships'; removed := n; return next;

  delete from public.project_members where user_id = any(people);
  get diagnostics n = row_count;
  what := 'song memberships'; removed := n; return next;

  -- And the accounts. profiles goes with them through auth.users' cascade,
  -- which is the one cascade in this chain that was never loosened.
  delete from auth.users where id = any(people);
  get diagnostics n = row_count;
  what := 'accounts'; removed := n; return next;

  return;
end;
$fn$;

-- Service key only, like every other operational function here. A purge
-- callable from a phone is a delete button on somebody else's data.
revoke all on function public.purge_demo() from public, anon, authenticated;

comment on function public.purge_demo() is
  'Removes every seeded demo account and everything it made, in the order '
  'the foreign keys allow. Returns a count per kind. Service key only.';


-- ---------------------------------------------------------------------
-- Saying so, everywhere somebody is drawn
-- ---------------------------------------------------------------------

-- The flag has to reach the app or the label is a promise nothing keeps.
-- Both surfaces that draw a person now carry it.
--
-- Public, unlike `discoverable` and `location_visibility`, which are answered
-- as null for everybody but you. Those are settings somebody made about
-- themselves and are nobody else's business; this is a statement about
-- whether the account is a person at all, and hiding it would defeat the
-- entire point of having it.

drop function if exists public.musician_profile(uuid);

create function public.musician_profile(target uuid)
returns table (
  id uuid,
  display_name text,
  avatar_path text,
  city text,
  plays text[],
  sounds_like text[],
  parts_recorded jsonb,
  songs_played_on bigint,
  people_worked_with bigint,
  discoverable boolean,
  location_visibility text,
  is_demo boolean
)
language sql
stable
security definer
set search_path = public
as $fn$
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
    p.is_demo
  from public.profiles p
  where p.id = target
    and (
      p.id = (select auth.uid())
      or p.discoverable
      or exists (
        select 1 from public.room_members mine
        join public.room_members theirs on theirs.room_id = mine.room_id
        where mine.user_id = (select auth.uid()) and theirs.user_id = p.id
      )
    )
    and not private.blocked_between((select auth.uid()), p.id);
$fn$;

revoke all on function public.musician_profile(uuid) from public, anon;
grant execute on function public.musician_profile(uuid) to authenticated;

drop function if exists public.find_musicians(text, text, integer, text);

create function public.find_musicians(
  in_part text default null,
  in_city text default null,
  in_limit integer default 30,
  in_sounds_like text default null
)
returns table (
  id uuid,
  display_name text,
  avatar_path text,
  city text,
  plays text[],
  sounds_like text[],
  parts_recorded jsonb,
  songs_played_on bigint,
  people_worked_with bigint,
  shared_sounds text[],
  is_demo boolean
)
language sql
stable
security definer
set search_path = public
as $fn$
  with me as (
    select p.sounds_like from public.profiles p where p.id = (select auth.uid())
  )
  select
    p.id,
    p.display_name,
    p.avatar_path,
    case when p.location_visibility = 'public' then p.city else null end,
    p.plays,
    p.sounds_like,
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
    coalesce(shared.tags, '{}'::text[]),
    p.is_demo
  from public.profiles p
  cross join lateral (
    select array_agg(t) as tags
    from unnest(p.sounds_like) as t
    where t = any(coalesce((select m.sounds_like from me m), '{}'::text[]))
  ) shared
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
    and (
      in_sounds_like is null
      or lower(trim(in_sounds_like)) = any(p.sounds_like)
    )
  order by
    case when coalesce(array_length(shared.tags, 1), 0) > 0 then 0 else 1 end,
    md5(p.id::text || current_date::text)
  limit greatest(least(in_limit, 100), 1);
$fn$;

revoke all on function public.find_musicians(text, text, integer, text)
  from public, anon;
grant execute on function public.find_musicians(text, text, integer, text)
  to authenticated;
