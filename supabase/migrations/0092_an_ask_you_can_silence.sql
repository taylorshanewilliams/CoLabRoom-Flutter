-- An ask you can silence.
--
-- `notification_preferences` covers three types and there are seven. Two of
-- the missing four are deliberate and 0035 explains why: `analysis_ready` and
-- `help_answered` are results of something you personally started, so
-- silencing them would mean the app quietly not telling you the thing you
-- asked for.
--
-- `song_ask` is not that. It is somebody else's activity arriving uninvited —
-- a stranger from the Open Mic asking you to play on their song — which is
-- exactly the category the other three switches exist for, and it is the one
-- with no switch. It is also the type most likely to arrive often if this app
-- works: the whole design points at more people asking each other for help.
--
-- Somebody who finds it too much has two options today: turn off every
-- notification at the operating system, or stop being discoverable. Both are
-- much bigger than "not this one", and both cost them the app.
--
-- And silencing it loses nobody an ask. An ask made *of* a particular person
-- is a `project_asks` row they can read (0061), and the Inbox draws those
-- from `asks_for_me` rather than from the notifications table — so turning
-- this off stops the interruption and not the request. That is what makes it
-- safe to offer at all; a switch that quietly dropped other people's requests
-- on the floor would be a worse thing than the noise it fixed.

alter table public.notification_preferences
  add column if not exists asks boolean not null default true;

comment on column public.notification_preferences.asks is
  'Whether to be told when somebody asks you to play on a song. Other '
  'people''s activity arriving uninvited, so it gets a switch — unlike '
  'analysis_ready and help_answered, which are answers to things you started.';

create or replace function private.wants_asks(target_user uuid)
returns boolean
language sql
stable
security definer set search_path = ''
as $fn$
  select coalesce(
    (select asks from public.notification_preferences where user_id = target_user),
    true
  );
$fn$;

revoke all on function private.wants_asks(uuid)
  from public, anon, authenticated;

-- And notify_user honours it.
--
-- Re-declared whole rather than patched, because this is the one function
-- every notification in the app goes through and it must be readable in one
-- piece. The three existing checks are unchanged.
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
  -- The new one. Somebody else's activity arriving uninvited, which is the
  -- category every other switch here covers.
  if notif_type = 'song_ask' and not private.wants_asks(target_user) then
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
