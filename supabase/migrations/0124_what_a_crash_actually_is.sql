-- What a crash actually is.
--
-- `crash_free_rate` (0053) counts a session as bad when any error was
-- reported during it, and calls the result crash-free. Those are two
-- different things, and the gap between them is why the daily workflow has
-- failed every morning since 10 September: a push token that would not
-- register, an Open Mic that did not load, a three-pixel overflow -- all
-- real, none of them a crash, and all of them holding a number named after
-- crashes below its floor for good.
--
-- An alarm that can never stop ringing is an alarm nobody hears. So this
-- separates the two questions without hiding either:
--
--   error-free   no error of any kind was reported. The strict number, and
--                the one to drive down over months.
--   crash-free   the app actually worked. A session counts against this
--                only when the library never loaded (`load`) or when
--                something escaped every catch (`uncaught`, `async`) --
--                the two shapes that mean somebody could not use the app.
--
-- Deliberately not counted as crashes: Flutter's own layout complaints
-- (`rendering library` and friends). A three-pixel overflow is a bug worth
-- fixing and it is not a person being locked out, and pretending otherwise
-- is how the first number stopped meaning anything.

create or replace function public.app_health(within_days integer default 7)
returns table (
  app_version text,
  sessions bigint,
  sessions_with_an_error bigint,
  sessions_that_could_not_work bigint,
  error_free_percent numeric,
  crash_free_percent numeric
)
language sql
security definer
set search_path = public
stable
as $$
  with recent as (
    select s.id, s.app_version
    from public.app_sessions s
    where s.started_at > now() - make_interval(days => greatest(within_days, 1))
  ),
  errored as (
    select distinct e.session_id
    from public.analysis_errors e
    where e.session_id is not null
      and e.severity = 'error'
      and e.created_at > now() - make_interval(days => greatest(within_days, 1))
  ),
  broke as (
    select distinct e.session_id
    from public.analysis_errors e
    where e.session_id is not null
      and e.severity = 'error'
      and e.stage in ('load', 'uncaught', 'async')
      and e.created_at > now() - make_interval(days => greatest(within_days, 1))
  )
  select
    r.app_version,
    count(*)::bigint,
    count(*) filter (where r.id in (select session_id from errored))::bigint,
    count(*) filter (where r.id in (select session_id from broke))::bigint,
    round(100.0 * (count(*) - count(*) filter (where r.id in (select session_id from errored)))
          / greatest(count(*), 1), 2),
    round(100.0 * (count(*) - count(*) filter (where r.id in (select session_id from broke)))
          / greatest(count(*), 1), 2)
  from recent r
  group by r.app_version
  order by count(*) desc;
$$;

revoke all on function public.app_health(integer) from public, anon, authenticated;
