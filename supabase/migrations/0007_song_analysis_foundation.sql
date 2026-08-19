-- Premium song-analysis foundation. Prepared for the reference-track / lyric-sync / chord-map pass.
-- This migration is intentionally schema-only; no analyzer provider or billing dependency is introduced here.

create table public.project_audio_references (
  project_id uuid primary key references public.projects(id) on delete cascade,
  file_id uuid not null unique references public.files(id) on delete cascade,
  uploaded_by uuid not null default auth.uid() references public.profiles(id),
  analysis_state text not null default 'uploaded'
    check (analysis_state in ('uploaded', 'queued', 'processing', 'ready', 'failed')),
  duration_ms integer check (duration_ms is null or duration_ms >= 0),
  bpm double precision check (bpm is null or bpm > 0),
  musical_key text,
  analyzer_version text,
  lyric_confidence double precision
    check (lyric_confidence is null or lyric_confidence between 0 and 1),
  chord_confidence double precision
    check (chord_confidence is null or chord_confidence between 0 and 1),
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.lyric_sync_cues (
  contribution_id uuid primary key,
  project_id uuid not null,
  start_ms integer not null check (start_ms >= 0),
  end_ms integer not null check (end_ms >= start_ms),
  confidence double precision not null default 0
    check (confidence between 0 and 1),
  source text not null default 'automatic'
    check (source in ('automatic', 'reviewed', 'manual')),
  updated_at timestamptz not null default now(),
  foreign key (contribution_id, project_id)
    references public.contributions(id, project_id)
    on delete cascade
);

create table public.chord_cues (
  id bigint generated always as identity primary key,
  project_id uuid not null references public.projects(id) on delete cascade,
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

create index project_audio_references_uploaded_by_idx
  on public.project_audio_references(uploaded_by);
create index lyric_sync_cues_project_start_idx
  on public.lyric_sync_cues(project_id, start_ms);
create index chord_cues_project_start_idx
  on public.chord_cues(project_id, start_ms);

create trigger project_audio_references_set_updated_at
before update on public.project_audio_references
for each row execute function public.set_updated_at();

create trigger lyric_sync_cues_set_updated_at
before update on public.lyric_sync_cues
for each row execute function public.set_updated_at();

create trigger chord_cues_set_updated_at
before update on public.chord_cues
for each row execute function public.set_updated_at();

alter table public.project_audio_references enable row level security;
alter table public.lyric_sync_cues enable row level security;
alter table public.chord_cues enable row level security;

create policy project_audio_references_read_room
on public.project_audio_references
for select to authenticated
using (
  exists (
    select 1 from public.projects p
    where p.id = project_id and private.is_room_member(p.room_id)
  )
);

create policy project_audio_references_create_editors
on public.project_audio_references
for insert to authenticated
with check (
  uploaded_by = (select auth.uid())
  and exists (
    select 1 from public.projects p
    where p.id = project_id
      and private.room_role_for(p.room_id) in ('owner', 'editor')
  )
  and exists (
    select 1 from public.files f
    where f.id = file_id and f.project_id = project_id
  )
);

create policy project_audio_references_update_editors
on public.project_audio_references
for update to authenticated
using (
  exists (
    select 1 from public.projects p
    where p.id = project_id
      and private.room_role_for(p.room_id) in ('owner', 'editor')
  )
)
with check (
  exists (
    select 1 from public.projects p
    where p.id = project_id
      and private.room_role_for(p.room_id) in ('owner', 'editor')
  )
  and exists (
    select 1 from public.files f
    where f.id = file_id and f.project_id = project_id
  )
);

create policy project_audio_references_delete_editors
on public.project_audio_references
for delete to authenticated
using (
  exists (
    select 1 from public.projects p
    where p.id = project_id
      and private.room_role_for(p.room_id) in ('owner', 'editor')
  )
);

create policy lyric_sync_cues_read_room
on public.lyric_sync_cues
for select to authenticated
using (
  exists (
    select 1 from public.projects p
    where p.id = project_id and private.is_room_member(p.room_id)
  )
);

create policy lyric_sync_cues_create_editors
on public.lyric_sync_cues
for insert to authenticated
with check (
  exists (
    select 1 from public.projects p
    where p.id = project_id
      and private.room_role_for(p.room_id) in ('owner', 'editor')
  )
);

create policy lyric_sync_cues_update_editors
on public.lyric_sync_cues
for update to authenticated
using (
  exists (
    select 1 from public.projects p
    where p.id = project_id
      and private.room_role_for(p.room_id) in ('owner', 'editor')
  )
)
with check (
  exists (
    select 1 from public.projects p
    where p.id = project_id
      and private.room_role_for(p.room_id) in ('owner', 'editor')
  )
);

create policy lyric_sync_cues_delete_editors
on public.lyric_sync_cues
for delete to authenticated
using (
  exists (
    select 1 from public.projects p
    where p.id = project_id
      and private.room_role_for(p.room_id) in ('owner', 'editor')
  )
);

create policy chord_cues_read_room
on public.chord_cues
for select to authenticated
using (
  exists (
    select 1 from public.projects p
    where p.id = project_id and private.is_room_member(p.room_id)
  )
);

create policy chord_cues_create_editors
on public.chord_cues
for insert to authenticated
with check (
  exists (
    select 1 from public.projects p
    where p.id = project_id
      and private.room_role_for(p.room_id) in ('owner', 'editor')
  )
);

create policy chord_cues_update_editors
on public.chord_cues
for update to authenticated
using (
  exists (
    select 1 from public.projects p
    where p.id = project_id
      and private.room_role_for(p.room_id) in ('owner', 'editor')
  )
)
with check (
  exists (
    select 1 from public.projects p
    where p.id = project_id
      and private.room_role_for(p.room_id) in ('owner', 'editor')
  )
);

create policy chord_cues_delete_editors
on public.chord_cues
for delete to authenticated
using (
  exists (
    select 1 from public.projects p
    where p.id = project_id
      and private.room_role_for(p.room_id) in ('owner', 'editor')
  )
);

revoke all on table
  public.project_audio_references,
  public.lyric_sync_cues,
  public.chord_cues
from anon;

grant select, insert, update, delete on table public.project_audio_references to authenticated;
grant select, insert, update, delete on table public.lyric_sync_cues to authenticated;
grant select, insert, update, delete on table public.chord_cues to authenticated;
grant usage, select on sequence public.chord_cues_id_seq to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'project_audio_references'
  ) then
    alter publication supabase_realtime add table public.project_audio_references;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'lyric_sync_cues'
  ) then
    alter publication supabase_realtime add table public.lyric_sync_cues;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'chord_cues'
  ) then
    alter publication supabase_realtime add table public.chord_cues;
  end if;
end;
$$;