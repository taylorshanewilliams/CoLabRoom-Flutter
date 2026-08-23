-- In-app notifications: a per-user feed (invite received/accepted/declined,
-- project activity) backing a bell/badge in the app, plus per-type toggles
-- in notification_preferences. No push/FCM/APNs here — in-app only.
--
-- Also upgrades create_room_invitation/create_project_invitation to notify
-- the invitee immediately when their email already has an account, so the
-- "copy a code, paste a code" flow is only needed as a fallback when it
-- doesn't.

create type public.notification_type as enum (
  'invite_received',
  'invite_accepted',
  'invite_declined',
  'project_update'
);

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  type public.notification_type not null,
  title text not null,
  body text not null default '',
  room_id uuid references public.rooms(id) on delete cascade,
  project_id uuid references public.projects(id) on delete cascade,
  invitation_id uuid references public.invitations(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create index notifications_user_id_created_at_idx
  on public.notifications (user_id, created_at desc);

alter table public.notifications enable row level security;

-- Leaf table, own-row only — no cross-table subquery, so none of the
-- RLS-recursion pattern documented for rooms/projects applies here. All
-- inserts happen through private.notify_user (security definer) below;
-- there is deliberately no insert policy for authenticated.
create policy notifications_read_own on public.notifications
for select to authenticated using (user_id = (select auth.uid()));

create policy notifications_update_own on public.notifications
for update to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

create policy notifications_delete_own on public.notifications
for delete to authenticated using (user_id = (select auth.uid()));

revoke all on table public.notifications from anon;
grant select, update, delete on table public.notifications to authenticated;

create table public.notification_preferences (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  invites boolean not null default true,
  invite_responses boolean not null default true,
  project_updates boolean not null default true,
  updated_at timestamptz not null default now()
);

alter table public.notification_preferences enable row level security;

create policy notification_preferences_rw_own on public.notification_preferences
for all to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

revoke all on table public.notification_preferences from anon;
grant select, insert, update on table public.notification_preferences to authenticated;

-- Reuses the generic public.set_updated_at() trigger function already
-- defined in 0001_music_beta.sql for rooms/projects/contributions/comments.
create trigger notification_preferences_set_updated_at
before update on public.notification_preferences
for each row execute function public.set_updated_at();

create or replace function private.wants_invites(target_user uuid)
returns boolean
language sql
stable
security definer set search_path = ''
as $$
  select coalesce(
    (select invites from public.notification_preferences where user_id = target_user),
    true
  );
$$;

create or replace function private.wants_invite_responses(target_user uuid)
returns boolean
language sql
stable
security definer set search_path = ''
as $$
  select coalesce(
    (select invite_responses from public.notification_preferences where user_id = target_user),
    true
  );
$$;

create or replace function private.wants_project_updates(target_user uuid)
returns boolean
language sql
stable
security definer set search_path = ''
as $$
  select coalesce(
    (select project_updates from public.notification_preferences where user_id = target_user),
    true
  );
$$;

-- Unlike private.is_room_member/private.room_role_for, none of these are
-- referenced from an RLS policy (which evaluates as the querying user and
-- so needs a direct grant) — they're only called from inside the other
-- security-definer functions below, which already run as their owner. No
-- grant to authenticated needed.
revoke all on function private.wants_invites(uuid) from public, anon, authenticated;
revoke all on function private.wants_invite_responses(uuid) from public, anon, authenticated;
revoke all on function private.wants_project_updates(uuid) from public, anon, authenticated;

-- Central insert helper: checks the recipient's preference for notif_type,
-- skips self-notification, and no-ops (rather than raising) when the
-- recipient opted out — callers never need to branch on preferences.
create or replace function private.notify_user(
  target_user uuid,
  notif_type public.notification_type,
  notif_title text,
  notif_body text,
  target_room uuid default null,
  target_project uuid default null,
  target_invitation uuid default null,
  notif_actor uuid default null
)
returns void
language plpgsql
security definer set search_path = ''
as $$
begin
  if target_user is null or target_user = notif_actor then
    return;
  end if;

  if notif_type = 'invite_received' and not private.wants_invites(target_user) then
    return;
  end if;
  if notif_type in ('invite_accepted', 'invite_declined')
     and not private.wants_invite_responses(target_user) then
    return;
  end if;
  if notif_type = 'project_update' and not private.wants_project_updates(target_user) then
    return;
  end if;

  insert into public.notifications (
    user_id, type, title, body, room_id, project_id, invitation_id, actor_id
  ) values (
    target_user, notif_type, notif_title, notif_body,
    target_room, target_project, target_invitation, notif_actor
  );
end;
$$;

revoke all on function private.notify_user(
  uuid, public.notification_type, text, text, uuid, uuid, uuid, uuid
) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Wire notify_user into the existing invite lifecycle.
-- ---------------------------------------------------------------------

-- Room-wide invite: now also resolves whether the invited email already has
-- an account and, if so, notifies them immediately instead of relying on
-- them noticing the pending row in their own Invites tab. Return type
-- widens from `text` to `jsonb` so the client knows whether to still show
-- the copy/paste code as a fallback. CREATE OR REPLACE can't change a
-- function's return type, so the old `text`-returning signature has to be
-- dropped first.
drop function if exists public.create_room_invitation(uuid, text, public.room_role);

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
  if private.room_role_for(target_room) <> 'owner' then
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

create or replace function public.accept_room_invitation_by_id(target_invitation uuid)
returns uuid
language plpgsql
security definer set search_path = public
as $$
declare
  selected public.invitations%rowtype;
  member_name text;
  room_name text;
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
  select display_name into member_name from public.profiles where id = auth.uid();
  insert into public.room_members (room_id, user_id, display_name, role)
  values (selected.room_id, auth.uid(), coalesce(member_name, 'Member'), selected.role)
  on conflict (room_id, user_id) do update
  set role = excluded.role, display_name = excluded.display_name;
  update public.invitations set status = 'accepted' where id = selected.id;

  select name into room_name from public.rooms where id = selected.room_id;
  perform private.notify_user(
    selected.invited_by,
    'invite_accepted',
    coalesce(member_name, 'Someone') || ' accepted your invite to ' || coalesce(room_name, 'your Room'),
    '',
    selected.room_id,
    null,
    selected.id,
    auth.uid()
  );

  return selected.room_id;
end;
$$;

create or replace function public.decline_room_invitation(target_invitation uuid)
returns void
language plpgsql
security definer set search_path = public
as $$
declare
  declined_invited_by uuid;
  declined_room_id uuid;
  room_name text;
  decliner_name text;
begin
  update public.invitations
  set status = 'declined'
  where id = target_invitation
    and status = 'pending'
    and lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  returning invited_by, room_id into declined_invited_by, declined_room_id;
  if not found then
    raise exception 'That invitation is no longer available.' using errcode = '22023';
  end if;

  select display_name into decliner_name from public.profiles where id = auth.uid();
  select name into room_name from public.rooms where id = declined_room_id;
  perform private.notify_user(
    declined_invited_by,
    'invite_declined',
    coalesce(decliner_name, 'Someone') || ' declined your invite to ' || coalesce(room_name, 'your Room'),
    '',
    declined_room_id,
    null,
    target_invitation,
    auth.uid()
  );
end;
$$;

-- Song-only invite: mirrors create_room_invitation's account-matching and
-- notification, same jsonb return shape. Same drop-first requirement as
-- above (return type changes from `text` to `jsonb`).
drop function if exists public.create_project_invitation(uuid, text, public.room_role);

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

create or replace function public.accept_project_invitation_by_id(target_invitation uuid)
returns uuid
language plpgsql
security definer set search_path = public
as $$
declare
  selected public.invitations%rowtype;
  member_name text;
  project_title text;
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

  select title into project_title from public.projects where id = selected.project_id;
  perform private.notify_user(
    selected.invited_by,
    'invite_accepted',
    coalesce(member_name, 'Someone') || ' accepted your invite to ' || coalesce(project_title, 'your song'),
    '',
    selected.room_id,
    selected.project_id,
    selected.id,
    auth.uid()
  );

  return selected.project_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Project updates: notify other members of a project's Room (both
-- room_members and project-only project_members) whenever someone adds a
-- lyric/note/section contribution.
--
-- Statement-level (not row-level): importContributions can insert up to
-- 500 rows in a single statement (bulk lyric-sheet import). A per-row
-- trigger would fire once per line and flood every other member's feed —
-- this fires once per INSERT statement instead, via a transition table, and
-- collapses a multi-row insert into a single "added N lines" notification
-- while keeping the normal one-line-at-a-time case as a specific preview.
-- ---------------------------------------------------------------------

create or replace function public.notify_project_update()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
declare
  row_count integer;
  first_project_id uuid;
  first_author_id uuid;
  first_author_name text;
  first_body text;
  target_room uuid;
  project_title text;
  notif_title text;
  notif_body text;
  member uuid;
begin
  select count(*), min(project_id), min(author_id), min(author_name)
    into row_count, first_project_id, first_author_id, first_author_name
    from new_rows;

  if row_count is null or row_count = 0 then
    return null;
  end if;

  select room_id, title into target_room, project_title
  from public.projects where id = first_project_id;

  if row_count = 1 then
    select body into first_body from new_rows limit 1;
    notif_title := coalesce(first_author_name, 'Someone') || ' added to ' || coalesce(project_title, 'a song');
    notif_body := left(coalesce(first_body, ''), 140);
  else
    notif_title := coalesce(first_author_name, 'Someone') || ' added ' || row_count || ' lines to '
      || coalesce(project_title, 'a song');
    notif_body := '';
  end if;

  for member in
    select user_id from public.room_members
    where room_id = target_room and user_id <> first_author_id
    union
    select user_id from public.project_members
    where project_id = first_project_id and user_id <> first_author_id
  loop
    perform private.notify_user(
      member,
      'project_update',
      notif_title,
      notif_body,
      target_room,
      first_project_id,
      null,
      first_author_id
    );
  end loop;

  return null;
end;
$$;

create trigger contributions_notify_project_update
after insert on public.contributions
referencing new table as new_rows
for each statement execute function public.notify_project_update();

revoke all on function public.notify_project_update() from public, anon, authenticated;

-- create_room_invitation/create_project_invitation were dropped and
-- recreated above (return type change), which resets their grants —
-- accept_room_invitation_by_id/accept_project_invitation_by_id/
-- decline_room_invitation only used CREATE OR REPLACE (same signature and
-- return type), so their existing grants from 0001/0013 still stand.
revoke all on function public.create_room_invitation(uuid, text, public.room_role) from public, anon;
revoke all on function public.create_project_invitation(uuid, text, public.room_role) from public, anon;
grant execute on function public.create_room_invitation(uuid, text, public.room_role) to authenticated;
grant execute on function public.create_project_invitation(uuid, text, public.room_role) to authenticated;
