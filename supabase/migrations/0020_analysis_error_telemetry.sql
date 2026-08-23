-- Error telemetry for the analysis pipeline.
--
-- Every failure in this pipeline was already being recorded — analyze()
-- writes project_audio_references.last_error, and degraded runs write
-- analysis_warning — but nothing ever read either one back. A production
-- bug therefore surfaced the only way it could: a single user hit it and
-- sent a screenshot. This table makes failures countable.
--
-- Warnings matter as much as errors here, arguably more. When the harmonic
-- mix step broke, the app did not error: it caught the failure, fell back to
-- the far less accurate on-device chord heuristic, and told the user "a less
-- accurate fallback was used". Analysis still "succeeded". A pipeline whose
-- whole value is accuracy can degrade silently, so `severity` carries both
-- and the warning rows are the ones worth watching.

create table public.analysis_errors (
  id bigint generated always as identity primary key,
  user_id uuid default auth.uid() references public.profiles(id) on delete set null,
  severity text not null default 'error' check (severity in ('error', 'warning')),
  -- Which subsystem reported it: 'analysis', 'studio_analysis', and so on.
  service text not null,
  -- Which stage inside that subsystem: 'separation', 'chords', 'lyrics'.
  stage text,
  message text not null,
  -- Filled by the trigger below, never by the client, so grouping can't
  -- drift between call sites.
  signature text not null,
  project_id uuid references public.projects(id) on delete set null,
  app_version text,
  platform text,
  created_at timestamptz not null default now()
);

create index analysis_errors_signature_idx on public.analysis_errors (signature, created_at desc);
create index analysis_errors_created_at_idx on public.analysis_errors (created_at desc);

-- Collapses one error message into a stable grouping key.
--
-- Raw messages carry per-occurrence noise — temp directories, heap
-- addresses, uuids, library version numbers — that would otherwise make
-- every instance of the same bug look unique. Version numbers get
-- normalized deliberately: an ffmpeg failure includes the whole build
-- banner, and without collapsing those digits each library version bump
-- would fork the signature.
--
-- Long messages keep both ends rather than just the front. The useful part
-- of an ffmpeg failure ("Option 'normalize' not found") is at the very end,
-- after several hundred characters of banner; truncating from the front
-- alone would group every ffmpeg error in the system together.
create or replace function public.error_signature(raw text)
returns text
language plpgsql
immutable
as $$
declare
  n text := coalesce(raw, '');
begin
  n := regexp_replace(n, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '<id>', 'g');
  n := regexp_replace(n, '0x[0-9a-fA-F]+', '<addr>', 'g');
  n := regexp_replace(n, '/tmp/[^\s'',)]*', '<tmp>', 'g');
  n := regexp_replace(n, '\m\d+(\.\d+)*\M', '<n>', 'g');
  n := regexp_replace(n, '\s+', ' ', 'g');
  n := btrim(n);
  if length(n) <= 300 then
    return n;
  end if;
  return left(n, 120) || ' … ' || right(n, 180);
end;
$$;

create or replace function public.set_error_signature()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
begin
  new.signature := public.error_signature(new.message);
  return new;
end;
$$;

create trigger analysis_errors_set_signature
before insert on public.analysis_errors
for each row execute function public.set_error_signature();

revoke all on function public.set_error_signature() from public, anon, authenticated;

alter table public.analysis_errors enable row level security;

-- Own-row only, like notifications. Reading the whole picture is a
-- maintainer activity done through the dashboard or a service-role query,
-- which bypasses RLS — no reason to expose other users' failures in-app.
create policy analysis_errors_insert_own on public.analysis_errors
for insert to authenticated with check (user_id = (select auth.uid()));

create policy analysis_errors_read_own on public.analysis_errors
for select to authenticated using (user_id = (select auth.uid()));

revoke all on table public.analysis_errors from anon;
grant select, insert on table public.analysis_errors to authenticated;

-- The triage surface: one row per distinct failure, newest first.
--
-- security_invoker so the view evaluates under the caller's RLS rather than
-- the owner's — without it this would hand every authenticated user a
-- read of everyone else's errors through the back door.
create view public.analysis_error_signatures
with (security_invoker = on) as
select
  signature,
  count(*) as occurrences,
  count(distinct user_id) as affected_users,
  min(created_at) as first_seen,
  max(created_at) as last_seen,
  array_agg(distinct severity) as severities,
  array_agg(distinct service) as services,
  -- Which pipeline stage failed. The most useful field for routing a
  -- diagnosis at the right source files, so it belongs in the summary
  -- rather than only on the raw rows.
  array_remove(array_agg(distinct stage), null) as stages,
  (array_agg(message order by created_at desc))[1] as latest_message,
  (array_agg(app_version order by created_at desc))[1] as latest_app_version
from public.analysis_errors
group by signature
order by max(created_at) desc;

grant select on public.analysis_error_signatures to authenticated;

-- One row per signature the triage agent has already looked at, so a
-- recurring bug doesn't reopen an issue every time it fires. Written only
-- by the agent with the service role; RLS is enabled with no policies at
-- all, which denies every authenticated client and leaves service-role
-- access (which bypasses RLS) as the only way in.
create table public.error_triage (
  signature text primary key,
  issue_number integer,
  issue_url text,
  confidence text,
  diagnosis text,
  occurrences_at_triage integer,
  triaged_at timestamptz not null default now()
);

alter table public.error_triage enable row level security;

revoke all on table public.error_triage from anon, authenticated;
