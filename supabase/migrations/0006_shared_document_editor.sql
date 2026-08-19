-- Continuous shared-document editing and safe per-room member colors.

create unique index if not exists room_members_room_color_unique
  on public.room_members (room_id, color_value);

create or replace function public.accept_room_invitation_by_id(target_invitation uuid)
returns uuid
language plpgsql
security definer set search_path = public
as $$
declare
  selected public.invitations%rowtype;
  member_name text;
  member_color bigint;
  palette bigint[] := array[
    4294938957, -- FF914D
    4282045439, -- 3AD3FF
    4282767013, -- 45D6A5
    4290352127, -- B993FF
    4294953047, -- FFC857
    4294930350, -- FF6FAE
    4286352639, -- 7C8CFF
    4281258935, -- 2ED3B7
    4289257571, -- A8E063
    4294933114  -- FF7A7A
  ];
begin
  select * into selected
  from public.invitations
  where id = target_invitation
    and status = 'pending'
    and expires_at > now()
  for update;

  if selected.id is null then
    raise exception 'That invitation is no longer available.' using errcode = '22023';
  end if;
  if lower(selected.email) <> lower(coalesce(auth.jwt() ->> 'email', '')) then
    raise exception 'This invitation belongs to a different email address.' using errcode = '42501';
  end if;

  select display_name into member_name
  from public.profiles
  where id = auth.uid();

  select color_value into member_color
  from public.room_members
  where room_id = selected.room_id
    and user_id = auth.uid();

  if member_color is null then
    lock table public.room_members in share row exclusive mode;
    select candidate into member_color
    from unnest(palette) with ordinality as colors(candidate, priority)
    where not exists (
      select 1
      from public.room_members rm
      where rm.room_id = selected.room_id
        and rm.color_value = candidate
    )
    order by priority
    limit 1;
  end if;

  if member_color is null then
    raise exception 'This Room has no unused collaborator colors available.' using errcode = '54000';
  end if;

  insert into public.room_members (room_id, user_id, display_name, role, color_value)
  values (
    selected.room_id,
    auth.uid(),
    coalesce(member_name, 'Member'),
    selected.role,
    member_color
  )
  on conflict (room_id, user_id) do update
  set role = excluded.role,
      display_name = excluded.display_name;

  update public.invitations
  set status = 'accepted'
  where id = selected.id;

  return selected.room_id;
end;
$$;

revoke all on function public.accept_room_invitation_by_id(uuid) from public, anon;
grant execute on function public.accept_room_invitation_by_id(uuid) to authenticated;

create or replace function public.set_my_room_color(
  target_room uuid,
  target_color bigint
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  allowed_colors bigint[] := array[
    4294938957, -- FF914D
    4282045439, -- 3AD3FF
    4282767013, -- 45D6A5
    4290352127, -- B993FF
    4294953047, -- FFC857
    4294930350, -- FF6FAE
    4286352639, -- 7C8CFF
    4281258935, -- 2ED3B7
    4289257571, -- A8E063
    4294933114  -- FF7A7A
  ];
begin
  if current_user_id is null then
    raise exception 'You must be signed in.' using errcode = '42501';
  end if;

  if not target_color = any(allowed_colors) then
    raise exception 'Choose one of the available Room colors.' using errcode = '22023';
  end if;

  if not exists (
    select 1
    from public.room_members rm
    where rm.room_id = target_room
      and rm.user_id = current_user_id
  ) then
    raise exception 'You are not a member of this Room.' using errcode = '42501';
  end if;

  lock table public.room_members in share row exclusive mode;

  if exists (
    select 1
    from public.room_members rm
    where rm.room_id = target_room
      and rm.user_id <> current_user_id
      and rm.color_value = target_color
  ) then
    raise exception 'That color is already being used in this Room.' using errcode = '23505';
  end if;

  update public.room_members
  set color_value = target_color
  where room_id = target_room
    and user_id = current_user_id;

  update public.contributions c
  set color_value = target_color
  where c.author_id = current_user_id
    and exists (
      select 1
      from public.projects p
      where p.id = c.project_id
        and p.room_id = target_room
    );
end;
$$;

revoke all on function public.set_my_room_color(uuid, bigint) from public, anon;
grant execute on function public.set_my_room_color(uuid, bigint) to authenticated;

-- A Room editor edits the shared song document, not only rows they originally authored.
drop policy if exists contributions_update_author_or_owner on public.contributions;
drop policy if exists contributions_update_room_editors on public.contributions;
create policy contributions_update_room_editors on public.contributions
for update to authenticated
using (
  exists (
    select 1
    from public.projects p
    where p.id = project_id
      and private.room_role_for(p.room_id) in ('owner', 'editor')
  )
)
with check (
  exists (
    select 1
    from public.projects p
    where p.id = project_id
      and private.room_role_for(p.room_id) in ('owner', 'editor')
  )
);

drop policy if exists contributions_delete_author_or_owner on public.contributions;
drop policy if exists contributions_delete_room_editors on public.contributions;
create policy contributions_delete_room_editors on public.contributions
for delete to authenticated
using (
  exists (
    select 1
    from public.projects p
    where p.id = project_id
      and private.room_role_for(p.room_id) in ('owner', 'editor')
  )
);

-- Limit direct contribution updates to shared-document content/order columns.
revoke update on table public.contributions from authenticated;
grant update (body, position) on table public.contributions to authenticated;

-- If an editor removes a shared lyric line, its contextual voice note must be removable too.
drop policy if exists files_delete_uploader_or_owner on public.files;
drop policy if exists files_delete_room_editors on public.files;
create policy files_delete_room_editors on public.files
for delete to authenticated
using (
  exists (
    select 1
    from public.projects p
    where p.id = project_id
      and private.room_role_for(p.room_id) in ('owner', 'editor')
  )
);

drop policy if exists room_files_delete_uploader_or_owner on storage.objects;
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
      and private.room_role_for(p.room_id) in ('owner', 'editor')
  )
);
