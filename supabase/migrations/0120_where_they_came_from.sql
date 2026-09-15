-- Where they came from.
--
-- The plan for the first ten thousand (15 Sep 2026) starts with fliers on
-- twenty boards, a QR code on each, and one question a week later: which
-- board worked. Until now nothing could answer it. The free chord tool
-- counts its funnel (0098) but not where a visitor came from, and an
-- account has no idea which door it walked in by.
--
-- So: a short code rides on the tool's link (colabroom.com/chords?c=orl-wp),
-- the page keeps it, every funnel step it records carries it, the link
-- onward to the app carries it, and an account made with it claims it
-- once. The code names a place -- a board, a venue, a video -- and never a
-- person. It is stored on the profile as arrived_via, is visible to the
-- account it belongs to and to nobody else, and is not used for anything
-- but counting.

-- ---------------------------------------------------------------------
-- The counts, per code.
-- ---------------------------------------------------------------------

create table public.arrivals (
  day date not null default current_date,
  code text not null check (code ~ '^[a-z0-9-]{1,32}$'),
  step text not null check (step in ('opened', 'analyzed_ok', 'clicked_app', 'signed_up')),
  count integer not null default 0,
  primary key (day, code, step)
);

comment on table public.arrivals is
  'Daily counts per arrival code: a flier, a board, a video. Written by the '
  'public tool beacon and by claim_arrival; read through arrival_report.';

-- Service role only. No policies: the counters are ours, not the visitor''s.
alter table public.arrivals enable row level security;

-- The one place an account remembers its door.
alter table public.profiles
  add column if not exists arrived_via text
    check (arrived_via is null or arrived_via ~ '^[a-z0-9-]{1,32}$');

-- ---------------------------------------------------------------------
-- The beacon learns the code.
-- ---------------------------------------------------------------------

-- Replaced with a two-argument shape rather than overloaded: PostgREST
-- cannot choose between (text) and (text, text default null) when only the
-- first is passed, and "could not choose the best candidate function" would
-- silently end the counting the day this ships.
drop function if exists public.note_public_tool_step(text);

create function public.note_public_tool_step(in_step text, in_code text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
-- The variable and the column share a name in ON CONFLICT; the column
-- is the one meant there.
#variable_conflict use_column
declare
  code text := lower(trim(coalesce(in_code, '')));
begin
  insert into public.public_tool_funnel (day, step, count)
  values (current_date, in_step, 1)
  on conflict (day, step) do update
    set count = public.public_tool_funnel.count + 1;

  -- Only the steps that answer "did this board work": arrived, got
  -- chords, went towards the app. The rest of the funnel is about the
  -- tool, not the door.
  if code <> '' and in_step in ('opened', 'analyzed_ok', 'clicked_app') then
    insert into public.arrivals (day, code, step, count)
    values (current_date, code, in_step, 1)
    on conflict (day, code, step) do update
      set count = public.arrivals.count + 1;
  end if;
exception
  -- An unknown step or a malformed code is a bug in the page, not a
  -- reason to break the page. The tool must keep working when the
  -- measurement does not.
  when check_violation then return;
end;
$$;

revoke all on function public.note_public_tool_step(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- An account claims its door, once.
-- ---------------------------------------------------------------------

-- Called by the web app after sign-in when the address carried ?from=. The
-- first claim wins: a person who signs in again from the same flier link is
-- not a second arrival. Anything but a plain code is ignored rather than
-- raised -- the address bar is not a place to be strict about.
create or replace function public.claim_arrival(code text)
returns boolean
language plpgsql
security definer set search_path = ''
as $$
-- The parameter is called code and so is the column; the column wins
-- inside the statements below.
#variable_conflict use_column
declare
  clean text := lower(trim(coalesce(code, '')));
  claimed boolean := false;
begin
  if auth.uid() is null or clean !~ '^[a-z0-9-]{1,32}$' then
    return false;
  end if;

  update public.profiles p
  set arrived_via = clean
  where p.id = auth.uid() and p.arrived_via is null
  returning true into claimed;

  if coalesce(claimed, false) then
    insert into public.arrivals (day, code, step, count)
    values (current_date, clean, 'signed_up', 1)
    on conflict (day, code, step) do update
      set count = public.arrivals.count + 1;
  end if;
  return coalesce(claimed, false);
end;
$$;

revoke all on function public.claim_arrival(text) from public, anon;
grant execute on function public.claim_arrival(text) to authenticated;

-- ---------------------------------------------------------------------
-- Which board worked.
-- ---------------------------------------------------------------------

create or replace function public.arrival_report(within_days integer default 30)
returns table (
  code text,
  opened integer,
  analyzed integer,
  clicked_app integer,
  signed_up integer,
  people integer
)
language sql
security definer
set search_path = public
stable
as $$
  with window_rows as (
    select a.code, a.step, sum(a.count)::integer as n
    from public.arrivals a
    where a.day >= current_date - within_days
    group by a.code, a.step
  ),
  codes as (
    select distinct w.code from window_rows w
    union
    select p.arrived_via from public.profiles p where p.arrived_via is not null
  )
  select
    c.code,
    coalesce((select n from window_rows w where w.code = c.code and w.step = 'opened'), 0),
    coalesce((select n from window_rows w where w.code = c.code and w.step = 'analyzed_ok'), 0),
    coalesce((select n from window_rows w where w.code = c.code and w.step = 'clicked_app'), 0),
    coalesce((select n from window_rows w where w.code = c.code and w.step = 'signed_up'), 0),
    (select count(*)::integer from public.profiles p where p.arrived_via = c.code)
  from codes c
  order by 6 desc, 2 desc, 1;
$$;

revoke all on function public.arrival_report(integer) from public, anon, authenticated;
