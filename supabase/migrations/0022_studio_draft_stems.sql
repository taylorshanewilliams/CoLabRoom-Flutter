-- Separated stems for Studio ideas.
--
-- Projects have kept their stems since migration 0019, but Studio drafts
-- never did: the Edge Function only persisted them when a projectId was
-- present, and a draft has no project by definition. So the one place the
-- stems would help most — a raw idea you're trying to remember and pull
-- apart — was the one place they were thrown away.
--
-- Separate table rather than reusing project_stems because ownership is
-- different: a draft belongs to an account, not to a room's membership.

create table public.studio_draft_stems (
  draft_id uuid not null references public.studio_drafts(id) on delete cascade,
  stem text not null check (stem in ('vocals', 'drums', 'bass', 'guitar', 'piano', 'other')),
  storage_path text not null,
  byte_size integer check (byte_size is null or byte_size >= 0),
  created_at timestamptz not null default now(),
  primary key (draft_id, stem)
);

create index studio_draft_stems_draft_id_idx on public.studio_draft_stems (draft_id);

alter table public.studio_draft_stems enable row level security;

-- Own drafts only, matching studio_drafts itself. Written exclusively by the
-- analyze-chords Edge Function with the service role, so there is no insert
-- policy for authenticated — same trust model as project_stems.
create policy studio_draft_stems_read_own on public.studio_draft_stems
for select to authenticated using (
  exists (
    select 1 from public.studio_drafts d
    where d.id = draft_id and d.account_id = (select auth.uid())
  )
);

create policy studio_draft_stems_delete_own on public.studio_draft_stems
for delete to authenticated using (
  exists (
    select 1 from public.studio_drafts d
    where d.id = draft_id and d.account_id = (select auth.uid())
  )
);

revoke all on table public.studio_draft_stems from anon;
grant select, delete on table public.studio_draft_stems to authenticated;
