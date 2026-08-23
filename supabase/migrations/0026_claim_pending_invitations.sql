-- An invite sent before someone signs up should be waiting for them when
-- they do.
--
-- Until now it wasn't. create_room_invitation looks up auth.users at the
-- moment the invite is created: if there's an account it notifies them, and
-- if there isn't it hands back a code to pass along by hand. Nothing ever
-- revisited that decision. Sign up an hour later with the exact email you
-- were invited at, and the pending invitation just sat there — you had to be
-- told about the code, find Invites, and paste it.
--
-- That is the wrong half of the flow to leave manual, because inviting
-- someone who hasn't joined yet is the *normal* case when a band is coming
-- onto the app for the first time.
--
-- So the lookup now also runs from the other side: when a profile is created,
-- any pending invitation addressed to that email becomes a notification, and
-- the new arrival opens the app already invited.

create or replace function private.claim_pending_invitations()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
declare
  signup_email text;
  pending record;
  invite_target text;
  inviter_name text;
begin
  select lower(trim(u.email)) into signup_email
  from auth.users u
  where u.id = new.id;
  if signup_email is null or signup_email = '' then
    return new;
  end if;

  for pending in
    select i.id, i.room_id, i.project_id, i.invited_by
    from public.invitations i
    where lower(trim(i.email)) = signup_email
      and i.status = 'pending'
      and i.expires_at > now()
  loop
    select p.display_name into inviter_name
    from public.profiles p
    where p.id = pending.invited_by;

    -- Same wording the two create_*_invitation functions use, so an invite
    -- claimed at signup is indistinguishable from one that arrived live.
    if pending.project_id is not null then
      select pr.title into invite_target
      from public.projects pr
      where pr.id = pending.project_id;
      invite_target := coalesce(invite_target, 'a song');
    else
      select r.name into invite_target
      from public.rooms r
      where r.id = pending.room_id;
      invite_target := coalesce(invite_target, 'a Room');
    end if;

    perform private.notify_user(
      new.id,
      'invite_received',
      coalesce(inviter_name, 'A collaborator') || ' invited you to ' || invite_target,
      'Open Invites to accept or decline.',
      pending.room_id,
      pending.project_id,
      pending.id,
      pending.invited_by
    );
  end loop;

  return new;
exception
  -- Never, under any circumstances, let this stop an account being created.
  -- A missed notification is a nuisance; a signup that fails because a
  -- room was deleted mid-invite is somebody unable to use the app at all.
  -- The invitation itself is untouched either way, so the code path still
  -- works as the fallback it always was.
  when others then
    return new;
end;
$$;

revoke all on function private.claim_pending_invitations() from public, anon, authenticated;

-- On profiles rather than on auth.users, which is where the equivalent
-- profile-creating trigger lives. notifications.user_id references
-- profiles(id), so hanging this off the profile row means the row it depends
-- on is guaranteed to exist rather than depending on two triggers on the same
-- table firing in the right order.
drop trigger if exists claim_pending_invitations_on_profile on public.profiles;
create trigger claim_pending_invitations_on_profile
after insert on public.profiles
for each row execute function private.claim_pending_invitations();
