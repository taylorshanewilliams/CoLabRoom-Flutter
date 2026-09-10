-- Where people stop in the free chord tool.
--
-- The tool has now been live for days and the quota table holds exactly one
-- requester and three analyses — all of them ours, on the day it shipped.
-- That is worth stating plainly, because it settles an argument: the free
-- tool has not given anything away. Nobody has found it yet.
--
-- Which makes this the right moment to build the meter, before the traffic
-- rather than after it. Retrofitting a funnel onto a thing already running
-- means the first month of real usage is the month you cannot explain.
--
-- **What this deliberately does not record.** No requester, no address, no
-- hash, no session, no ordering. One integer per step per day, and that is
-- the whole schema. It cannot answer a question about a person because it
-- does not hold anything a person could be recovered from — which keeps the
-- privacy policy's account of the public tool true as written, and keeps this
-- table out of every deletion request that will ever arrive.
--
-- The cost of that choice is real and worth naming: counters cannot tell you
-- that the same visitor tried three times, so a conversion *rate* here is an
-- estimate, not a measurement. That is the right trade for a tool whose whole
-- pitch is that it stores nothing.

create table public.public_tool_funnel (
  day date not null default current_date,
  step text not null,
  count integer not null default 0,
  primary key (day, step)
);

-- The allowlist is what keeps this table bounded. Without it an anonymous
-- caller can insert a new row per made-up step name until the table is the
-- largest thing in the database.
alter table public.public_tool_funnel add constraint public_tool_funnel_step_known
  check (step in (
    'opened',        -- the page was loaded
    'chose_file',    -- a file was picked or dropped
    'analyzed_ok',   -- chords came back
    'analyzed_fail', -- something went wrong
    'limit_reached', -- five songs today: not a failure, the opposite
    'copied_text',   -- the chart was copied as text
    'shared_link',   -- a link to the chart was copied
    'opened_shared', -- somebody arrived on a link one of those made
    'clicked_onward',-- one of the cards under the result was followed
    'clicked_app'    -- somebody went from the tool towards the app itself
  ));

-- `limit_reached` is separated from `analyzed_fail` because they are opposite
-- news. A failure is the tool not working; the limit is somebody with five
-- songs to understand, which is the most interested visitor this page will
-- ever get. Averaging the two together would hide the only signal worth
-- acting on.

alter table public.public_tool_funnel enable row level security;

-- No policies. Anonymous callers reach this only through the function below,
-- which adds to a counter and cannot read one. A tool that publishes how few
-- people are using it is doing its competitor's research for them.
revoke all on table public.public_tool_funnel from anon, authenticated;

-- Add one to today's count for a step.
--
-- Reached only by the Edge Function, holding the service role, so no grant is
-- issued here at all: an anonymous caller has no path to this and cannot
-- inflate a counter without going through the same endpoint the tool uses.
-- That endpoint is still public — it has to be, the people being counted are
-- exactly the ones who have not signed up — so the numbers are soft rather
-- than tamper-proof. What the check constraint guarantees is that the worst
-- case is a wrong number in our own analytics and never an unbounded table:
-- ten rows a day, whatever anybody sends.
create or replace function public.note_public_tool_step(in_step text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.public_tool_funnel (day, step, count)
  values (current_date, in_step, 1)
  on conflict (day, step) do update
    set count = public.public_tool_funnel.count + 1;
exception
  -- An unknown step is a bug in the page, not a reason to break the page.
  -- The tool must keep working when the measurement does not.
  when check_violation then return;
end;
$$;

revoke all on function public.note_public_tool_step(text) from public, anon, authenticated;

-- The funnel, read as a funnel.
create or replace function public.public_tool_funnel_report(within_days integer default 30)
returns table (step text, total bigint, days bigint)
language sql
security definer
set search_path = public
as $$
  select f.step, sum(f.count)::bigint, count(distinct f.day)::bigint
  from public.public_tool_funnel f
  where f.day > current_date - greatest(within_days, 1)
  group by f.step
  order by sum(f.count) desc;
$$;

revoke all on function public.public_tool_funnel_report(integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Keep the totals when the requesters are dropped.
--
-- `prune_public_analysis_quota` deletes rows older than a day, which is right
-- — a per-requester row is exactly the thing that should not accumulate. But
-- it also deletes the only record that the tool was used at all, so the
-- question "how many people tried this last month" has no answer and never
-- will. Roll the counts up first, then drop the rows.

create table public.public_tool_history (
  day date primary key,
  requesters integer not null,
  analyses integer not null
);

alter table public.public_tool_history enable row level security;
revoke all on table public.public_tool_history from anon, authenticated;

create or replace function public.prune_public_analysis_quota()
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  removed bigint;
begin
  insert into public.public_tool_history (day, requesters, analyses)
  select q.day, count(*)::integer, sum(q.used)::integer
  from public.public_analysis_quota q
  where q.day < current_date - 1
  group by q.day
  on conflict (day) do update
    set requesters = excluded.requesters,
        analyses = excluded.analyses;

  delete from public.public_analysis_quota where day < current_date - 1;
  get diagnostics removed = row_count;
  return removed;
end;
$$;

revoke all on function public.prune_public_analysis_quota() from public, anon, authenticated;

-- Usage across the whole life of the tool, not just the last two days.
create or replace function public.public_tool_usage(within_days integer default 7)
returns table (day date, requesters bigint, analyses bigint)
language sql
security definer
set search_path = public
as $$
  select h.day, h.requesters::bigint, h.analyses::bigint
  from public.public_tool_history h
  where h.day > current_date - greatest(within_days, 1)
  union all
  select q.day, count(*)::bigint, sum(q.used)::bigint
  from public.public_analysis_quota q
  where q.day > current_date - greatest(within_days, 1)
  group by q.day
  order by 1 desc;
$$;

revoke all on function public.public_tool_usage(integer) from public, anon, authenticated;
