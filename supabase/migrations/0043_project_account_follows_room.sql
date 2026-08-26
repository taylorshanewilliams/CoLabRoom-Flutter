-- A song's account must be the account that owns the room it sits in.
--
-- The insert policy has always required it:
--
--   exists (select 1 from public.rooms
--           where id = room_id and account_id = projects.account_id)
--
-- but moveProjects updates only room_id, and the *update* policy checks
-- nothing but the mover's role. So moving a song into a room owned by a
-- different account left projects.account_id pointing at the previous
-- owner — a row the database would have refused to create directly, reached
-- by editing one it had already accepted.
--
-- That matters for more than tidiness. projects_account_title_unique is keyed
-- on (account_id, title), so a stale account_id guards the wrong person's
-- titles: two songs called the same thing can coexist, which is how one band
-- ended up with two "Ladder Of Life" projects and no warning.
--
-- Enforced with a trigger rather than by fixing the one caller, because the
-- invariant belongs to the data. A second caller written a year from now
-- cannot get this wrong, and neither can a hand-run statement.

create or replace function public.projects_account_follows_room()
returns trigger
language plpgsql
-- Reads public.rooms, which is itself behind RLS. Definer so the invariant
-- does not depend on the mover being able to *see* the room row through a
-- policy — they have already been authorised to move into it by the time
-- this runs.
security definer
set search_path = public
as $$
begin
  select r.account_id into new.account_id
  from public.rooms r
  where r.id = new.room_id;

  if new.account_id is null then
    raise exception 'room % does not exist', new.room_id;
  end if;

  return new;
end;
$$;

revoke all on function public.projects_account_follows_room() from public, anon;

drop trigger if exists projects_account_follows_room on public.projects;
create trigger projects_account_follows_room
before insert or update of room_id on public.projects
for each row execute function public.projects_account_follows_room();

-- The rows already drifted, if any. Written before the trigger can help them
-- and left correct afterwards.
--
-- This can fail where a song's title already exists on the account it is
-- about to belong to — the unique index doing, late, the job it was supposed
-- to do at the time. That is a genuine collision needing a human to rename
-- one of them, not something to paper over, so it is left to raise.
update public.projects p
set account_id = r.account_id
from public.rooms r
where r.id = p.room_id
  and p.account_id is distinct from r.account_id;
