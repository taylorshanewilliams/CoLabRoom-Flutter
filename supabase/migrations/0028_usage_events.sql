-- What an analysis actually consumes.
--
-- Every analysis spends real money across four vendors and nothing has ever
-- recorded a byte of it. That makes three questions unanswerable: what does a
-- user cost, what should a plan cost, and is a given user profitable. You
-- cannot price a product whose unit cost you can't state, and the failure
-- mode is quiet — you find out you're losing money per subscriber months
-- after acquiring them.
--
-- One row per billable operation rather than one row per analysis. An
-- analysis is not a single purchase: it's a GPU job, a chord request, maybe a
-- transcription, and a pile of stored bytes that go on costing every month
-- after. Rolling those into one row would throw away exactly the detail that
-- says *which part* is expensive.
--
-- Deliberately no prices here. Rates change, they differ per vendor and per
-- region, and a price baked into a historical row is a lie the moment it
-- moves. This table records consumption — seconds, milliseconds, bytes — and
-- the rate card is applied when you ask the question.

create table public.usage_events (
  id uuid primary key default gen_random_uuid(),

  -- Nullable and ON DELETE SET NULL throughout: a deleted account must not
  -- erase the record that its usage happened. The cost was still incurred,
  -- and a month's totals shouldn't change retroactively because somebody
  -- left.
  account_id uuid references public.profiles(id) on delete set null,
  project_id uuid references public.projects(id) on delete set null,
  draft_id uuid references public.studio_drafts(id) on delete set null,

  -- Which vendor call this was. 'storage' is the odd one out and the
  -- important one: it is not paid once, it is paid every month until the
  -- bytes are deleted.
  service text not null check (
    service in ('separation', 'chords', 'transcription', 'storage')
  ),

  -- A cache hit consumed nothing from the vendor. Recording the hit rather
  -- than skipping the row is what makes the cache's value measurable — the
  -- money it saves is invisible if the saved runs leave no trace.
  cached boolean not null default false,

  -- What the vendor bills on. OpenAI charges per minute of audio; RunPod and
  -- Cloud Run charge for execution time; storage charges for bytes held.
  -- Whichever is null is simply not how that service is priced.
  audio_ms integer check (audio_ms is null or audio_ms >= 0),
  compute_ms integer check (compute_ms is null or compute_ms >= 0),
  bytes bigint check (bytes is null or bytes >= 0),

  -- Ties the events of one analysis together, and to the cache entry that
  -- may serve it next time.
  audio_sha256 text,

  created_at timestamptz not null default now()
);

create index usage_events_account_created_idx
  on public.usage_events (account_id, created_at desc);
create index usage_events_created_idx on public.usage_events (created_at desc);

-- Written by the Edge Functions with the service role, read by whoever is
-- asking what the month cost. No policies: a client that could write here
-- could under-report its own usage, which is the one thing this table exists
-- to prevent.
alter table public.usage_events enable row level security;

-- The question this table exists to answer, in the shape you'd ask it.
-- Bytes are summed as a *delta* per month — storage rows record what an
-- analysis added, so the running total is a cumulative sum over time rather
-- than anything a single month contains.
create or replace view public.usage_by_account_month as
select
  account_id,
  date_trunc('month', created_at) as month,
  count(*) filter (where service = 'separation' and not cached) as separations_run,
  count(*) filter (where service = 'separation' and cached) as separations_from_cache,
  count(*) filter (where service = 'transcription' and not cached) as transcriptions_run,
  count(*) filter (where service = 'transcription' and cached) as transcriptions_from_cache,
  coalesce(sum(compute_ms) filter (where service = 'separation' and not cached), 0) as gpu_ms,
  coalesce(sum(compute_ms) filter (where service = 'chords'), 0) as chord_service_ms,
  coalesce(sum(audio_ms) filter (where service = 'transcription' and not cached), 0) as whisper_audio_ms,
  coalesce(sum(bytes) filter (where service = 'storage'), 0) as bytes_added
from public.usage_events
group by account_id, date_trunc('month', created_at);
