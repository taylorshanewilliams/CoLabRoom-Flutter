-- What to watch, weekly.
--
-- The plan for the first ten thousand ends with five numbers to read every
-- week, and reading them meant writing five queries by hand each time --
-- which means not reading them. One function, one workflow, one email.
--
-- The list is the plan's, in its order:
--
--   tool tries, and how many came from a code
--   signups, and how many of those came from a code
--   people who came back the next day
--   rooms with two or more in them, and songs with more than one author
--   first-time pairings: two people who had never been on a song together
--
-- and the last is the north star. Deliberately absent: plays, likes, and
-- anything ranked. The moment those are counted they get optimised for, and
-- the app stops being the one it set out to be.
--
-- Nothing here returns a number about a person. The collaboration ledger
-- (0093) says no function may return a count, a rank or a score about
-- somebody; a count of how many pairs formed is about the product, and
-- every row below is a total over everybody or nobody at all.

create or replace function public.growth_report(within_days integer default 7)
returns table (metric text, value bigint, note text)
language sql
security definer
set search_path = public
stable
as $$
  with window_start as (
    select now() - make_interval(days => greatest(within_days, 1)) as at
  ),
  -- Two people who have been on a song together, as an unordered pair and
  -- the first time it ever happened.
  pairs as (
    select least(e.by_user, e.with_user) as a,
           greatest(e.by_user, e.with_user) as b,
           min(e.at) as first_at
    from private.collaboration_events e
    where e.kind = 'delivered' and e.with_user is not null
    group by 1, 2
  ),
  -- Somebody who opened the app on two different days inside the window.
  returners as (
    select s.user_id
    from public.app_sessions s, window_start w
    where s.user_id is not null and s.started_at >= w.at
    group by s.user_id
    having count(distinct s.started_at::date) > 1
  ),
  -- A song more than one person has written on or played on.
  shared_songs as (
    select p.id
    from public.projects p
    where (
      select count(distinct who) from (
        select c.author_id as who from public.contributions c where c.project_id = p.id
        union
        select l.recorded_by from public.song_layers l where l.project_id = p.id
      ) hands
    ) > 1
  )
  select 'tool tries'::text, coalesce(sum(f.count), 0)::bigint,
         'the free chord tool was opened'::text
  from public.public_tool_funnel f, window_start w
  where f.step = 'opened' and f.day >= w.at::date
  union all
  select 'tool answers', coalesce(sum(f.count), 0)::bigint,
         'chords actually came back'
  from public.public_tool_funnel f, window_start w
  where f.step = 'analyzed_ok' and f.day >= w.at::date
  union all
  select 'tool tries from a code', coalesce(sum(a.count), 0)::bigint,
         'a flier, a board, a video — see arrival_report for which'
  from public.arrivals a, window_start w
  where a.step = 'opened' and a.day >= w.at::date
  union all
  select 'signups', count(*)::bigint, 'new accounts'
  from public.profiles p, window_start w
  where p.created_at >= w.at
  union all
  select 'signups from a code', count(*)::bigint,
         'arrived by a flier, a link or an invitation'
  from public.profiles p, window_start w
  where p.created_at >= w.at and p.arrived_via is not null
  union all
  select 'came back another day', count(*)::bigint,
         'opened the app on two different days this week'
  from returners
  union all
  select 'rooms with a band in them', count(*)::bigint,
         'two or more members, all time'
  from (
    select rm.room_id from public.room_members rm
    group by rm.room_id having count(*) > 1
  ) bands
  union all
  select 'songs more than one person touched', count(*)::bigint,
         'written on or played on by two or more, all time'
  from shared_songs
  union all
  select 'first-time pairings', count(*)::bigint,
         'two people who had never been on a song together — the north star'
  from pairs, window_start w
  where pairs.first_at >= w.at
  union all
  select 'pairings, all time', count(*)::bigint,
         'every pair that has ever delivered something to each other'
  from pairs;
$$;

revoke all on function public.growth_report(integer) from public, anon, authenticated;
