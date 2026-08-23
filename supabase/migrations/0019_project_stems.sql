-- Separated instrument stems, kept instead of discarded.
--
-- htdemucs already produced these on every analysis job and threw them away
-- once the harmonic mix was built (see inference/separation_service/handler.py).
-- Two things change with this migration:
--
--   1. The worker now runs htdemucs_6s, which splits guitar and piano into
--      their own stems rather than lumping them into "other" — per-instrument
--      playback and, later, per-instrument transcription both need that split.
--   2. Each stem is uploaded to Storage as MP3 and recorded here, so the app
--      can play them back and so the *vocal* stem can be handed to Whisper
--      instead of transcribing the raw, unseparated mix.
--
-- Stems are written exclusively by the analyze-chords Edge Function (via
-- signed upload URLs it mints with the service role), so there is no insert
-- policy for `authenticated` — same trust model as notifications.

create table public.project_stems (
  project_id uuid not null references public.projects(id) on delete cascade,
  stem text not null check (stem in ('vocals', 'drums', 'bass', 'guitar', 'piano', 'other')),
  storage_path text not null,
  byte_size integer check (byte_size is null or byte_size >= 0),
  created_at timestamptz not null default now(),
  primary key (project_id, stem)
);

create index project_stems_project_id_idx on public.project_stems (project_id);

alter table public.project_stems enable row level security;

-- Same read shape as files_read_members / project_audio_references_read_room:
-- a project-only member sees their project's stems, a room member sees every
-- project's stems in that room. Both checks go through the existing security
-- definer helpers rather than plain subqueries, per the RLS recursion pattern
-- this schema already had to fix once in migration 0016.
create policy project_stems_read_members on public.project_stems
for select to authenticated using (
  private.is_project_member(project_id)
  or exists (
    select 1 from public.projects p
    where p.id = project_id and private.is_room_member(p.room_id)
  )
);

-- Editors can delete so removing a reference recording cleans its stems up
-- (song_analysis_service.removeReference runs as the user, not the service
-- role). Re-analysis overwrites through the Edge Function instead.
create policy project_stems_delete_editors on public.project_stems
for delete to authenticated using (
  private.project_role_for(project_id) in ('owner', 'editor')
  or exists (
    select 1 from public.projects p
    where p.id = project_id and private.room_role_for(p.room_id) in ('owner', 'editor')
  )
);

revoke all on table public.project_stems from anon;
grant select, delete on table public.project_stems to authenticated;
