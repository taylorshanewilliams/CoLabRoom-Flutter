-- Leaving a room takes its songs out of your sets.
--
-- A row in `setlist_projects` has outlived its owner's membership since the
-- day sets shipped: 0005's create policy asks that the set's owner be in the
-- song's room as the row goes in, and nothing has ever asked again. So
-- somebody leaves a band, or is removed from one, and their own sets go on
-- holding that band's songs -- with the key, the tempo, the count-in, the
-- form, the ending and the line for the stand-in that 0157 wrote on each of
-- those rows.
--
-- The songs could not be opened: every read of a song asks
-- `private.is_room_member` first, and 0164 guards its own read besides (a
-- set whose owner has left the room is handed to nobody, or a person who had
-- been removed could keep writing on the band's Home by re-dating an old
-- set). What was left was the record -- rows about a band, in a person's
-- list, after that band is nothing to do with them -- and a set that reads
-- as a list of songs, some of which do nothing when you tap them.
--
-- **The rule, decided 19 September 2026.** When a person stops being a
-- member of a room, that room's songs leave that person's sets, at that
-- moment. It is what a person would predict: a set is the songs you are
-- going to play, and those are songs you cannot. And it is the only answer
-- that keeps no record of a room after you have gone. Coming back adds them
-- again, which is the same two taps it was the first time.
--
-- **The set itself stays.** It is the person's own list, with their own name
-- on it, and a set that empties is a set with nothing in it rather than a
-- set somebody deleted. Its name and its day (0164) are untouched, because
-- neither of those is a fact about the room.
--
-- **Every way out, one rule.** Leaving (0062's `leave_room`), being removed
-- (`remove_room_member`, which `leave_room` calls), deleting an account
-- (0065 deletes the `auth.users` row, which cascades through `profiles` to
-- `room_members`) and deleting a room (which cascades to `room_members`
-- too) all end with a `room_members` row going. So the trigger is on that
-- row's deletion, and fires exactly once for each of them.
--
-- It cannot fight a cascade, because everything it deletes is a delete of
-- the same rows in the same transaction. A deleted room takes its songs,
-- and a deleted song takes its `setlist_projects` rows; whichever of those
-- and this trigger gets there first, the other finds the rows already gone
-- and removes what is left. Neither can error on the other.
--
-- **And a song that moves.** `moveProjects` updates `projects.room_id`
-- (0041), so a song can arrive in a room somebody is not in without their
-- membership changing at all. The same rule from the other side: when a song
-- moves, it leaves the sets of every owner who is not in the room it moved
-- to, and stays in the sets of those who are.
--
-- **No clean-up.** Production was read on 19 September 2026 and has no rows
-- this would have caught (0 of 5). A delete written here would be a delete
-- nobody could check, against rows nobody can see; from here the trigger
-- keeps it true.

-- Security definer, because this is usually not the departing person's own
-- delete. An owner removing somebody, and the cascade from a deleted account
-- or a deleted room, all run as somebody 0005's `setlist_projects` policies
-- would stop dead: those policies ask that the set be the caller's own.
create or replace function private.leaving_takes_the_songs_out_of_sets()
returns trigger
language plpgsql
security definer set search_path = ''
as $fn$
begin
  delete from public.setlist_projects sp
  using public.setlists s, public.projects p
  where sp.setlist_id = s.id
    and sp.project_id = p.id
    and s.owner_id = old.user_id
    and p.room_id = old.room_id;
  return old;
end;
$fn$;

revoke all on function private.leaving_takes_the_songs_out_of_sets()
  from public, anon, authenticated;

drop trigger if exists room_members_leaving_takes_the_songs on public.room_members;
create trigger room_members_leaving_takes_the_songs
after delete on public.room_members
for each row execute function private.leaving_takes_the_songs_out_of_sets();

-- The same rule for a song that changes rooms rather than a person who
-- changes rooms. `not exists` rather than a comparison, so a set whose owner
-- has no membership row at all is the case this catches rather than the case
-- it misses.
create or replace function private.a_moved_song_leaves_sets()
returns trigger
language plpgsql
security definer set search_path = ''
as $fn$
begin
  delete from public.setlist_projects sp
  using public.setlists s
  where sp.setlist_id = s.id
    and sp.project_id = new.id
    and not exists (
      select 1 from public.room_members m
      where m.room_id = new.room_id and m.user_id = s.owner_id
    );
  return new;
end;
$fn$;

revoke all on function private.a_moved_song_leaves_sets()
  from public, anon, authenticated;

drop trigger if exists projects_a_moved_song_leaves_sets on public.projects;
create trigger projects_a_moved_song_leaves_sets
after update of room_id on public.projects
for each row
when (new.room_id is distinct from old.room_id)
execute function private.a_moved_song_leaves_sets();
