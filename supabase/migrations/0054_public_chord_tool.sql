-- A quota for the free tool on the website.
--
-- The site is a sales pitch for an engine nobody outside the app can try.
-- Musicians search for "chords from a song" constantly; CoLabRoom can answer
-- that better than most things they will find, and currently answers it only
-- after a signup, an install and a Room.
--
-- Opening it up costs money, which is the whole reason this table exists.
-- Every anonymous endpoint that spends money on a request is a bill somebody
-- else can run up, and the honest way to offer one is to decide in advance
-- what you are willing to lose in a day.
--
-- **What makes it affordable at all.** ANALYSIS_COST.md measured chord
-- detection with and without source separation across four songs: 93.3% exact
-- agreement, 97.2% on the root. So the public tool skips separation entirely
-- — no GPU, CPU only, about six tenths of a cent a song against the five to
-- eight cents a full analysis costs. That is the difference between a free
-- tool you can afford and one you cannot.

create table public.public_analysis_quota (
  -- A salted hash, never an address. The only question this table is allowed
  -- to answer is "has this requester had its share today", and a hash answers
  -- it exactly as well as an IP would while being useless for anything else.
  -- Rows are dropped after a day, so it cannot become a history either.
  requester text not null,
  day date not null default current_date,
  used integer not null default 0,
  primary key (requester, day)
);

alter table public.public_analysis_quota enable row level security;

-- No policies at all: the only thing that touches this is the Edge Function,
-- with the service role, which bypasses RLS. An anonymous client that could
-- read this could enumerate who had been using the tool, and one that could
-- write to it could reset its own quota.
revoke all on table public.public_analysis_quota from anon, authenticated;

-- Takes one from today's allowance, or refuses.
--
-- The count and the check are one statement on purpose. Two requests arriving
-- together would otherwise both read the old count, both find room, and both
-- proceed — which is exactly the shape somebody exploits deliberately once
-- the endpoint is worth exploiting.
create or replace function public.claim_public_analysis(
  in_requester text,
  in_daily_limit integer default 5
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  allowed boolean;
begin
  insert into public.public_analysis_quota (requester, day, used)
  values (in_requester, current_date, 1)
  on conflict (requester, day) do update
    set used = public.public_analysis_quota.used + 1
    where public.public_analysis_quota.used < in_daily_limit
  returning true into allowed;

  -- Null when the conflict clause matched no row, which happens precisely
  -- when the where-clause refused: the requester is already at the limit.
  return coalesce(allowed, false);
end;
$$;

revoke all on function public.claim_public_analysis(text, integer) from public, anon, authenticated;

-- Yesterday's quota rows answer no question anybody has.
create or replace function public.prune_public_analysis_quota()
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  removed bigint;
begin
  delete from public.public_analysis_quota where day < current_date - 1;
  get diagnostics removed = row_count;
  return removed;
end;
$$;

revoke all on function public.prune_public_analysis_quota() from public, anon, authenticated;

-- How much the tool is being used, and what it is costing.
--
-- Deliberately a count of requesters and analyses rather than anything about
-- who they were. If this ever needs to answer a question about an individual,
-- the design has gone wrong.
create or replace function public.public_tool_usage(within_days integer default 7)
returns table (day date, requesters bigint, analyses bigint)
language sql
security definer
set search_path = public
as $$
  select q.day, count(*)::bigint, sum(q.used)::bigint
  from public.public_analysis_quota q
  where q.day > current_date - greatest(within_days, 1)
  group by q.day
  order by q.day desc;
$$;

revoke all on function public.public_tool_usage(integer) from public, anon, authenticated;
