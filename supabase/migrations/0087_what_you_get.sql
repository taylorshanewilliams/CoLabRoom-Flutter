-- What you get.
--
-- This app has to carry a large number of people who pay nothing without
-- going under, and the awkward fact is that the free hook is also the
-- expensive operation: the song sheet is the thing nobody else does, and it
-- is the only thing here that costs real money per use.
--
-- **The split is already built and nobody named it.** `AnalysisDepth` has
-- had two values since it shipped:
--
--   quick — chords, key, tempo and the words, straight from the recording.
--           No GPU. About six tenths of one cent.
--   full  — the same, after source separation: stems, structure, instruments,
--           and noticeably better chords on a dense mix. Five to eight cents.
--
-- ANALYSIS_COST.md measured them against each other across four songs: 93.3%
-- exact chord agreement, 97.2% on the root. So the free tier is not a
-- crippled version of the product. It is the product, at 93% of the accuracy,
-- for a hundredth of the cost — and that is the only honest basis for a free
-- tier that can survive a lot of people using it.
--
-- **Charge for what costs money; give away what does not.** Listening,
-- rooms, recording, takes, song sheets at `quick`, the Open Mic, asking for
-- help, everything social: all of it is storage and bandwidth, which is cheap
-- and does not scale with enthusiasm. Separation is a GPU per song.
--
-- A thousand free accounts making five sheets a month is about thirty dollars
-- on `quick` and three to four hundred on `full`. That difference is the
-- whole business model, and it happens to line up exactly with the feature
-- somebody would actually pay for.
--
-- **No payment here.** This is the entitlement model — who is on what, and
-- what that allows. Taking money is App Store and Play Store business and
-- belongs nowhere near a migration.

alter table public.profiles
  add column if not exists plan text not null default 'free'
  check (plan in ('free', 'member'));

comment on column public.profiles.plan is
  'free or member. Set by hand until there is a store to take money through. '
  'Decides whether full (separated) analysis is allowed and how many song '
  'sheets a month.';

-- How many `quick` sheets a free account gets in a month.
--
-- Generous on purpose. The point of a ceiling here is to stop one account
-- costing a fortune, not to push people into paying: at six tenths of a cent
-- a sheet, twenty of them is twelve cents, and somebody who hits twenty is
-- somebody using the app properly rather than somebody to charge.
--
-- `account_limits.monthly_analyses` still overrides it per account, which is
-- what that table has always been for.
create or replace function private.free_sheets_a_month()
returns integer
language sql
immutable
as $fn$ select 20; $fn$;

-- ---------------------------------------------------------------------
-- What this account is allowed to do
-- ---------------------------------------------------------------------

-- One answer for the client and the Edge Function to share.
--
-- The client uses it to draw the right thing and to stop somebody choosing
-- an option that will be refused; the function that spends the money uses it
-- to decide. Both asking the same question of the same place is what stops
-- them disagreeing — a paywall the client believes in and the server does
-- not is not a paywall.
create or replace function public.my_plan()
returns table (
  plan text,
  sheets_this_month bigint,
  sheets_allowed integer,
  can_separate boolean
)
language sql
stable
security definer
set search_path = public
as $fn$
  select
    p.plan,
    -- Song sheets made this month, counted as chord runs: every analysis
    -- does chords and only the full one does separation, so chords is the
    -- one row that means "a sheet was made" at either depth.
    --
    -- Cache hits are excluded. A re-run that cost nothing is not a sheet
    -- somebody should be charged a slot for, and 0028 records hits precisely
    -- so the difference is visible.
    (select count(*) from public.usage_events e
      where e.account_id = p.id
        and e.service = 'chords'
        and not e.cached
        and e.created_at >= date_trunc('month', now())),
    coalesce(
      (select l.monthly_analyses from public.account_limits l
        where l.account_id = p.id),
      case when p.plan = 'member' then null
           else private.free_sheets_a_month() end
    ),
    p.plan = 'member'
  from public.profiles p
  where p.id = (select auth.uid());
$fn$;

revoke all on function public.my_plan() from public, anon;
grant execute on function public.my_plan() to authenticated;
