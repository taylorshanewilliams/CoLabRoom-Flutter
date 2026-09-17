-- Somewhere to say "not now" to messages and calls.
--
-- The audit of 17 September 2026 found four notification switches (invites,
-- their answers, asks, new takes) and no way to quiet the two kinds most
-- likely to arrive often: a message, and "X started a call" in a room. Both
-- always notified and always pushed; the only way to stop a busy band thread
-- buzzing was to turn notifications off for the whole app, which also loses
-- the invitation that mattered.
--
-- Two switches, on by default, read by notify_user exactly as the others are.
-- Muting changes what is announced, not what exists: a message is still in
-- Messages with its unread count, and a call still shows on the room.
--
-- Older apps save the four switches they know about. An upsert only writes
-- the columns it sends, so they leave these two as they were.

alter table public.notification_preferences
  add column if not exists messages boolean not null default true,
  add column if not exists calls boolean not null default true;

comment on column public.notification_preferences.messages is
  'Whether to be told the moment somebody messages you, or says something in a room thread.';
comment on column public.notification_preferences.calls is
  'Whether to be told when somebody starts a call in one of your rooms.';

create or replace function private.wants_messages(target_user uuid)
returns boolean
language sql
stable
security definer set search_path = ''
as $fn$
  select coalesce(
    (select messages from public.notification_preferences where user_id = target_user),
    true
  );
$fn$;

revoke all on function private.wants_messages(uuid) from public, anon, authenticated;

create or replace function private.wants_calls(target_user uuid)
returns boolean
language sql
stable
security definer set search_path = ''
as $fn$
  select coalesce(
    (select calls from public.notification_preferences where user_id = target_user),
    true
  );
$fn$;

revoke all on function private.wants_calls(uuid) from public, anon, authenticated;

-- As 0132, with the two switches read.
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
as $fn$
begin
  if target_user is null or target_user = notif_actor then
    return;
  end if;

  if notif_type in ('invite_received', 'connection_request')
     and not private.wants_invites(target_user) then
    return;
  end if;
  if notif_type in ('invite_accepted', 'invite_declined', 'connection_accepted')
     and not private.wants_invite_responses(target_user) then
    return;
  end if;
  if notif_type = 'project_update' and not private.wants_project_updates(target_user) then
    return;
  end if;
  -- Somebody else's activity arriving uninvited, which is the category every
  -- other switch here covers.
  if notif_type = 'song_ask' and not private.wants_asks(target_user) then
    return;
  end if;
  -- 0136. Messages still arrive in Messages, and a call still shows on the
  -- room; these switches are about being told the moment it happens.
  if notif_type = 'direct_message' and not private.wants_messages(target_user) then
    return;
  end if;
  if notif_type = 'call_started' and not private.wants_calls(target_user) then
    return;
  end if;

  insert into public.notifications (
    user_id, type, title, body, room_id, project_id, invitation_id, actor_id
  ) values (
    target_user, notif_type, notif_title, notif_body,
    target_room, target_project, target_invitation, notif_actor
  );
end;
$fn$;

revoke all on function private.notify_user(
  uuid, public.notification_type, text, text, uuid, uuid, uuid, uuid
) from public, anon, authenticated;
