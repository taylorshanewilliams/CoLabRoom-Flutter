-- The Studio: pre-project song analysis drafts. A draft has no room/project yet,
-- so it can't hang off project_audio_references/chord_cues (both FK'd down to an
-- existing project -> room) or the files table (project_id not null) — this is a
-- parallel, account-scoped schema instead. A draft is promoted into a real
-- project_audio_references/chord_cues row once the user creates a project from it.

create table public.studio_drafts (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  display_name text not null,
  storage_path text not null,
  mime_type text,
  byte_size bigint check (byte_size is null or byte_size >= 0),
  analysis_state text not null default 'uploaded'
    check (analysis_state in ('uploaded', 'queued', 'processing', 'ready', 'failed')),
  duration_ms integer check (duration_ms is null or duration_ms >= 0),
  bpm double precision check (bpm is null or bpm > 0),
  musical_key text,
  analyzer_version text,
  chord_confidence double precision
    check (chord_confidence is null or chord_confidence between 0 and 1),
  transcript_text text,
  transcript_words jsonb not null default '[]'::jsonb,
  -- [{startMs,endMs,label,repeatsSectionLabel?}, ...] -- boundaries only, never
  -- asserted as ground-truth Verse/Chorus/Bridge; the musician relabels themselves.
  structure_sections jsonb not null default '[]'::jsonb
    check (jsonb_typeof(structure_sections) = 'array'),
  -- {"vocals":{"present":bool,"confidence":float}, "guitar":..., "bass":..., "drums":...}
  instruments jsonb not null default '{}'::jsonb
    check (jsonb_typeof(instruments) = 'object'),
  analysis_warning text,
  last_error text,
  promoted_project_id uuid references public.projects(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.studio_chord_cues (
  id bigint generated always as identity primary key,
  draft_id uuid not null references public.studio_drafts(id) on delete cascade,
  start_ms integer not null check (start_ms >= 0),
  end_ms integer not null check (end_ms >= start_ms),
  chord text not null check (char_length(trim(chord)) between 1 and 24),
  confidence double precision not null default 0
    check (confidence between 0 and 1),
  beat_index integer check (beat_index is null or beat_index >= 0),
  source text not null default 'automatic'
    check (source in ('automatic', 'reviewed', 'manual')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index studio_drafts_account_idx
  on public.studio_drafts(account_id, created_at desc);
create index studio_chord_cues_draft_start_idx
  on public.studio_chord_cues(draft_id, start_ms);

create trigger studio_drafts_set_updated_at
before update on public.studio_drafts
for each row execute function public.set_updated_at();

create trigger studio_chord_cues_set_updated_at
before update on public.studio_chord_cues
for each row execute function public.set_updated_at();

alter table public.studio_drafts enable row level security;
alter table public.studio_chord_cues enable row level security;

-- Account-owner-only — a draft is a personal scratch space until it's promoted
-- into a real project, at which point normal room-membership policies take over
-- on project_audio_references/chord_cues instead.
create policy studio_drafts_owner_all on public.studio_drafts
for all to authenticated
using (account_id = (select auth.uid()))
with check (account_id = (select auth.uid()));

create policy studio_chord_cues_owner_all on public.studio_chord_cues
for all to authenticated
using (
  exists (
    select 1 from public.studio_drafts d
    where d.id = draft_id and d.account_id = (select auth.uid())
  )
)
with check (
  exists (
    select 1 from public.studio_drafts d
    where d.id = draft_id and d.account_id = (select auth.uid())
  )
);

revoke all on table public.studio_drafts, public.studio_chord_cues from anon;

grant select, insert, update, delete on table public.studio_drafts to authenticated;
grant select, insert, update, delete on table public.studio_chord_cues to authenticated;
grant usage, select on sequence public.studio_chord_cues_id_seq to authenticated;

-- Object names begin with the caller's own account UUID: <account-id>/<draft-id>/<filename>.
-- No room-membership check (unlike room-files) since there's no room yet.
insert into storage.buckets (id, name, public)
values ('studio-drafts', 'studio-drafts', false)
on conflict (id) do nothing;

create policy studio_drafts_files_owner on storage.objects
for all to authenticated using (
  bucket_id = 'studio-drafts'
  and ((storage.foldername(name))[1])::uuid = (select auth.uid())
) with check (
  bucket_id = 'studio-drafts'
  and ((storage.foldername(name))[1])::uuid = (select auth.uid())
);

-- Existing per-project analysis gains the same new fields the Studio engine
-- produces (bpm already existed but had no writer; structure/instruments are new)
-- so "Explain My Song" -> "Put that into my song" has somewhere to write, and the
-- existing Analyze Song screen can start showing this data too.
alter table public.project_audio_references
  add column if not exists structure_sections jsonb not null default '[]'::jsonb
    check (jsonb_typeof(structure_sections) = 'array'),
  add column if not exists instruments jsonb not null default '{}'::jsonb
    check (jsonb_typeof(instruments) = 'object');

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'studio_drafts'
  ) then
    alter publication supabase_realtime add table public.studio_drafts;
  end if;
end;
$$;
