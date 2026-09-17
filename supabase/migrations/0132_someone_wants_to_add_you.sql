-- Somebody wants to add you.
--
-- 16 September 2026. Scanning somebody's code (0130) sends a connection
-- request, and until now nothing told the person asked. They found out only
-- if their code was still on their screen, or the next time they happened to
-- open Your people. At a gig the phone goes back in the pocket the moment the
-- other person has scanned it, so the request sat there unseen, and the
-- "scan each other's codes" moment quietly became "scan, and hope".
--
-- So a request tells the person asked, and a yes tells the person who asked.
-- Both are written by triggers on `connections`, not by the functions that
-- write it: request_connection, respond_to_connection and anything added later
-- all get the same behaviour without remembering to (0093's rule).
--
-- Three guards, because a notification about a person is the kind somebody
-- can use to pester:
--
--   * Once a day per pair. Requesting, withdrawing and requesting again is
--     three taps, and without this it would be a push every time. Kept in its
--     own record, since withdrawing removes the inbox card.
--   * Blocking wins. request_connection already refuses, but the trigger checks
--     again rather than trusting every future writer.
--   * A request that is answered, withdrawn or declined takes its card with it.
--     "Sam wants to add you" still sitting in the inbox after you added Sam
--     is a card asking you to do something already done.
--
-- They ride the invitation switches (0018): a request is somebody inviting
-- you to be one of their people, and a yes is the answer to your invitation.

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

-- When a pair's request was last announced. Its own record rather than a
-- look at the inbox, because the inbox card goes away when a request is
-- withdrawn -- and request, withdraw, request would otherwise be a push each
-- time.
create table if not exists private.connection_requests_told (
  requester_id uuid not null references public.profiles(id) on delete cascade,
  addressee_id uuid not null references public.profiles(id) on delete cascade,
  told_at timestamptz not null default now(),
  primary key (requester_id, addressee_id)
);

revoke all on table private.connection_requests_told from public, anon, authenticated;
alter table private.connection_requests_told enable row level security;

create or replace function private.announce_connection()
returns trigger
language plpgsql
security definer set search_path = ''
as $fn$
declare
  asker_name text;
  answerer_name text;
begin
  if private.blocked_between(new.requester_id, new.addressee_id) then
    return new;
  end if;

  select coalesce(nullif(trim(p.display_name), ''), 'Somebody') into asker_name
  from public.profiles p where p.id = new.requester_id;
  select coalesce(nullif(trim(p.display_name), ''), 'Somebody') into answerer_name
  from public.profiles p where p.id = new.addressee_id;

  if tg_op = 'INSERT' and new.state = 'pending' then
    if exists (
      select 1 from private.connection_requests_told t
      where t.requester_id = new.requester_id
        and t.addressee_id = new.addressee_id
        and t.told_at > now() - interval '1 day'
    ) then
      return new;
    end if;
    insert into private.connection_requests_told (requester_id, addressee_id)
    values (new.requester_id, new.addressee_id)
    on conflict (requester_id, addressee_id) do update set told_at = now();
    perform private.notify_user(
      new.addressee_id,
      'connection_request',
      asker_name || ' wants to add you',
      'Add them back and you are connected.',
      null, null, null,
      new.requester_id
    );
  elsif tg_op = 'UPDATE' and old.state = 'pending' and new.state = 'accepted' then
    delete from public.notifications n
    where n.user_id = new.addressee_id
      and n.actor_id = new.requester_id
      and n.type = 'connection_request';
    perform private.notify_user(
      new.requester_id,
      'connection_accepted',
      'You and ' || answerer_name || ' are connected',
      answerer_name || ' is one of your people now.',
      null, null, null,
      new.addressee_id
    );
  end if;
  return new;
end;
$fn$;

revoke all on function private.announce_connection() from public, anon, authenticated;

drop trigger if exists connections_announce on public.connections;
create trigger connections_announce
after insert or update of state on public.connections
for each row execute function private.announce_connection();

-- A request that ends without a yes -- declined, withdrawn, or either of
-- them removing the other -- takes its card out of the inbox.
create or replace function private.forget_connection_request()
returns trigger
language plpgsql
security definer set search_path = ''
as $fn$
begin
  delete from public.notifications n
  where n.type = 'connection_request'
    and ((n.user_id = old.addressee_id and n.actor_id = old.requester_id)
      or (n.user_id = old.requester_id and n.actor_id = old.addressee_id));
  return old;
end;
$fn$;

revoke all on function private.forget_connection_request() from public, anon, authenticated;

drop trigger if exists connections_forget_request on public.connections;
create trigger connections_forget_request
after delete on public.connections
for each row execute function private.forget_connection_request();
