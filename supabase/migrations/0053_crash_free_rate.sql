-- A number that says whether this week is better than last.
--
-- The app can now record what failed, where, and who it happened to. What it
-- cannot do is answer "is it getting better", because every count is an
-- absolute: 36 errors means nothing without knowing whether that was over ten
-- sessions or ten thousand. A bad release and a busy week look identical.
--
-- Crash-free rate is the standard answer and it needs one thing this schema
-- does not have: a session. Not a login — a single run of the app, from
-- launch to whenever it stops. Sessions are the denominator; without one there
-- is no rate, only a tally.

create table public.app_sessions (
  -- Generated on the phone at launch rather than here, because the first
  -- thing a session must be able to do is own a crash that happens before any
  -- request succeeds. A server-assigned id would be null for exactly the
  -- sessions worth counting.
  id text primary key,

  user_id uuid default auth.uid() references public.profiles(id) on delete set null,
  app_version text,
  platform text,
  started_at timestamptz not null default now()
);

create index app_sessions_started_idx on public.app_sessions (started_at desc);

alter table public.app_sessions enable row level security;

-- Write your own, read your own. Nobody needs to see anybody else's launches,
-- and the rate below is computed with the service role.
create policy app_sessions_write_own on public.app_sessions
for insert to authenticated with check (user_id = (select auth.uid()));

create policy app_sessions_read_own on public.app_sessions
for select to authenticated using (user_id = (select auth.uid()));

-- Which run of the app a failure belongs to.
--
-- A join on time would be guesswork: sessions overlap, a phone can be running
-- two builds in a day, and a background upload finishing an hour later is not
-- part of the session that started it. The id is carried on the report.
alter table public.analysis_errors
  add column if not exists session_id text;

create index if not exists analysis_errors_session_idx
  on public.analysis_errors (session_id);

-- The rate itself.
--
-- Deliberately counts only `severity = 'error'`. The warnings added alongside
-- this are failures the app *coped with* — a cleanup that did not run, a
-- stream that kept stale content — and folding them in would make the number
-- move for reasons that are not crashes, which is exactly how a metric stops
-- being watched.
create or replace function public.crash_free_rate(within_days integer default 7)
returns table (
  sessions bigint,
  sessions_with_an_error bigint,
  crash_free_percent numeric,
  app_version text
)
language sql
security definer
set search_path = public
as $$
  with recent as (
    select s.id, s.app_version
    from public.app_sessions s
    where s.started_at > now() - make_interval(days => greatest(within_days, 1))
  ),
  bad as (
    select distinct e.session_id
    from public.analysis_errors e
    where e.session_id is not null
      and e.severity = 'error'
      and e.created_at > now() - make_interval(days => greatest(within_days, 1))
  )
  select
    count(*)::bigint as sessions,
    count(*) filter (where r.id in (select session_id from bad))::bigint
      as sessions_with_an_error,
    round(
      100.0 * (count(*) - count(*) filter (where r.id in (select session_id from bad)))
      / greatest(count(*), 1),
      2
    ) as crash_free_percent,
    r.app_version
  from recent r
  group by r.app_version
  order by sessions desc;
$$;

revoke all on function public.crash_free_rate(integer) from public, anon, authenticated;

-- Sessions are the one table here that grows with use rather than with work.
--
-- One row per launch per person: nothing at four users, and at a million it is
-- the largest table in the database within a month. Ninety days is far more
-- history than "is this release worse than the last one" needs, and keeping
-- more would be paying to store the fact that somebody opened an app in 2026.
create or replace function public.prune_app_sessions(keep_days integer default 90)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  removed bigint;
begin
  delete from public.app_sessions
  where started_at < now() - make_interval(days => greatest(keep_days, 7));
  get diagnostics removed = row_count;
  return removed;
end;
$$;

revoke all on function public.prune_app_sessions(integer) from public, anon, authenticated;
