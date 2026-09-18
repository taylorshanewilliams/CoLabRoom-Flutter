-- A room for a class.
--
-- Every Musician, Same Song, 17 September 2026: build-order slice 16, and
-- the first piece of the school program. Several named links, and a minimal
-- class room where viewers cannot post takes.
--
-- 0129 gave a teacher one open lesson link, and every scan of it made a
-- private two-person room. That is right for a studio of one-to-one
-- lessons and wrong the moment a teacher runs two of anything: Tuesday
-- beginners and the jazz combo cannot share a poster, because the poster's
-- title names every room it makes. Three things change.
--
--   * A teacher can keep several links open at once, each with a name they
--     chose, so a student lands in "Tuesday beginners · Jess" rather than in
--     whatever the one link was called that week. Eight open at a time is
--     the cap: enough for a timetable, few enough that a teacher can still
--     say which poster is which. The one-open index goes. Turning a link off
--     stays, one at a time -- or all of them, for a build that predates this
--     and still calls close_lesson_link with nothing.
--
--   * A link can belong to a class. The class room is one room the teacher
--     owns, named for the link, holding what the whole class listens to: the
--     director's recordings of the parts, the songs being worked on. Opening
--     a class link puts the student in the class room as a viewer and makes
--     their own two-person lesson room in the same step. They record in
--     their own room, never in front of the class. A class turned off keeps
--     its room, and turned on again is the same room: a switch flipped twice
--     on a phone must not split a class between two rooms. A fresh room is
--     made only when the old one is gone.
--
--   * A viewer listens and talks and does nothing else, in SQL. The role has
--     existed since 0001 and every policy on songs and words already keeps
--     it out; takes never did (0038 checks membership and not role), and
--     neither did the storage path the audio arrives through (0041). Both
--     now refuse a viewer. That reaches every room with a viewer in it, not
--     only class rooms, and on purpose: "viewer" is what the role is called,
--     and a band that gave somebody that word did not mean "can put audio on
--     our song". Owners and editors are untouched.
--
-- What this does not do. It counts nothing about a student: my_lesson_links
-- carries how many people joined each link, and the app says only whether
-- anybody has -- no number on any screen (Every Musician, Same Song: no
-- badges, streaks or counts anywhere). It does not rename a link -- a code already on a poster is
-- kept by turning the link off and making another, which is what a teacher
-- with eight of them will do anyway. And both ends of a link are still
-- adults (0139): every function here that makes or changes a link asks the
-- same question first.

drop index if exists public.lesson_links_one_open;

-- Which room the whole class listens in, when the link is a class. Set null
-- when the room goes, so a link outlives a room the teacher deleted and
-- simply stops being a class.
--
-- class_off_at is the class turned off while the room is kept: scans stop
-- joining the room, and turning the class back on clears it and opens the
-- same room again. The room is only ever forgotten by going away.
alter table public.lesson_links
  add column class_room_id uuid references public.rooms(id) on delete set null,
  add column class_off_at timestamptz;

create index lesson_links_class_room_idx
  on public.lesson_links (class_room_id) where class_room_id is not null;

-- ---------------------------------------------------------------------
-- A viewer cannot post a take.
-- ---------------------------------------------------------------------

-- As 0038, with the role. `is distinct from` rather than `<>`: room_role_for
-- is null for somebody who is not a member at all, and `null <> 'viewer'` is
-- null, which passes a check it should fail -- though is_room_member catches
-- that one first, the two are written to agree.
drop policy if exists song_layers_insert_members on public.song_layers;
create policy song_layers_insert_members on public.song_layers
for insert to authenticated with check (
  recorded_by = (select auth.uid())
  and exists (
    select 1 from public.projects p
    where p.id = project_id
      and private.is_room_member(p.room_id)
      and private.room_role_for(p.room_id) is distinct from 'viewer'
  )
);

-- As 0041, with the role: the audio arrives before the row does, and a
-- refusal that only reached the row would leave the take's sound in the
-- bucket with nothing pointing at it.
drop policy if exists song_layer_files_write_members on storage.objects;
create policy song_layer_files_write_members on storage.objects
for insert to authenticated with check (
  bucket_id = 'room-files'
  and name like '%/layers/%'
  and array_length(storage.foldername(name), 1) >= 3
  and exists (
    select 1 from public.projects p
    where p.id = private.as_uuid((storage.foldername(name))[2])
      and private.is_room_member(p.room_id)
      and private.room_role_for(p.room_id) is distinct from 'viewer'
  )
);

-- ---------------------------------------------------------------------
-- A viewer can talk, said in words.
-- ---------------------------------------------------------------------

-- 0118 made room_messages and wrote its policies without a grant, which a
-- hosted project's default privileges cover. Said here the way 0001 says it
-- for every other table a room runs on, so that a viewer talking in the
-- class room is something the smoke can prove, rather than a write the CI
-- shim refuses on the grant before any policy is asked. Additive: a
-- production database already has this and gains nothing.
grant select, insert, delete on table public.room_messages to authenticated;

-- ---------------------------------------------------------------------
-- The teacher's side.
-- ---------------------------------------------------------------------

-- A room for a class, owned by the teacher and named for the link. Names
-- are unique within an account (rooms_account_name_unique), so "Jazz
-- studio" becomes "Jazz studio 2" beside a room that already has the name
-- -- the same rule join_lesson_link uses for a second Jess. A room that
-- already exists is never reused, even one called exactly this: a teacher
-- who has a band room named "Jazz studio" did not mean for every student
-- who scans a poster to be added to their band.
create or replace function private.make_class_room(teacher uuid, class_title text)
returns uuid
language plpgsql
security definer set search_path = ''
as $fn$
declare
  teacher_name text;
  base_name text := left(trim(coalesce(class_title, '')), 60);
  room_name text;
  attempt integer := 1;
  new_room uuid;
  next_sort double precision;
begin
  if base_name = '' then
    base_name := 'Class';
  end if;
  select coalesce(nullif(trim(p.display_name), ''), 'Your teacher') into teacher_name
  from public.profiles p where p.id = teacher;

  room_name := base_name;
  while exists (
    select 1 from public.rooms room
    where room.account_id = teacher
      and room.deleted_at is null
      and lower(regexp_replace(trim(room.name), '\s+', ' ', 'g'))
        = lower(regexp_replace(trim(room_name), '\s+', ' ', 'g'))
  ) loop
    attempt := attempt + 1;
    room_name := base_name || ' ' || attempt;
  end loop;

  select coalesce(max(room.sort_order), 0) + 1024 into next_sort
  from public.rooms room where room.account_id = teacher;

  insert into public.rooms (account_id, name, sort_order)
  values (teacher, room_name, next_sort)
  returning id into new_room;

  -- The teacher's colour in every lesson room (0129), so they look the same
  -- to a student in both.
  insert into public.room_members (room_id, user_id, display_name, role, color_value)
  values (new_room, teacher, coalesce(teacher_name, 'Your teacher'), 'owner', 4294937164);

  return new_room;
end;
$fn$;

revoke all on function private.make_class_room(uuid, text) from public, anon, authenticated;

-- Your open links, oldest first, each with how many students have joined
-- through it and the class room it opens into -- if it still exists and the
-- class is on. A class turned off reads as no class, which is what the switch
-- shows; the room it kept is the server's business until the switch goes on.
create or replace function public.my_lesson_links()
returns table (
  id uuid,
  code text,
  title text,
  created_at timestamptz,
  students bigint,
  class_room_id uuid,
  class_room_name text
)
language sql
stable
security definer set search_path = ''
as $fn$
  select l.id, l.code, l.title, l.created_at,
         (select count(*) from public.lesson_rooms r where r.link_id = l.id),
         room.id, room.name
  from public.lesson_links l
  left join public.rooms room
    on room.id = l.class_room_id and room.deleted_at is null and l.class_off_at is null
  where l.teacher_id = auth.uid() and l.closed_at is null
  order by l.created_at, l.id;
$fn$;

revoke all on function public.my_lesson_links() from public, anon;
grant execute on function public.my_lesson_links() to authenticated;

-- Makes a link. Dropped rather than replaced: a second signature beside the
-- old one would leave open_lesson_link('Guitar') with two functions to
-- choose from and PostgreSQL choosing neither. A build that still sends only
-- the title gets the default, which is what it meant.
--
-- Not "or renames the open one" any more (0129). With several links there is
-- no "the" one, and a teacher who calls this twice now has two links, which
-- is the point.
drop function if exists public.open_lesson_link(text);

create or replace function public.open_lesson_link(in_title text, in_class boolean default false)
returns text
language plpgsql
security definer set search_path = ''
as $fn$
declare
  me uuid := auth.uid();
  cleaned text := left(trim(coalesce(in_title, '')), 60);
  kept text;
  class_room uuid;
begin
  if me is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;
  perform private.lessons_need_an_adult(me);
  if cleaned = '' then
    cleaned := 'Lessons';
  end if;

  -- Eight. A ninth is a teacher who has lost track of the first, and the
  -- sentence says what to do about it rather than how many there are.
  if (select count(*) from public.lesson_links l
      where l.teacher_id = me and l.closed_at is null) >= 8 then
    raise exception 'Eight lesson links are open. Turn one off to make another.'
      using errcode = '22023';
  end if;

  if coalesce(in_class, false) then
    class_room := private.make_class_room(me, cleaned);
  end if;

  kept := left(replace(gen_random_uuid()::text, '-', ''), 12);
  insert into public.lesson_links (teacher_id, code, title, class_room_id)
  values (me, kept, cleaned, class_room);
  return kept;
end;
$fn$;

revoke all on function public.open_lesson_link(text, boolean) from public, anon;
grant execute on function public.open_lesson_link(text, boolean) to authenticated;

-- Marks a link as a class, or stops it being one. On: the link's class room,
-- the same one it had if that room is still there, made now if not. Off:
-- new students stop joining the room; the room and everybody in it stay,
-- because a room with people in it is theirs and not the link's -- and the
-- link remembers it, so on again after off is the room the class is already
-- in rather than an empty second one the poster would open into while the
-- teacher's recordings stay in the first. Returns the class room, or null.
--
-- Nobody but the link's teacher, and only while it is open: a closed link
-- opens nothing, so there is nothing for it to be a class of.
create or replace function public.set_lesson_link_class(in_link uuid, in_class boolean)
returns uuid
language plpgsql
security definer set search_path = ''
as $fn$
declare
  me uuid := auth.uid();
  link public.lesson_links%rowtype;
  class_room uuid;
begin
  if me is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;

  select * into link from public.lesson_links l
  where l.id = in_link and l.teacher_id = me and l.closed_at is null
  for update;
  if link.id is null then
    raise exception 'That is not a lesson link of yours.' using errcode = '42501';
  end if;

  -- After the link is known to be theirs, the way 0139 asks a student's age
  -- only once the link is known good: a link that is not yours says so
  -- whatever your age. A teacher who may not have a link may not keep one
  -- working either (0139's rule for renaming, which this is the nearest
  -- thing to now), though anybody holding an open link answered this once
  -- already.
  perform private.lessons_need_an_adult(me);

  if not coalesce(in_class, false) then
    update public.lesson_links
    set class_off_at = coalesce(class_off_at, now())
    where id = link.id;
    return null;
  end if;

  select room.id into class_room
  from public.rooms room
  where room.id = link.class_room_id and room.deleted_at is null;
  if class_room is null then
    class_room := private.make_class_room(me, link.title);
  end if;
  update public.lesson_links
  set class_room_id = class_room, class_off_at = null
  where id = link.id;
  return class_room;
end;
$fn$;

revoke all on function public.set_lesson_link_class(uuid, boolean) from public, anon;
grant execute on function public.set_lesson_link_class(uuid, boolean) to authenticated;

-- Turn one off, or -- with nothing said, which is what a build from before
-- this sends -- every open one. Rooms already made stay: those are lessons,
-- not the link, and a class room is a class.
drop function if exists public.close_lesson_link();

create or replace function public.close_lesson_link(in_link uuid default null)
returns void
language sql
security definer set search_path = ''
as $fn$
  update public.lesson_links
  set closed_at = now()
  where teacher_id = auth.uid()
    and closed_at is null
    and (in_link is null or id = in_link);
$fn$;

revoke all on function public.close_lesson_link(uuid) from public, anon;
grant execute on function public.close_lesson_link(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- The student's side.
-- ---------------------------------------------------------------------

-- As 0139, with the class. The class room comes before the room somebody
-- already has, and every time rather than only the first: a link that
-- became a class after a student joined it puts them in the class room the
-- next time they scan the poster, which is what the teacher will tell them
-- to do. Somebody the teacher already put in that room by hand keeps the
-- role they were given.
--
-- The other side of "every time": somebody the teacher took out of the class
-- room by hand is back in it, as a viewer, the next time they scan. Removal
-- is not sticky here, on purpose -- the alternative, joining the class only
-- on a first scan, would leave every student who joined before the link
-- became a class with no way in by the poster. Keeping somebody out is a
-- block, which refuses the link itself (blocked_between, below), or turning
-- the link off.
create or replace function public.join_lesson_link(in_code text)
returns uuid
language plpgsql
security definer set search_path = ''
as $fn$
declare
  me uuid := auth.uid();
  cleaned text := lower(regexp_replace(coalesce(in_code, ''), '[^0-9a-fA-F]', '', 'g'));
  link public.lesson_links%rowtype;
  existing uuid;
  student_name text;
  teacher_name text;
  base_name text;
  room_name text;
  attempt integer := 1;
  new_room uuid;
  next_sort double precision;
begin
  if me is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;

  select * into link from public.lesson_links l
  where l.code = cleaned and l.closed_at is null;
  if link.id is null then
    raise exception 'That lesson link is turned off, or it is not one.' using errcode = '22023';
  end if;
  if link.teacher_id = me then
    raise exception 'That is your own lesson link. Share it with a student.' using errcode = '22023';
  end if;
  if private.blocked_between(me, link.teacher_id) then
    raise exception 'That lesson link is not available to you.' using errcode = '42501';
  end if;

  perform private.lessons_need_an_adult(me);

  select coalesce(nullif(trim(p.display_name), ''), 'A student') into student_name
  from public.profiles p where p.id = me;
  select coalesce(nullif(trim(p.display_name), ''), 'Your teacher') into teacher_name
  from public.profiles p where p.id = link.teacher_id;

  -- The class, as a viewer: listening and talking, never a take in front of
  -- everybody (song_layers_insert_members, above). The colour is the
  -- trigger's to pick (0047). Not while the class is turned off: the room
  -- is kept for when it comes back on, and nobody new joins it meanwhile.
  if link.class_room_id is not null and link.class_off_at is null and exists (
    select 1 from public.rooms room
    where room.id = link.class_room_id and room.deleted_at is null
  ) then
    insert into public.room_members (room_id, user_id, display_name, role)
    values (link.class_room_id, me, coalesce(student_name, 'A student'), 'viewer')
    on conflict (room_id, user_id) do nothing;
  end if;

  -- Already joined: the same room, if it is still there.
  select r.room_id into existing
  from public.lesson_rooms r
  join public.rooms room on room.id = r.room_id
  where r.link_id = link.id and r.student_id = me;
  if existing is not null then
    return existing;
  end if;
  delete from public.lesson_rooms r where r.link_id = link.id and r.student_id = me;

  -- "Guitar lessons · Jess", and "Guitar lessons · Jess 2" for the second
  -- Jess: room names are unique within the teacher's account -- among rooms
  -- still there, which is what rooms_account_name_unique says and what
  -- make_class_room asks, so the two loops agree.
  base_name := left(link.title, 60) || ' · ' || left(coalesce(student_name, 'A student'), 40);
  room_name := base_name;
  while exists (
    select 1 from public.rooms room
    where room.account_id = link.teacher_id
      and room.deleted_at is null
      and lower(regexp_replace(trim(room.name), '\s+', ' ', 'g'))
        = lower(regexp_replace(trim(room_name), '\s+', ' ', 'g'))
  ) loop
    attempt := attempt + 1;
    room_name := base_name || ' ' || attempt;
  end loop;

  select coalesce(max(room.sort_order), 0) + 1024 into next_sort
  from public.rooms room where room.account_id = link.teacher_id;

  insert into public.rooms (account_id, name, sort_order)
  values (link.teacher_id, room_name, next_sort)
  returning id into new_room;

  insert into public.room_members (room_id, user_id, display_name, role, color_value)
  values (new_room, link.teacher_id, coalesce(teacher_name, 'Your teacher'), 'owner', 4294937164);
  insert into public.room_members (room_id, user_id, display_name, role)
  values (new_room, me, coalesce(student_name, 'A student'), 'editor');

  insert into public.lesson_rooms (link_id, student_id, room_id)
  values (link.id, me, new_room);

  -- The teacher hears about it, and the card opens the room.
  perform private.notify_user(
    link.teacher_id,
    'invite_accepted',
    coalesce(student_name, 'A student') || ' joined ' || link.title,
    'Your lesson room is ready: ' || room_name || '.',
    new_room,
    null,
    null,
    me
  );

  return new_room;
end;
$fn$;

revoke all on function public.join_lesson_link(text) from public, anon;
grant execute on function public.join_lesson_link(text) to authenticated;
