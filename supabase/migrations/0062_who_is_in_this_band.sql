-- Who is in this catalog, and what happens when somebody leaves the band.
--
-- A catalog has said "3 members" since the day it shipped and has never been
-- able to say *which* three. Worse, there has been no way to change it: the
-- app can add people and has never been able to remove one. Bands are not
-- permanent — somebody leaves, somebody was added by mistake, somebody was a
-- session player for one record — and an app where membership only ever grows
-- is an app whose owners eventually stop adding anybody.
--
-- Two ways out, because they are different things:
--
--   * **The owner removes somebody.** Their decision, about their catalog.
--   * **Somebody leaves on their own.** Nobody should need permission to stop
--     being in a band, and an owner who could trap people in a catalog is a
--     worse problem than an owner who loses a member.
--
-- Removal takes the project-scoped memberships with it. Somebody taken out of
-- a catalog who kept an editor row on four of its songs has not been removed;
-- they have been removed from the list that displays them, which is the shape
-- of permission bug nobody notices until it matters.

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
  if not (private.room_role_for(target_room) = 'owner'
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

revoke all on function public.remove_room_member(uuid, uuid) from public, anon;
grant execute on function public.remove_room_member(uuid, uuid) to authenticated;

-- Leaving. The same code path, said in the words of the person doing it.
create or replace function public.leave_room(target_room uuid)
returns void
language sql
security invoker
set search_path = public
as $$
  select public.remove_room_member(target_room, auth.uid());
$$;

revoke all on function public.leave_room(uuid) from public, anon;
grant execute on function public.leave_room(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Inviting somebody you met, rather than somebody you have the email of
-- ---------------------------------------------------------------------

-- The existing invitations table is keyed on an email address and a token,
-- which is right for "send my bandmate a link" and useless for "I found this
-- drummer in Open Mic". You do not have a stranger's email, you have their
-- profile — and asking for their address in order to invite them would be
-- asking them to hand it over to somebody they have not agreed to work with.
--
-- A separate table rather than a column on `invitations`, deliberately. That
-- table's accept path is the one that broke before, where only the first
-- invitee to a catalog could ever join; widening it to take a second kind of
-- match would put a working join flow back in play for a feature that does
-- not need to touch it.
--
-- Same consent shape as an ask: sending this grants nothing at all.
create table if not exists public.room_invites (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  invited_by uuid not null default auth.uid()
    references public.profiles(id) on delete cascade,
  invited_profile uuid not null references public.profiles(id) on delete cascade,

  note text not null default '' check (char_length(note) <= 280),
  role public.room_role not null default 'editor',
  status text not null default 'open'
    check (status in ('open', 'accepted', 'declined', 'withdrawn')),

  created_at timestamptz not null default now(),
  answered_at timestamptz
);

-- One open invite per person per catalog, for the same reason the ask has
-- one: this is a cap on what somebody can be made to read, not on the sender.
create unique index if not exists room_invites_one_open_per_person
  on public.room_invites (room_id, invited_profile)
  where status = 'open';

alter table public.room_invites enable row level security;

-- The person invited, and the people already in the catalog. Nobody else.
drop policy if exists room_invites_read on public.room_invites;
create policy room_invites_read on public.room_invites
for select to authenticated using (
  invited_profile = (select auth.uid())
  or private.is_room_member(room_id)
);

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

  if private.room_role_for(target_room) <> 'owner' then
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

  -- The enum from 0018 already had the right word for each direction, which
  -- is better than one generic 'invitation' for all three: somebody reading
  -- their inbox wants "you were invited" and "they joined" to be different
  -- kinds of thing, and the client already styles them differently.
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

revoke all on function public.invite_musician_to_room(uuid, uuid, text)
  from public, anon;
grant execute on function public.invite_musician_to_room(uuid, uuid, text)
  to authenticated;

-- The only thing here that grants anything, callable only by the person
-- invited.
create or replace function public.answer_room_invite(
  target_invite uuid,
  accept boolean
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  the_invite public.room_invites%rowtype;
  my_name text;
  room_name text;
begin
  select * into the_invite
  from public.room_invites
  where id = target_invite
  for update;

  if the_invite.id is null
     or the_invite.invited_profile is distinct from auth.uid() then
    raise exception 'That invitation is not yours to answer.'
      using errcode = '42501';
  end if;

  if the_invite.status <> 'open' then
    return the_invite.room_id;
  end if;

  select display_name into my_name from public.profiles where id = auth.uid();
  select name into room_name from public.rooms where id = the_invite.room_id;

  if accept then
    -- No colour named here on purpose. The trigger from 0047 assigns one
    -- under an advisory lock, which is what stopped a second person joining
    -- a catalog from colliding with the first — the bug a real tester hit.
    insert into public.room_members (room_id, user_id, display_name, role)
    values (the_invite.room_id, auth.uid(), coalesce(my_name, 'Member'),
            the_invite.role)
    on conflict (room_id, user_id) do nothing;
  end if;

  update public.room_invites
  set status = case when accept then 'accepted' else 'declined' end,
      answered_at = now()
  where id = target_invite;

  perform private.notify_user(
    the_invite.invited_by,
    -- Cast spelled out: a CASE over two literals is text, and text does not
    -- implicitly become an enum the way a bare literal does.
    (case when accept then 'invite_accepted' else 'invite_declined' end)
      ::public.notification_type,
    coalesce(my_name, 'Somebody') ||
      case when accept then ' joined ' else ' passed on ' end ||
      coalesce(room_name, 'your catalog'),
    case when accept then 'They can see its songs now.' else '' end,
    the_invite.room_id,
    null,
    null,
    auth.uid()
  );

  return the_invite.room_id;
end;
$$;

revoke all on function public.answer_room_invite(uuid, boolean) from public, anon;
grant execute on function public.answer_room_invite(uuid, boolean) to authenticated;

-- Catalog invitations aimed at you by name, for the inbox.
create or replace function public.room_invites_for_me()
returns table (
  id uuid,
  room_id uuid,
  room_name text,
  invited_by uuid,
  invited_by_name text,
  note text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    i.id,
    i.room_id,
    r.name,
    i.invited_by,
    pr.display_name,
    i.note,
    i.created_at
  from public.room_invites i
  join public.rooms r on r.id = i.room_id
  left join public.profiles pr on pr.id = i.invited_by
  where i.invited_profile = (select auth.uid())
    and i.status = 'open'
  order by i.created_at desc;
$$;

revoke all on function public.room_invites_for_me() from public, anon;
grant execute on function public.room_invites_for_me() to authenticated;

-- Catalogs you own that you could invite somebody into, and whether you
-- already have. Same reason `songs_i_can_offer` reports it: a row greyed out
-- with a reason beats a row that silently is not there.
create or replace function public.rooms_i_can_invite_to(target_person uuid)
returns table (
  id uuid,
  name text,
  song_count bigint,
  already_in boolean,
  already_invited boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select
    r.id,
    r.name,
    (select count(*) from public.projects p where p.room_id = r.id),
    exists (
      select 1 from public.room_members m
      where m.room_id = r.id and m.user_id = target_person
    ),
    exists (
      select 1 from public.room_invites i
      where i.room_id = r.id
        and i.invited_profile = target_person
        and i.status = 'open'
    )
  from public.rooms r
  where r.account_id = (select auth.uid())
  order by r.name;
$$;

revoke all on function public.rooms_i_can_invite_to(uuid) from public, anon;
grant execute on function public.rooms_i_can_invite_to(uuid) to authenticated;
