-- Which screen somebody was on when it broke.
--
-- `analysis_errors` records what failed and never recorded where. That was
-- fine while it only carried pipeline failures, which happen on one screen —
-- 0040 widened it to every uncaught error in the app and the column never
-- followed. So a report says "That did not go through" and leaves the reader
-- to guess between fifty-seven screens.
--
-- The evidence that this matters is the whole error table: 36 rows, and the
-- triage agent's diagnoses repeatedly say the ancestor chain was truncated
-- "exactly where it would have told us the screen". Issue #19 says it in as
-- many words — "I cannot tell you which widget it is from this report".
-- The screen is the single most useful thing a report can carry and it was
-- the one thing missing.
--
-- Nullable, because errors arrive from places that have no route: a failed
-- sign-in before the app has drawn anything, a background upload, the
-- analysis pipeline reporting through the same table.

alter table public.analysis_errors
  add column if not exists route text;

-- Reports somebody sent on purpose, grouped by where they were.
--
-- `feedback` has had a route column since 0001 and every row that could have
-- arrived in it would have said 'account', because the one place the app
-- offers to take a report hardcodes that string. There are no rows at all —
-- nobody has ever used it in three weeks of beta, while the band hit at least
-- three real problems and told Taylor about every one of them in person.
--
-- A form that only exists on one screen is a form people have to go and find
-- after the moment has passed, which is the moment they decide it is easier
-- to send a text message instead.
comment on column public.feedback.route is
  'Where the person was when they hit the problem — not where they were when '
  'they filled in the form.';

comment on column public.feedback.category is
  'What kind of report: bug, idea, or general. Chosen by the person, not '
  'assumed by the screen they happened to be on.';

-- What was going wrong for this person just before they wrote to you.
--
-- The single most useful thing to have beside a bug report, and the thing
-- that turns "it didn't work" into something answerable. Reads only this
-- person's own rows and only the last hour, because a report is about what
-- just happened.
create or replace function public.my_recent_errors(within_minutes integer default 60)
returns table (
  created_at timestamptz,
  service text,
  stage text,
  route text,
  message text
)
language sql
security invoker
set search_path = public
as $$
  select e.created_at, e.service, e.stage, e.route, left(e.message, 400)
  from public.analysis_errors e
  where e.user_id = (select auth.uid())
    and e.created_at > now() - make_interval(mins => greatest(within_minutes, 1))
  order by e.created_at desc
  limit 20;
$$;

revoke all on function public.my_recent_errors(integer) from public, anon;
grant execute on function public.my_recent_errors(integer) to authenticated;
