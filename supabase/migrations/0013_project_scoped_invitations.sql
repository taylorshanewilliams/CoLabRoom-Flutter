-- Song-only invitations: grants access to exactly one project instead of the
-- whole Room. Room-wide invitations (public.invitations.project_id is null)
-- are unchanged and remain the only way to become a full public.room_members
-- row. This migration adds a parallel, narrower grant path
-- (public.project_members) and widens every RLS policy that currently reads
-- "is a room member" to also accept "is a project-only member of this
-- specific project" — never the reverse: project-only access never implies
-- room-wide access anywhere in this file.
--
-- v1 scope (per product decision): core access only. A song-only member can
-- open, view, and edit that one song (lyrics, chords, recordings/analysis).
-- Deferred to a later migration: unique per-project color assignment (they
-- get the same flat default room_members already defaults to), a "who has
-- access to this song" management UI, and promoting a song-only member to a
-- full room member.

create table public.project_members (
  project_id uuid not null references public.projects(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  display_name text not null default 'Member',
  role public.room_role not null default 'editor',
  color_value bigint not null default 4294957644,
  joined_at timestamptz not null default now(),
  primary key (project_id, user_id)
);

create index project_members_user_id_idx on public.project_members (user_id, project_id);

alter table public.project_members enable row level security;

-- No direct client writes in v1 — only accept_project_invitation_by_id
-- (security definer) creates rows here. Read access: your own row, or the
-- Room owner (groundwork for a future "manage access" screen).
create policy project_members_read on public.project_members
for select to authenticated using (
  user_id = (select auth.uid())
  or exists (
    select 1 from public.projects p
    where p.id = project_id and private.room_role_for(p.room_id) = 'owner'
  )
);

revoke all on table public.project_members from anon;
grant select on table public.project_members to authenticated;

alter table public.invitations
  add column if not exists project_id uuid references public.projects(id) on delete cascade;

create index if not exists invitations_project_id_idx on public.invitations (project_id);

create or replace function private.is_project_member(target_project uuid)
returns boolean
language sql
stable
security definer set search_path = ''
as $$
  select exists (
    select 1 from public.project_members
    where project_id = target_project and user_id = auth.uid()
  );
$$;

create or replace function private.project_role_for(target_project uuid)
returns public.room_role
language sql
stable
security definer set search_path = ''
as $$
  select role from public.project_members
  where project_id = target_project and user_id = auth.uid()
  limit 1;
$$;

revoke all on function private.is_project_member(uuid) from public, anon;
revoke all on function private.project_role_for(uuid) from public, anon;
grant execute on function private.is_project_member(uuid) to authenticated;
grant execute on function private.project_role_for(uuid) to authenticated;

-- Mirrors create_room_invitation, scoped to one project. Only the Room
-- owner can send one, same authority requirement as a room-wide invite.
create or replace function public.create_project_invitation(
  target_project uuid,
  invite_email text,
  invite_role public.room_role default 'editor'
)
returns text
language plpgsql
security definer set search_path = public, extensions
as $$
declare
  raw_token text := encode(gen_random_bytes(18), 'hex');
  normalized_email text := lower(trim(invite_email));
  target_room uuid;
begin
  select room_id into target_room from public.projects where id = target_project;
  if target_room is null then
    raise exception 'That song could not be found.' using errcode = '22023';
  end if;
  if private.room_role_for(target_room) <> 'owner' then
    raise exception 'Only the Room owner can invite collaborators.' using errcode = '42501';
  end if;
  if normalized_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'Enter a valid email address.' using errcode = '22023';
  end if;
  update public.invitations
  set status = 'expired'
  where project_id = target_project
    and lower(email) = normalized_email
    and status = 'pending';
  insert into public.invitations (
    room_id,
    project_id,
    invited_by,
    email,
    role,
    token_hash
  ) values (
    target_room,
    target_project,
    auth.uid(),
    normalized_email,
    invite_role,
    encode(digest(raw_token, 'sha256'), 'hex')
  );
  return raw_token;
end;
$$;

-- Mirrors accept_room_invitation_by_id, but inserts into project_members
-- instead of room_members and returns the project_id (not room_id) so the
-- caller can navigate straight to the song. No color-uniqueness locking in
-- v1 — every song-only member gets the same flat default color.
create or replace function public.accept_project_invitation_by_id(target_invitation uuid)
returns uuid
language plpgsql
security definer set search_path = public
as $$
declare
  selected public.invitations%rowtype;
  member_name text;
begin
  select * into selected
  from public.invitations
  where id = target_invitation
    and status = 'pending'
    and expires_at > now()
    and project_id is not null
  for update;

  if selected.id is null then
    raise exception 'That invitation is no longer available.' using errcode = '22023';
  end if;
  if lower(selected.email) <> lower(coalesce(auth.jwt() ->> 'email', '')) then
    raise exception 'This invitation belongs to a different email address.' using errcode = '42501';
  end if;

  select display_name into member_name from public.profiles where id = auth.uid();

  insert into public.project_members (project_id, user_id, display_name, role)
  values (selected.project_id, auth.uid(), coalesce(member_name, 'Member'), selected.role)
  on conflict (project_id, user_id) do update
  set role = excluded.role,
      display_name = excluded.display_name;

  update public.invitations set status = 'accepted' where id = selected.id;

  return selected.project_id;
end;
$$;

revoke all on function public.create_project_invitation(uuid, text, public.room_role) from public, anon;
revoke all on function public.accept_project_invitation_by_id(uuid) from public, anon;
grant execute on function public.create_project_invitation(uuid, text, public.room_role) to authenticated;
grant execute on function public.accept_project_invitation_by_id(uuid) to authenticated;

-- accept_room_invitation (the "join by code" path) previously always
-- delegated to accept_room_invitation_by_id, regardless of scope — a
-- project-scoped invite's code would have granted whole-Room access
-- instead of just the one song. Route by scope instead.
create or replace function public.accept_room_invitation(invite_token text)
returns uuid
language plpgsql
security definer set search_path = public, extensions
as $$
declare
  target_id uuid;
  target_project uuid;
begin
  select id, project_id into target_id, target_project
  from public.invitations
  where token_hash = encode(digest(trim(invite_token), 'sha256'), 'hex')
    and status = 'pending'
    and expires_at > now();
  if target_id is null then
    raise exception 'That invite code is invalid or expired.' using errcode = '22023';
  end if;
  if target_project is not null then
    return public.accept_project_invitation_by_id(target_id);
  end if;
  return public.accept_room_invitation_by_id(target_id);
end;
$$;

revoke all on function public.accept_room_invitation(text) from public, anon;
grant execute on function public.accept_room_invitation(text) to authenticated;

-- ---------------------------------------------------------------------
-- Widen existing RLS policies to also accept project-only membership.
-- decline_room_invitation and invitations_read_participants are already
-- scope-agnostic (id/email based) and need no change. Every policy below
-- is dropped and recreated under its existing name so this is a true
-- replacement, not an additional/competing policy.
-- ---------------------------------------------------------------------

drop policy if exists rooms_read_members on public.rooms;
create policy rooms_read_members on public.rooms
for select to authenticated using (
  account_id = (select auth.uid())
  or private.is_room_member(id)
  or exists (
    select 1 from public.projects p
    where p.room_id = rooms.id and private.is_project_member(p.id)
  )
  or exists (
    select 1 from public.invitations invitation
    where invitation.room_id = rooms.id
      and invitation.status = 'pending'
      and lower(invitation.email) = lower(coalesce((select auth.jwt()) ->> 'email', ''))
  )
);

drop policy if exists projects_read_members on public.projects;
create policy projects_read_members on public.projects
for select to authenticated using (
  private.is_room_member(room_id)
  or private.is_project_member(id)
  or exists (
    select 1 from public.invitations invitation
    where invitation.project_id = projects.id
      and invitation.status = 'pending'
      and lower(invitation.email) = lower(coalesce((select auth.jwt()) ->> 'email', ''))
  )
);

drop policy if exists contributions_read_members on public.contributions;
create policy contributions_read_members on public.contributions
for select to authenticated using (
  private.is_project_member(project_id)
  or exists (select 1 from public.projects p where p.id = project_id and private.is_room_member(p.room_id))
);

drop policy if exists contributions_create_editors on public.contributions;
create policy contributions_create_editors on public.contributions
for insert to authenticated with check (
  author_id = (select auth.uid()) and (
    private.project_role_for(project_id) in ('owner', 'editor')
    or exists (
      select 1 from public.projects p
      where p.id = project_id and private.room_role_for(p.room_id) in ('owner', 'editor')
    )
  )
);

drop policy if exists contributions_update_room_editors on public.contributions;
create policy contributions_update_room_editors on public.contributions
for update to authenticated
using (
  private.project_role_for(project_id) in ('owner', 'editor')
  or exists (
    select 1 from public.projects p
    where p.id = project_id and private.room_role_for(p.room_id) in ('owner', 'editor')
  )
)
with check (
  private.project_role_for(project_id) in ('owner', 'editor')
  or exists (
    select 1 from public.projects p
    where p.id = project_id and private.room_role_for(p.room_id) in ('owner', 'editor')
  )
);

drop policy if exists contributions_delete_room_editors on public.contributions;
create policy contributions_delete_room_editors on public.contributions
for delete to authenticated
using (
  private.project_role_for(project_id) in ('owner', 'editor')
  or exists (
    select 1 from public.projects p
    where p.id = project_id and private.room_role_for(p.room_id) in ('owner', 'editor')
  )
);

drop policy if exists revisions_read_members on public.contribution_revisions;
create policy revisions_read_members on public.contribution_revisions
for select to authenticated using (
  exists (
    select 1 from public.contributions c
    where c.id = contribution_id
      and (
        private.is_project_member(c.project_id)
        or exists (select 1 from public.projects p where p.id = c.project_id and private.is_room_member(p.room_id))
      )
  )
);

drop policy if exists revisions_create_editors on public.contribution_revisions;
create policy revisions_create_editors on public.contribution_revisions
for insert to authenticated with check (
  edited_by = (select auth.uid()) and exists (
    select 1 from public.contributions c
    where c.id = contribution_id
      and (
        private.project_role_for(c.project_id) in ('owner', 'editor')
        or exists (select 1 from public.projects p where p.id = c.project_id and private.room_role_for(p.room_id) in ('owner', 'editor'))
      )
  )
);

drop policy if exists comments_read_members on public.comments;
create policy comments_read_members on public.comments
for select to authenticated using (
  exists (
    select 1 from public.contributions c
    where c.id = contribution_id
      and (
        private.is_project_member(c.project_id)
        or exists (select 1 from public.projects p where p.id = c.project_id and private.is_room_member(p.room_id))
      )
  )
);

drop policy if exists comments_create_participants on public.comments;
create policy comments_create_participants on public.comments
for insert to authenticated with check (
  author_id = (select auth.uid()) and exists (
    select 1 from public.contributions c
    where c.id = contribution_id
      and (
        private.project_role_for(c.project_id) in ('owner', 'editor', 'commenter')
        or exists (
          select 1 from public.projects p
          where p.id = c.project_id and private.room_role_for(p.room_id) in ('owner', 'editor', 'commenter')
        )
      )
  )
);

drop policy if exists files_read_members on public.files;
create policy files_read_members on public.files
for select to authenticated using (
  private.is_project_member(project_id)
  or exists (select 1 from public.projects p where p.id = project_id and private.is_room_member(p.room_id))
);

drop policy if exists files_create_editors on public.files;
create policy files_create_editors on public.files
for insert to authenticated with check (
  uploaded_by = (select auth.uid()) and (
    private.project_role_for(project_id) in ('owner', 'editor')
    or exists (select 1 from public.projects p where p.id = project_id and private.room_role_for(p.room_id) in ('owner', 'editor'))
  )
);

drop policy if exists files_delete_room_editors on public.files;
create policy files_delete_room_editors on public.files
for delete to authenticated
using (
  private.project_role_for(project_id) in ('owner', 'editor')
  or exists (select 1 from public.projects p where p.id = project_id and private.room_role_for(p.room_id) in ('owner', 'editor'))
);

drop policy if exists history_read_members on public.project_history;
create policy history_read_members on public.project_history
for select to authenticated using (
  private.is_project_member(project_id)
  or exists (select 1 from public.projects p where p.id = project_id and private.is_room_member(p.room_id))
);

drop policy if exists history_create_members on public.project_history;
create policy history_create_members on public.project_history
for insert to authenticated with check (
  actor_id = (select auth.uid()) and (
    private.is_project_member(project_id)
    or exists (select 1 from public.projects p where p.id = project_id and private.is_room_member(p.room_id))
  )
);

drop policy if exists project_audio_references_read_room on public.project_audio_references;
create policy project_audio_references_read_room
on public.project_audio_references
for select to authenticated
using (
  private.is_project_member(project_id)
  or exists (select 1 from public.projects p where p.id = project_id and private.is_room_member(p.room_id))
);

drop policy if exists project_audio_references_create_editors on public.project_audio_references;
create policy project_audio_references_create_editors
on public.project_audio_references
for insert to authenticated
with check (
  uploaded_by = (select auth.uid())
  and (
    private.project_role_for(project_id) in ('owner', 'editor')
    or exists (select 1 from public.projects p where p.id = project_id and private.room_role_for(p.room_id) in ('owner', 'editor'))
  )
  and exists (select 1 from public.files f where f.id = file_id and f.project_id = project_id)
);

drop policy if exists project_audio_references_update_editors on public.project_audio_references;
create policy project_audio_references_update_editors
on public.project_audio_references
for update to authenticated
using (
  private.project_role_for(project_id) in ('owner', 'editor')
  or exists (select 1 from public.projects p where p.id = project_id and private.room_role_for(p.room_id) in ('owner', 'editor'))
)
with check (
  (
    private.project_role_for(project_id) in ('owner', 'editor')
    or exists (select 1 from public.projects p where p.id = project_id and private.room_role_for(p.room_id) in ('owner', 'editor'))
  )
  and exists (select 1 from public.files f where f.id = file_id and f.project_id = project_id)
);

drop policy if exists project_audio_references_delete_editors on public.project_audio_references;
create policy project_audio_references_delete_editors
on public.project_audio_references
for delete to authenticated
using (
  private.project_role_for(project_id) in ('owner', 'editor')
  or exists (select 1 from public.projects p where p.id = project_id and private.room_role_for(p.room_id) in ('owner', 'editor'))
);

drop policy if exists lyric_sync_cues_read_room on public.lyric_sync_cues;
create policy lyric_sync_cues_read_room
on public.lyric_sync_cues
for select to authenticated
using (
  private.is_project_member(project_id)
  or exists (select 1 from public.projects p where p.id = project_id and private.is_room_member(p.room_id))
);

drop policy if exists lyric_sync_cues_create_editors on public.lyric_sync_cues;
create policy lyric_sync_cues_create_editors
on public.lyric_sync_cues
for insert to authenticated
with check (
  private.project_role_for(project_id) in ('owner', 'editor')
  or exists (select 1 from public.projects p where p.id = project_id and private.room_role_for(p.room_id) in ('owner', 'editor'))
);

drop policy if exists lyric_sync_cues_update_editors on public.lyric_sync_cues;
create policy lyric_sync_cues_update_editors
on public.lyric_sync_cues
for update to authenticated
using (
  private.project_role_for(project_id) in ('owner', 'editor')
  or exists (select 1 from public.projects p where p.id = project_id and private.room_role_for(p.room_id) in ('owner', 'editor'))
)
with check (
  private.project_role_for(project_id) in ('owner', 'editor')
  or exists (select 1 from public.projects p where p.id = project_id and private.room_role_for(p.room_id) in ('owner', 'editor'))
);

drop policy if exists lyric_sync_cues_delete_editors on public.lyric_sync_cues;
create policy lyric_sync_cues_delete_editors
on public.lyric_sync_cues
for delete to authenticated
using (
  private.project_role_for(project_id) in ('owner', 'editor')
  or exists (select 1 from public.projects p where p.id = project_id and private.room_role_for(p.room_id) in ('owner', 'editor'))
);

drop policy if exists chord_cues_read_room on public.chord_cues;
create policy chord_cues_read_room
on public.chord_cues
for select to authenticated
using (
  private.is_project_member(project_id)
  or exists (select 1 from public.projects p where p.id = project_id and private.is_room_member(p.room_id))
);

drop policy if exists chord_cues_create_editors on public.chord_cues;
create policy chord_cues_create_editors
on public.chord_cues
for insert to authenticated
with check (
  private.project_role_for(project_id) in ('owner', 'editor')
  or exists (select 1 from public.projects p where p.id = project_id and private.room_role_for(p.room_id) in ('owner', 'editor'))
);

drop policy if exists chord_cues_update_editors on public.chord_cues;
create policy chord_cues_update_editors
on public.chord_cues
for update to authenticated
using (
  private.project_role_for(project_id) in ('owner', 'editor')
  or exists (select 1 from public.projects p where p.id = project_id and private.room_role_for(p.room_id) in ('owner', 'editor'))
)
with check (
  private.project_role_for(project_id) in ('owner', 'editor')
  or exists (select 1 from public.projects p where p.id = project_id and private.room_role_for(p.room_id) in ('owner', 'editor'))
);

drop policy if exists chord_cues_delete_editors on public.chord_cues;
create policy chord_cues_delete_editors
on public.chord_cues
for delete to authenticated
using (
  private.project_role_for(project_id) in ('owner', 'editor')
  or exists (select 1 from public.projects p where p.id = project_id and private.room_role_for(p.room_id) in ('owner', 'editor'))
);

-- Storage objects are named <room-id>/<project-id>/<filename> — a
-- project-only member may only reach the second path segment matching
-- their own project, never the room's other files.
drop policy if exists room_files_read_members on storage.objects;
create policy room_files_read_members on storage.objects
for select to authenticated using (
  bucket_id = 'room-files'
  and (
    private.is_room_member(((storage.foldername(name))[1])::uuid)
    or (
      array_length(storage.foldername(name), 1) >= 2
      and private.is_project_member(((storage.foldername(name))[2])::uuid)
    )
  )
);

drop policy if exists room_files_write_editors on storage.objects;
create policy room_files_write_editors on storage.objects
for insert to authenticated with check (
  bucket_id = 'room-files'
  and (
    private.room_role_for(((storage.foldername(name))[1])::uuid) in ('owner', 'editor')
    or (
      array_length(storage.foldername(name), 1) >= 2
      and private.project_role_for(((storage.foldername(name))[2])::uuid) in ('owner', 'editor')
    )
  )
);

drop policy if exists room_files_delete_room_editors on storage.objects;
create policy room_files_delete_room_editors on storage.objects
for delete to authenticated
using (
  bucket_id = 'room-files'
  and exists (
    select 1
    from public.files f
    join public.projects p on p.id = f.project_id
    where f.storage_path = name
      and (
        private.room_role_for(p.room_id) in ('owner', 'editor')
        or private.project_role_for(p.id) in ('owner', 'editor')
      )
  )
);
