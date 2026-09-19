-- What came in: the takes students have sent their teacher.
--
-- Every Musician, Same Song, 17 September 2026, build-order slice 22: the
-- teacher's listening desk. "Mr. Okafor opens What came in. Only sent takes
-- appear." A hand-in has worked by construction since 0057 and 0129 -- a take
-- is private until its player shares it, and sharing in a lesson room tells
-- exactly one person -- but there has never been anywhere to hear the hand-ins
-- together. A teacher with nine students has been opening nine rooms.
--
-- So one read, across every lesson they teach, in one order: arrival. Not
-- alphabetically, which the schools design first suggested, and not by song:
-- a listening pass goes through what turned up, oldest first, and the thing
-- that turned up last is the thing at the end.
--
-- The rules, and they are the whole of it:
--
--   * Only the teacher of the lesson. The rows are reached through
--     lesson_rooms joined to the caller's own lesson_links (0129), so a
--     student calling this gets nothing -- not their own takes, and certainly
--     not a classmate's. There is no argument that says whose queue to read;
--     the answer is always the caller's.
--   * Only what was sent. `shared_at is not null` is the whole definition of
--     sent (0057), and it is also why a sealed take (0158) cannot appear:
--     sealing is refused on a take the room has heard, and sharing is refused
--     on a sealed one.
--   * Only the student's own playing. A teacher's demonstration recorded in
--     the lesson room is not a hand-in, and neither is anything an
--     accompanist invited into the room plays.
--   * A class room is not a lesson room. Students listen there and record in
--     their own room with the teacher (0148), and song_layers_insert_members
--     refuses a viewer a take in the first place -- but the join is what makes
--     that true here rather than a fact somebody has to remember.
--   * Nothing about when. The function orders by arrival and returns no
--     timestamp at all, so there is no date for a screen or an export to
--     print. No count comes back either, and there is no column for a score,
--     a tick or a "done" -- the plan forbids all three, and the way to keep
--     forbidding them is to have nowhere to put one.
--   * Nothing is written. Reading what a student sent leaves no mark on it,
--     so a student never finds out whether their teacher has listened yet.

-- The desk, in one read.
--
-- Security definer because the join is the permission: lesson_rooms shows a
-- row to its student as well as to the teacher (0129), and the caller being
-- the teacher of that lesson is what this function checks, rather than
-- leaving a phone to ask honestly.
--
-- storage_path comes back because the desk plays the take, and signing a path
-- is where the bucket's own policies apply (room_files_read_members): a
-- teacher owns the lesson room, so the object signs for them and for nobody
-- this function would not have listed anyway.
create or replace function public.takes_sent_to_me()
returns table (
  take_id uuid,
  project_id uuid,
  song_title text,
  student_id uuid,
  student_name text,
  storage_path text
)
language sql
stable
security definer set search_path = ''
as $fn$
  -- The newest two hundred, read back in arrival order. A cap because this
  -- is one read across a whole studio and takes are kept for months; two
  -- hundred is far past a term's listening and the mildest way for a read to
  -- run out, since what falls off is what was heard longest ago.
  select newest.take_id, newest.project_id, newest.song_title,
         newest.student_id, newest.student_name, newest.storage_path
  from (
    select l.id as take_id,
           p.id as project_id,
           p.title as song_title,
           lr.student_id as student_id,
           coalesce(
             nullif(trim(rm.display_name), ''),
             nullif(trim(pr.display_name), ''),
             'A student'
           ) as student_name,
           l.storage_path as storage_path,
           l.shared_at as sent_at
    from public.lesson_rooms lr
    join public.lesson_links link on link.id = lr.link_id
    join public.projects p
      on p.room_id = lr.room_id and p.deleted_at is null
    join public.song_layers l on l.project_id = p.id
    -- What the room calls them, which is what the teacher reads everywhere
    -- else in the app; their profile name if the room never got one.
    left join public.room_members rm
      on rm.room_id = lr.room_id and rm.user_id = lr.student_id
    left join public.profiles pr on pr.id = lr.student_id
    -- A link that has been turned off is joined all the same, as 0143, 0149
    -- and 0150 join it: a teacher who took their poster down still teaches
    -- the people who scanned it.
    where link.teacher_id = auth.uid()
      -- And still owns the room the lesson happens in. Said here because
      -- this function runs as its owner, so nothing else would say it.
      and private.room_role_for(lr.room_id) = 'owner'
      and l.recorded_by = lr.student_id
      and l.shared_at is not null
      -- Somebody either of them has blocked is skipped rather than refused,
      -- as 0149 and 0150 skip them: it is still the teacher's room, there is
      -- just nobody in it they are hearing from.
      and not private.blocked_between(auth.uid(), lr.student_id)
    order by l.shared_at desc, l.id desc
    limit 200
  ) newest
  order by newest.sent_at, newest.take_id;
$fn$;

comment on function public.takes_sent_to_me() is
  'What students have sent their teacher, across every lesson they teach, '
  'oldest first. Every Musician, Same Song, 17 September 2026. No dates, no '
  'counts, and nowhere to put a score.';

revoke all on function public.takes_sent_to_me() from public, anon;
grant execute on function public.takes_sent_to_me() to authenticated;
