-- A set for a day, and one quiet card for each of you.
--
-- Every Musician, Same Song, 17 September 2026, worship teams item 2: "the
-- dated set practised during the week, with one quiet card per member.
-- Leaders never see who opened it." A set here is a running order and,
-- since 0157, what the band does with each song. What it could not say is
-- *when* -- and without that there is no week to practise in, so the person
-- who is on Sunday morning finds out what they are playing on Sunday
-- morning.
--
-- **The day is a date, not a countdown.** A `date` and not a timestamp,
-- because a day is a day wherever the phone is: a set for the fourth of
-- October is for the fourth of October in the van and at the airport. The
-- app says it as a weekday, or "Sunday 4 October" when a weekday alone
-- would not say which, and never as a number of days left. Nothing counts
-- down in this app (Every Musician, Same Song: no badges, streaks, counts or
-- durations), and a set that says "2 days" is a set that nags.
--
-- **No check on it.** A day in the past is a true thing for a set to say --
-- last Sunday's set is still last Sunday's -- and how long before the day a
-- card appears is a question about somebody's Home, answered on their phone
-- where their own calendar is, not here.
--
-- **Whose it is.** The set's owner's, the way the set is, and the way 0157's
-- six columns are. 0005's `setlists_update_owner` already lets only the
-- owner of the set write the row, so there is no new policy here and no
-- function: an update from anybody else lands on no row.
--
-- **Who may read it.** Only the owner could read a set at all (0005's
-- `setlists_read_owner`), which is right for a private list and wrong for
-- the one thing this slice is for: the people playing it have to be able to
-- see that there is a set on Sunday. `sets_for_the_day` below answers that
-- one question and nothing else. It is a function rather than a read policy
-- on `setlists` for two reasons. A policy would have to look at
-- `setlist_projects` to find out which rooms a set touches, and that table's
-- own read policy asks for the set's owner, so the policy would be circular
-- and answer false for exactly the people it is for. And a policy would
-- widen every existing read: `loadSetlists` selects `setlists` with no owner
-- filter and leans on RLS, so the Sets tab would quietly fill up with other
-- people's sets.
--
-- **Nobody can see who opened it.** There is no receipt here: no opened_at,
-- no row written when the card is tapped, and no function that could be
-- asked. `sets_for_the_day` is `stable`, so it could not write one if it
-- tried. That is the promise in the plan -- "Leaders never see who opened
-- it" -- and it is kept by there being nothing to read rather than by a
-- rule about reading it.
--
-- **Covered songs.** Nothing new leaks. A song marked somebody else's (0142)
-- stays in the set for its sheet and its key, which is what the CCLI
-- Rehearsal Licence finding in the plan allows; the card opens what the room
-- may already hear, through the same reads the room already has. This
-- function hands back no audio, no words and no path -- a song's id, its
-- place in the running order, and the key the set does it in.

alter table public.setlists
  add column if not exists for_day date;

comment on column public.setlists.for_day is
  'The day this set is for. Null means it is not for a day -- a list of '
  'songs rather than an occasion -- which is what every set was before '
  'this. Set by the set''s owner through 0005''s update policy.';

-- Which dated sets are waiting for the person asking, and what is in them.
--
-- One row per song they may see. A set that mixes rooms hands back only the
-- songs from the rooms they are in, which is the 0005 read policy's rule
-- said again here: being handed a set is not being handed the songs in it.
-- Somebody in none of the rooms is handed nothing at all, including the
-- set's name.
--
-- **And whoever made the set has to still be in the room.** A set is joined
-- to a room's song by a row in `setlist_projects`, and nothing takes those
-- rows away when somebody leaves a band or is removed from it: 0005 checks
-- membership as the row goes in and never again. Without the check below, a
-- person who had been removed from a room could still put a line of their
-- own writing -- the set's name -- on every member's Home, every week, by
-- re-dating an old set of theirs. Being removed from a room is supposed to
-- end what you can put in front of it, so the set of somebody who is no
-- longer in the room is not handed to anybody, and the room stops hearing
-- from them the moment they are out.
--
-- Blocking counts too, the way it does in every other read that carries
-- somebody's words (0063's `blocked_between`, either direction). Somebody
-- you have blocked does not get a card on your Home with their sentence on
-- it, even if the two of you are still in the same room.
--
-- From yesterday onwards, not from today: the day is a calendar date and
-- `current_date` here is the server's, which can be tomorrow already for a
-- phone in Auckland and still yesterday for one in Honolulu. The phone
-- decides whether its own card is still for a day to come; this only avoids
-- handing back a year of old sets.
drop function if exists public.sets_for_the_day();

create function public.sets_for_the_day()
returns table (
  set_id uuid,
  owner_id uuid,
  set_name text,
  for_day date,
  created_at timestamptz,
  updated_at timestamptz,
  project_id uuid,
  -- Not `position`: `position` is a keyword Postgres will not take as a
  -- returns-table column name, and a set is about the running order anyway.
  running_order integer,
  played_key text
)
language sql
stable
security definer set search_path = ''
as $fn$
  select s.id, s.owner_id, s.name, s.for_day, s.created_at, s.updated_at,
         sp.project_id, sp.position, sp.played_key
  from public.setlists s
  join public.setlist_projects sp on sp.setlist_id = s.id
  join public.projects p on p.id = sp.project_id and p.deleted_at is null
  join public.rooms r on r.id = p.room_id and r.deleted_at is null
  where s.for_day is not null
    and s.for_day >= current_date - 1
    and private.is_room_member(p.room_id)
    and exists (
      select 1 from public.room_members m
      where m.room_id = p.room_id and m.user_id = s.owner_id
    )
    and not private.blocked_between((select auth.uid()), s.owner_id)
  order by s.for_day, s.id, sp.position, sp.project_id;
$fn$;

revoke all on function public.sets_for_the_day() from public, anon;
grant execute on function public.sets_for_the_day() to authenticated;
