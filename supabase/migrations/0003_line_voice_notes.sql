-- A voice note belongs to one lyric line and must stay inside that line's project.
alter table public.contributions
  add constraint contributions_id_project_id_unique unique (id, project_id);

alter table public.files
  add column contribution_id uuid;

alter table public.files
  add constraint files_contribution_project_fkey
  foreign key (contribution_id, project_id)
  references public.contributions (id, project_id)
  on delete cascade;

create index files_contribution_project_idx
  on public.files (contribution_id, project_id);

create unique index files_one_voice_note_per_contribution
  on public.files (contribution_id)
  where contribution_id is not null and deleted_at is null;

-- The client listens for attached voice notes so a collaborator's play button
-- appears without reopening the project.
do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'files'
  ) then
    alter publication supabase_realtime add table public.files;
  end if;
end;
$$;
