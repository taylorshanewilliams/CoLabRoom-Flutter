-- Joining a Room by invitation failed for the second person to try it, in
-- every Room, since 0018.
--
-- 0006 added `room_members_room_color_unique` on (room_id, color_value) so
-- the shared editor could tell one person's cursor from another's, and taught
-- `accept_room_invitation_by_id` to pick an unused colour from a palette
-- before inserting. 0018 rewrote that same function to send an
-- `invite_accepted` notification and, in doing so, dropped the palette block
-- along with the `color_value` in the insert column list. The row then took
-- the table default (4294957644) — so the first person to accept an invite to
-- a Room got the default and succeeded, and every person after them collided
-- with it:
--
--   duplicate key value violates unique constraint
--   "room_members_room_color_unique"
--
-- Production on 2026-09-05 shows exactly that shape: South Dean has three
-- members, one of whom holds 4294957644, and the fourth account signed up,
-- was invited repeatedly, and could not get in.
--
-- Restoring the palette block inside that one function would fix today's bug
-- and leave the trap: three call sites insert into room_members, two of them
-- omit color_value, and nothing stops the next `create or replace` from
-- dropping it again exactly as 0018 did. So put the colour choice where it
-- cannot be left out — a BEFORE INSERT trigger — and let every path, present
-- and future, be correct by construction.
--
-- The other half of the decision: **a colour must never block a join.** The
-- palette holds ten and a Room can hold more people than that; 0006 would
-- `raise exception 'This Room has no unused collaborator colors available.'`
-- and refuse the membership. Membership is the product, the colour is
-- decoration, so past the palette this picks the next free value instead of
-- failing.

create or replace function private.member_colour_palette()
returns bigint[]
language sql
immutable
as $$
  -- 0006's palette, unchanged: ten hues that stay apart from each other on
  -- the bullet rail and on a cursor.
  select array[
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
$$;

revoke all on function private.member_colour_palette() from public, anon, authenticated;

create or replace function private.room_members_assign_colour()
returns trigger
-- SECURITY DEFINER because the whole question is "what colours does this Room
-- already use", and the person asking is by definition not a member yet. Under
-- the caller's RLS they can see none of the existing rows, would find every
-- colour free, and would pick a colliding one — the bug this replaces, wearing
-- a different hat.
language plpgsql
security definer set search_path = ''
as $$
declare
  existing bigint;
  chosen bigint;
begin
  -- Two people accepting invitations to the same Room in the same instant
  -- would otherwise both read the same set of taken colours, both pick the
  -- same free one, and one of them would hit the very unique violation this
  -- trigger exists to prevent. 0006 serialised this with a table lock over
  -- every Room at once; an advisory lock keyed on the Room holds only the
  -- Room, for the rest of the transaction, and is released whatever happens
  -- to it.
  perform pg_advisory_xact_lock(
    hashtext('room_members_colour:' || new.room_id::text));

  -- Already in this Room: keep the colour they have. This insert is a
  -- re-accept, and the ON CONFLICT behind it is about to become an UPDATE
  -- that leaves colour alone anyway. Reassigning here would change somebody's
  -- cursor colour mid-session for no reason.
  select rm.color_value into existing
  from public.room_members rm
  where rm.room_id = new.room_id
    and rm.user_id = new.user_id;
  if existing is not null then
    new.color_value := existing;
    return new;
  end if;

  -- Honour the colour the caller asked for when the Room isn't using it. The
  -- app writes its own colour for the owner row at Room creation, and that is
  -- a deliberate choice worth keeping.
  if new.color_value is not null and not exists (
    select 1 from public.room_members rm
    where rm.room_id = new.room_id
      and rm.color_value = new.color_value
  ) then
    return new;
  end if;

  select c.candidate into chosen
  from unnest(private.member_colour_palette())
    with ordinality as c(candidate, priority)
  where not exists (
    select 1 from public.room_members rm
    where rm.room_id = new.room_id
      and rm.color_value = c.candidate
  )
  order by c.priority
  limit 1;

  if chosen is null then
    -- Eleventh member and beyond. Walk up from opaque black until something
    -- is free rather than refusing the join. Terminates for any Room a band
    -- can produce, and the value is still a valid opaque ARGB.
    chosen := 4278190080; -- FF000000
    while exists (
      select 1 from public.room_members rm
      where rm.room_id = new.room_id
        and rm.color_value = chosen
    ) loop
      chosen := chosen + 1;
    end loop;
  end if;

  new.color_value := chosen;
  return new;
end;
$$;

drop trigger if exists room_members_assign_colour on public.room_members;
create trigger room_members_assign_colour
before insert on public.room_members
for each row execute function private.room_members_assign_colour();

-- project_members has the same `default 4294957644` and the same three-column
-- insert, and differs only in having no unique index to fail on — so instead
-- of an error, every member of a project-scoped invite has silently been the
-- same colour as every other one. Same trigger, same reason.
create or replace function private.project_members_assign_colour()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
declare
  existing bigint;
  chosen bigint;
begin
  perform pg_advisory_xact_lock(
    hashtext('project_members_colour:' || new.project_id::text));

  select pm.color_value into existing
  from public.project_members pm
  where pm.project_id = new.project_id
    and pm.user_id = new.user_id;
  if existing is not null then
    new.color_value := existing;
    return new;
  end if;

  if new.color_value is not null and not exists (
    select 1 from public.project_members pm
    where pm.project_id = new.project_id
      and pm.color_value = new.color_value
  ) then
    return new;
  end if;

  select c.candidate into chosen
  from unnest(private.member_colour_palette())
    with ordinality as c(candidate, priority)
  where not exists (
    select 1 from public.project_members pm
    where pm.project_id = new.project_id
      and pm.color_value = c.candidate
  )
  order by c.priority
  limit 1;

  if chosen is null then
    chosen := 4278190080;
    while exists (
      select 1 from public.project_members pm
      where pm.project_id = new.project_id
        and pm.color_value = chosen
    ) loop
      chosen := chosen + 1;
    end loop;
  end if;

  new.color_value := chosen;
  return new;
end;
$$;

drop trigger if exists project_members_assign_colour on public.project_members;
create trigger project_members_assign_colour
before insert on public.project_members
for each row execute function private.project_members_assign_colour();

-- The table defaults stay as they are. They are now only a starting
-- suggestion the trigger is free to overrule, which is the one job a default
-- can safely hold here.
