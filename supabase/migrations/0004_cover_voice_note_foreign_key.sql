-- The initial voice-note migration used a partial line index. The foreign-key
-- cascade also needs coverage for soft-deleted rows, so keep a full composite index.
drop index if exists public.files_contribution_id_idx;

create index if not exists files_contribution_project_idx
  on public.files (contribution_id, project_id);
