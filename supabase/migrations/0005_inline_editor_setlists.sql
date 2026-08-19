-- Inline lyric editing, reusable setlists, project moves, and voice-note management.

alter table public.contributions
  add column position numeric not null default 0;

with ordered as (
  select id, row_number() over (partition by project_id order by created_at, id) * 1024 as value
  from public.contributions
)
update public.contributions as contribution
set position = ordered.value
from ordered
where contribution.id = ordered.id;

create index contributions_project_position_idx
  on public.contributions (project_id, position, created_at);

create or replace function public.archive_contribution_revision()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.body is distinct from old.body then
    insert into public.contribution_revisions (
      contribution_id,
      revision,
      body,
      edited_by
    ) values (
      old.id,
      old.revision,
      old.body,
      auth.uid()
    ) on conflict (contribution_id, revision) do nothing;
    new.revision = old.revision + 1;
  end if;
  return new;
end;
$$;

create trigger contributions_archive_revision
before update of body on public.contributions
for each row execute function public.archive_contribution_revision();

create table public.setlists (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  name text not null check (char_length(trim(name)) between 1 and 80),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index setlists_owner_name_unique
  on public.setlists (owner_id, lower(regexp_replace(trim(name), '\s+', ' ', 'g')));
create index setlists_owner_updated_idx on public.setlists (owner_id, updated_at desc);

create table public.setlist_projects (
  setlist_id uuid not null references public.setlists(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  position integer not null default 0 check (position >= 0),
  added_at timestamptz not null default now(),
  primary key (setlist_id, project_id)
);

create index setlist_projects_project_idx on public.setlist_projects (project_id);
create index setlist_projects_order_idx on public.setlist_projects (setlist_id, position);

create trigger setlists_set_updated_at before update on public.setlists
for each row execute function public.set_updated_at();

alter table public.setlists enable row level security;
alter table public.setlist_projects enable row level security;

create policy setlists_read_owner on public.setlists
for select to authenticated using (owner_id = (select auth.uid()));
create policy setlists_create_owner on public.setlists
for insert to authenticated with check (owner_id = (select auth.uid()));
create policy setlists_update_owner on public.setlists
for update to authenticated using (owner_id = (select auth.uid()))
with check (owner_id = (select auth.uid()));
create policy setlists_delete_owner on public.setlists
for delete to authenticated using (owner_id = (select auth.uid()));

create policy setlist_projects_read_owner on public.setlist_projects
for select to authenticated using (
  exists (
    select 1 from public.setlists s
    where s.id = setlist_id and s.owner_id = (select auth.uid())
  )
  and exists (
    select 1 from public.projects p
    where p.id = project_id and private.is_room_member(p.room_id)
  )
);
create policy setlist_projects_create_owner on public.setlist_projects
for insert to authenticated with check (
  exists (
    select 1 from public.setlists s
    where s.id = setlist_id and s.owner_id = (select auth.uid())
  )
  and exists (
    select 1 from public.projects p
    where p.id = project_id and private.is_room_member(p.room_id)
  )
);
create policy setlist_projects_update_owner on public.setlist_projects
for update to authenticated using (
  exists (
    select 1 from public.setlists s
    where s.id = setlist_id and s.owner_id = (select auth.uid())
  )
) with check (
  exists (
    select 1 from public.setlists s
    where s.id = setlist_id and s.owner_id = (select auth.uid())
  )
);
create policy setlist_projects_delete_owner on public.setlist_projects
for delete to authenticated using (
  exists (
    select 1 from public.setlists s
    where s.id = setlist_id and s.owner_id = (select auth.uid())
  )
);

create policy contributions_delete_author_or_owner on public.contributions
for delete to authenticated using (
  author_id = (select auth.uid()) or exists (
    select 1 from public.projects p
    where p.id = project_id and private.room_role_for(p.room_id) = 'owner'
  )
);

drop policy contributions_update_author_or_owner on public.contributions;
create policy contributions_update_author_or_owner on public.contributions
for update to authenticated using (
  private.room_role_for((select p.room_id from public.projects p where p.id = project_id))
    in ('owner', 'editor')
  and (
    author_id = (select auth.uid()) or exists (
      select 1 from public.projects p
      where p.id = project_id and private.room_role_for(p.room_id) = 'owner'
    )
  )
) with check (
  private.room_role_for((select p.room_id from public.projects p where p.id = project_id))
    in ('owner', 'editor')
  and (
    author_id = (select auth.uid()) or exists (
      select 1 from public.projects p
      where p.id = project_id and private.room_role_for(p.room_id) = 'owner'
    )
  )
);

create policy files_delete_uploader_or_owner on public.files
for delete to authenticated using (
  uploaded_by = (select auth.uid()) or exists (
    select 1 from public.projects p
    where p.id = project_id and private.room_role_for(p.room_id) = 'owner'
  )
);

drop policy projects_update_editors on public.projects;
create policy projects_update_editors on public.projects
for update to authenticated
using (private.room_role_for(room_id) in ('owner', 'editor'))
with check (
  private.room_role_for(room_id) in ('owner', 'editor')
  and exists (
    select 1 from public.rooms
    where id = room_id and account_id = projects.account_id
  )
);

grant select, insert, update, delete on table public.setlists to authenticated;
grant select, insert, update, delete on table public.setlist_projects to authenticated;
revoke all on table public.setlists, public.setlist_projects from anon;
grant delete on table public.contributions to authenticated;
grant delete on table public.files to authenticated;

drop policy room_files_read_members on storage.objects;
create policy room_files_read_members on storage.objects
for select to authenticated using (
  bucket_id = 'room-files'
  and exists (
    select 1
    from public.files f
    join public.projects p on p.id = f.project_id
    where f.storage_path = name
      and private.is_room_member(p.room_id)
  )
);

create policy room_files_delete_uploader_or_owner on storage.objects
for delete to authenticated using (
  bucket_id = 'room-files'
  and exists (
    select 1
    from public.files f
    join public.projects p on p.id = f.project_id
    where f.storage_path = name
      and (
        f.uploaded_by = (select auth.uid())
        or private.room_role_for(p.room_id) = 'owner'
      )
  )
);

alter publication supabase_realtime add table public.setlists, public.setlist_projects;
