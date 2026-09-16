-- A link for lessons.
--
-- Taylor, 16 September: "a way for teachers to start learning rooms, or
-- lesson rooms, and they can email out or share a qr code or whatever, and
-- the student could join right into their room."
--
-- An invitation was the wrong shape for that. It is addressed to one email,
-- used once, and opens a room that already exists -- which for a teacher
-- would mean one room shared by every student, each hearing the others'
-- takes. A teacher's code on a studio wall is used by everybody who walks
-- past it, and each of those people is a separate lesson.
--
-- So: one standing lesson link per teacher. Whoever opens it gets their own
-- room with the teacher -- the two of them and nobody else -- with Follow me,
-- the song sheet and the practice marks already there. Opening it again
-- gives back the same room, never a second.
--
-- The consent rule still holds, from both ends. The teacher agreed to rooms
-- appearing by making the link, and can turn it off. The student agrees by
-- opening it; nobody is added to anything they did not open. Somebody
-- either of them has blocked cannot use it.

create table public.lesson_links (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references public.profiles(id) on delete cascade,

  -- Twelve hex characters, shown to people as abcd-ef01-2345. Stored
  -- plainly, unlike an invitation token: the teacher has to be able to show
  -- it again tomorrow, and what it opens is an empty room with the teacher,
  -- not anything that already exists.
  code text not null unique check (code ~ '^[0-9a-f]{12}$'),

  -- What they teach, in their words: "Guitar lessons".
  title text not null check (char_length(trim(title)) between 1 and 60),

  created_at timestamptz not null default now(),
  closed_at timestamptz
);

-- One open link per teacher. A second link is a teacher who lost track of
-- the first, and a student scanning the old poster should not be told it
-- is closed while an identical one works.
create unique index lesson_links_one_open
  on public.lesson_links (teacher_id) where closed_at is null;

alter table public.lesson_links enable row level security;

create policy lesson_links_read_own on public.lesson_links
for select to authenticated using (teacher_id = (select auth.uid()));

grant select on public.lesson_links to authenticated;
revoke insert, update, delete on public.lesson_links from authenticated, anon;

-- Which room each student's lessons live in.
create table public.lesson_rooms (
  link_id uuid not null references public.lesson_links(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  room_id uuid not null references public.rooms(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (link_id, student_id)
);

create index lesson_rooms_room_idx on public.lesson_rooms (room_id);

alter table public.lesson_rooms enable row level security;

create policy lesson_rooms_read_either on public.lesson_rooms
for select to authenticated using (
  student_id = (select auth.uid())
  or exists (
    select 1 from public.lesson_links l
    where l.id = link_id and l.teacher_id = (select auth.uid())
  )
);

grant select on public.lesson_rooms to authenticated;
revoke insert, update, delete on public.lesson_rooms from authenticated, anon;

-- ---------------------------------------------------------------------
-- The teacher's side.
-- ---------------------------------------------------------------------

-- Your open link, with how many students have joined through it.
create or replace function public.my_lesson_link()
returns table (id uuid, code text, title text, created_at timestamptz, students bigint)
language sql
stable
security definer set search_path = ''
as $fn$
  select l.id, l.code, l.title, l.created_at,
         (select count(*) from public.lesson_rooms r where r.link_id = l.id)
  from public.lesson_links l
  where l.teacher_id = auth.uid() and l.closed_at is null
  limit 1;
$fn$;

revoke all on function public.my_lesson_link() from public, anon;
grant execute on function public.my_lesson_link() to authenticated;

-- Make the link, or rename the open one. Renaming keeps the code: a code
-- already printed on a poster must go on working.
create or replace function public.open_lesson_link(in_title text)
returns text
language plpgsql
security definer set search_path = ''
as $fn$
declare
  me uuid := auth.uid();
  cleaned text := left(trim(coalesce(in_title, '')), 60);
  kept text;
begin
  if me is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;
  if cleaned = '' then
    cleaned := 'Lessons';
  end if;

  update public.lesson_links
  set title = cleaned
  where teacher_id = me and closed_at is null
  returning code into kept;
  if kept is not null then
    return kept;
  end if;

  kept := left(replace(gen_random_uuid()::text, '-', ''), 12);
  insert into public.lesson_links (teacher_id, code, title)
  values (me, kept, cleaned);
  return kept;
end;
$fn$;

revoke all on function public.open_lesson_link(text) from public, anon;
grant execute on function public.open_lesson_link(text) to authenticated;

-- Turn it off. Rooms already made stay: those are lessons, not the link.
create or replace function public.close_lesson_link()
returns void
language sql
security definer set search_path = ''
as $fn$
  update public.lesson_links
  set closed_at = now()
  where teacher_id = auth.uid() and closed_at is null;
$fn$;

revoke all on function public.close_lesson_link() from public, anon;
grant execute on function public.close_lesson_link() to authenticated;

-- ---------------------------------------------------------------------
-- The student's side.
-- ---------------------------------------------------------------------

-- Opens a link: your room with the teacher, made the first time and given
-- back every time after. Returns the room.
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

  -- Already joined: the same room, if it is still there.
  select r.room_id into existing
  from public.lesson_rooms r
  join public.rooms room on room.id = r.room_id
  where r.link_id = link.id and r.student_id = me;
  if existing is not null then
    return existing;
  end if;
  delete from public.lesson_rooms r where r.link_id = link.id and r.student_id = me;

  select coalesce(nullif(trim(p.display_name), ''), 'A student') into student_name
  from public.profiles p where p.id = me;
  select coalesce(nullif(trim(p.display_name), ''), 'Your teacher') into teacher_name
  from public.profiles p where p.id = link.teacher_id;

  -- "Guitar lessons · Jess", and "Guitar lessons · Jess 2" for the second
  -- Jess: room names are unique within the teacher's account.
  base_name := left(link.title, 60) || ' · ' || left(coalesce(student_name, 'A student'), 40);
  room_name := base_name;
  while exists (
    select 1 from public.rooms room
    where room.account_id = link.teacher_id
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
