-- A ceiling on how much one account can spend of yours in a month.
--
-- Not a pricing tier. There is no pricing yet, and this is not a way to
-- smuggle one in early — it is the safety valve that should have existed from
-- the first GPU job. Right now nothing stops one enthusiastic person running
-- three hundred analyses, and the bill for that arrives before any signal
-- that it is happening does.
--
-- Set deliberately high, so a working musician never meets it and a runaway
-- does. When real pricing exists these numbers become the plans; until then
-- the number's job is to be a limit rather than a product decision.
--
-- Only separations that actually ran count. A cache hit costs nothing, so
-- charging quota for one would penalise exactly the behaviour that saves the
-- money — analysing a song your bandmate already analysed should be free in
-- every sense.

create table public.account_limits (
  account_id uuid primary key references public.profiles(id) on delete cascade,

  -- Null means "use the default in the Edge Function". A row exists here only
  -- for accounts that need something other than the default — a band doing a
  -- record, somebody who hit the ceiling for a good reason, or a tester who
  -- should have none at all.
  monthly_analyses integer check (monthly_analyses is null or monthly_analyses >= 0),

  -- Why this account is different. A limit with no explanation becomes a
  -- mystery the first time somebody asks about it.
  note text,

  updated_at timestamptz not null default now()
);

-- Read and written by the Edge Function with the service role. No policies:
-- an account that could edit its own ceiling does not have a ceiling.
alter table public.account_limits enable row level security;

