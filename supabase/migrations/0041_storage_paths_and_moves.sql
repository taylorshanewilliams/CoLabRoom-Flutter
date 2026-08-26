-- Three storage problems, one of which has been silently eating every take.
--
-- 1. A cast that throws instead of returning false.
--
-- The room-files policies read the room out of the first path segment and the
-- project out of the second, and cast both to uuid. That is fine for the paths
-- this app has always written — {room}/{project}/... — and it is an *error*,
-- not a false, for anything else. A permissive policy whose expression raises
-- takes the whole statement with it, however many other policies would have
-- allowed it.
--
-- Layers were being written to {project}/layers/{id}, which puts the literal
-- string 'layers' where a project uuid was expected. Every upload therefore
-- failed on a cast, no matter that 0038 had added a policy that allowed them.
-- The table has zero rows to show for it, and the app reported nothing,
-- because the failure looked like an ordinary error on a path that swallowed
-- ordinary errors.
--
-- The client now writes {room}/{project}/layers/{id}, which sidesteps it. This
-- removes the landmine as well, because the next feature to invent a path is
-- not going to remember.
--
-- 2. Moving a song leaves its audio behind.
--
-- Moving a project updates projects.room_id and nothing else — correctly, the
-- lyrics are keyed on the project and follow it. But the objects were written
-- under the *old* room's id and the read policy asks the path who owns them,
-- so a song moved into a room reads as belonging to a room the new members may
-- not be in. The lyrics arrive and the audio does not.
--
-- Asking the database rather than the path fixes it for every move, past and
-- future, without touching a single object: `files` already records which
-- project owns each path, and the project already records its room.
--
-- 3. 0038's own write policy no longer matches the path it was written for.

-- ---------------------------------------------------------------------
-- A cast that cannot throw.
-- ---------------------------------------------------------------------
create or replace function private.as_uuid(value text)
returns uuid
language sql
immutable
set search_path = ''
as $$
  select case
    when value ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then value::uuid
    else null
  end;
$$;

grant execute on function private.as_uuid(text) to authenticated;

-- ---------------------------------------------------------------------
-- The room-files policies, with the casts made safe and a data-driven
-- branch added so a moved project keeps its audio.
--
-- The path branches are kept exactly as they were, because they are what
-- lets a project-scoped member — somebody invited to one song rather than
-- the whole room — reach their own project's folder. The new branch is
-- additive: it grants where the row says so, and nothing that worked
-- before stops working.
-- ---------------------------------------------------------------------
drop policy if exists room_files_read_members on storage.objects;
create policy room_files_read_members on storage.objects
for select to authenticated using (
  bucket_id = 'room-files'
  and (
    private.is_room_member(private.as_uuid((storage.foldername(name))[1]))
    or (
      array_length(storage.foldername(name), 1) >= 2
      and private.is_project_member(private.as_uuid((storage.foldername(name))[2]))
    )
    -- Where the object actually belongs, rather than where it was put. This
    -- is the branch that survives a move.
    or exists (
      select 1
      from public.files f
      join public.projects p on p.id = f.project_id
      where f.storage_path = name
        and (private.is_room_member(p.room_id) or private.is_project_member(p.id))
    )
  )
);

drop policy if exists room_files_write_editors on storage.objects;
create policy room_files_write_editors on storage.objects
for insert to authenticated with check (
  bucket_id = 'room-files'
  and (
    private.room_role_for(private.as_uuid((storage.foldername(name))[1]))
      in ('owner', 'editor')
    or (
      array_length(storage.foldername(name), 1) >= 2
      and private.project_role_for(private.as_uuid((storage.foldername(name))[2]))
        in ('owner', 'editor')
    )
  )
);

-- ---------------------------------------------------------------------
-- 0038's layer policies, against the path the client actually writes.
-- ---------------------------------------------------------------------
drop policy if exists song_layer_files_write_members on storage.objects;
create policy song_layer_files_write_members on storage.objects
for insert to authenticated with check (
  bucket_id = 'room-files'
  and name like '%/layers/%'
  and array_length(storage.foldername(name), 1) >= 3
  and exists (
    select 1 from public.projects p
    where p.id = private.as_uuid((storage.foldername(name))[2])
      and private.is_room_member(p.room_id)
  )
);
