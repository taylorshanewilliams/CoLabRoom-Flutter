-- Nine guards that never fired for a stranger.
--
-- `private.room_role_for` returns null when you are not in the room. Every
-- owner-only function in this app then asked
--
--     if private.room_role_for(target_room) <> 'owner' then raise ...
--
-- and `null <> 'owner'` is null, and `if null then` does not fire. So the
-- check passed for the one person it existed to stop: somebody who is not in
-- the room at all. A member with the wrong role was refused correctly; a
-- complete stranger walked through.
--
-- What that allowed, for any signed-in account against any catalog:
--
--   * `remove_room_member` — remove anybody from anybody's catalog. The worst
--     of them, and mine, shipped this morning.
--   * `invite_musician_to_room` — invite anybody to anybody's catalog.
--   * `create_room_invitation` and `create_project_invitation` — the same by
--     email, and live since migration 0001.
--
-- The row level security policies are *not* affected and never were: they use
-- `= 'owner'` and `in (...)` in a USING clause, where null is false and a
-- stranger is refused. The bug is only in `if ... then raise` guards inside
-- security definer functions, where null means "do not raise".
--
-- Found because a smoke test finally ran as `authenticated` instead of as the
-- superuser, and a stranger took somebody else's song off the Open Mic.
--
-- `is distinct from` is the whole fix. It is true when the left side is null,
-- which is exactly the case that was being waved through.

create or replace function public.create_room_invitation(
  target_room uuid,
  invite_email text,
  invite_role public.room_role default 'editor'
)
returns jsonb
language plpgsql
security definer set search_path = public, extensions
as $$
declare
  raw_token text := encode(gen_random_bytes(18), 'hex');
  normalized_email text := lower(trim(invite_email));
  new_invitation_id uuid;
  invited_user_id uuid;
  room_name text;
  inviter_name text;
begin
  if private.room_role_for(target_room) is distinct from 'owner' then
    raise exception 'Only the Room owner can invite collaborators.' using errcode = '42501';
  end if;
  if normalized_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'Enter a valid email address.' using errcode = '22023';
  end if;
  update public.invitations
  set status = 'expired'
  where room_id = target_room
    and lower(email) = normalized_email
    and status = 'pending';
  insert into public.invitations (
    room_id,
    invited_by,
    email,
    role,
    token_hash
  ) values (
    target_room,
    auth.uid(),
    normalized_email,
    invite_role,
    encode(digest(raw_token, 'sha256'), 'hex')
  )
  returning id into new_invitation_id;

  select id into invited_user_id from auth.users where lower(email) = normalized_email limit 1;
  if invited_user_id is not null then
    select name into room_name from public.rooms where id = target_room;
    select display_name into inviter_name from public.profiles where id = auth.uid();
    perform private.notify_user(
      invited_user_id,
      'invite_received',
      coalesce(inviter_name, 'A collaborator') || ' invited you to ' || coalesce(room_name, 'a Room'),
      'Open Invites to accept or decline.',
      target_room,
      null,
      new_invitation_id,
      auth.uid()
    );
  end if;

  return jsonb_build_object('token', raw_token, 'matched_account', invited_user_id is not null);
end;
$$;

create or replace function public.create_project_invitation(
  target_project uuid,
  invite_email text,
  invite_role public.room_role default 'editor'
)
returns jsonb
language plpgsql
security definer set search_path = public, extensions
as $$
declare
  raw_token text := encode(gen_random_bytes(18), 'hex');
  normalized_email text := lower(trim(invite_email));
  target_room uuid;
  new_invitation_id uuid;
  invited_user_id uuid;
  project_title text;
  inviter_name text;
begin
  select room_id into target_room from public.projects where id = target_project;
  if target_room is null then
    raise exception 'That song could not be found.' using errcode = '22023';
  end if;
  if private.room_role_for(target_room) is distinct from 'owner' then
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
  )
  returning id into new_invitation_id;

  select id into invited_user_id from auth.users where lower(email) = normalized_email limit 1;
  if invited_user_id is not null then
    select title into project_title from public.projects where id = target_project;
    select display_name into inviter_name from public.profiles where id = auth.uid();
    perform private.notify_user(
      invited_user_id,
      'invite_received',
      coalesce(inviter_name, 'A collaborator') || ' invited you to ' || coalesce(project_title, 'a song'),
      'Open Invites to accept or decline.',
      target_room,
      target_project,
      new_invitation_id,
      auth.uid()
    );
  end if;

  return jsonb_build_object('token', raw_token, 'matched_account', invited_user_id is not null);
end;
$$;

create or replace function public.remove_room_member(
  target_room uuid,
  target_user uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  room_owner uuid;
begin
  select account_id into room_owner from public.rooms where id = target_room;

  if room_owner is null then
    raise exception 'That catalog does not exist.' using errcode = '22023';
  end if;

  -- The owner, or you removing yourself. Anything else is refused here rather
  -- than left to RLS: this is a security definer function, and one that skips
  -- its own check is a way for any member to empty somebody's band.
  if not (private.room_role_for(target_room) is not distinct from 'owner'
          or target_user = auth.uid()) then
    raise exception 'Only the catalog owner can remove somebody.'
      using errcode = '42501';
  end if;

  -- The owner cannot be removed, including by themselves. A catalog with no
  -- owner is a catalog nobody can invite to, rename, or delete — the rows
  -- would still be there and nobody could reach them.
  if target_user = room_owner then
    raise exception
      'The owner cannot leave their own catalog. Hand it over or delete it.'
      using errcode = '22023';
  end if;

  delete from public.room_members
  where room_id = target_room and user_id = target_user;

  -- And every per-song membership inside it, or they keep the songs and lose
  -- only the listing.
  delete from public.project_members pm
  using public.projects p
  where pm.project_id = p.id
    and p.room_id = target_room
    and pm.user_id = target_user;
end;
$$;

create or replace function public.invite_musician_to_room(
  target_room uuid,
  target_person uuid,
  in_note text default ''
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  room_name text;
  inviter_name text;
  new_invite uuid;
begin
  if target_person = auth.uid() then
    raise exception 'You are already in it.' using errcode = '22023';
  end if;

  if private.blocked_between(auth.uid(), target_person) then
    raise exception 'That musician is not available.' using errcode = '22023';
  end if;

  if private.room_role_for(target_room) is distinct from 'owner' then
    raise exception 'Only the catalog owner can invite somebody to it.'
      using errcode = '42501';
  end if;

  if exists (
    select 1 from public.room_members
    where room_id = target_room and user_id = target_person
  ) then
    raise exception 'They are already in this catalog.' using errcode = '22023';
  end if;

  select name into room_name from public.rooms where id = target_room;
  select display_name into inviter_name
  from public.profiles where id = auth.uid();

  insert into public.room_invites (room_id, invited_profile, note)
  values (target_room, target_person, left(trim(coalesce(in_note, '')), 280))
  returning id into new_invite;

  perform private.notify_user(
    target_person,
    'invite_received',
    coalesce(inviter_name, 'Somebody') || ' invited you to ' ||
      coalesce(room_name, 'a catalog'),
    case
      when nullif(trim(coalesce(in_note, '')), '') is null
        then 'You would see the songs in it.'
      else left(trim(in_note), 200)
    end,
    target_room,
    null,
    null,
    auth.uid()
  );

  return new_invite;
end;
$$;
