-- Lesson links are for adults, for now.
--
-- Every Musician, Same Song, 17 September 2026: adult students first, and
-- lesson links for people 18 and over until there is a guardian step to put
-- 13 to 17 behind. It is the rule calls have had since 0134, and lesson
-- links (0129) never checked it: a teacher's QR code on a studio wall is
-- scanned by whoever walks past, which is the one place in this app where a
-- stranger's age was nobody's business and needed to be. Production has two
-- links and no lesson rooms, so this turns nobody out of anything.
--
-- The same three answers calls give, in the same order, so that somebody
-- says when they were born once and it counts for both:
--
--   * an account that answered under 13 is closed to lesson links, in the
--     sentence 0138 settled on, with no age in it for a second try to aim at;
--   * an account that has never said is asked, and the app opens the same
--     question calls ask;
--   * a 16-year-old is told plainly, and told nothing about a way in.
--
-- Which of the three it is rides on the error's hint rather than its words,
-- so the sentence can be reworded without the app stopping recognising it.
--
-- Age is asked last, after the link itself is known good: a link that was
-- turned off says so to everybody, and nobody is asked for a birth month to
-- open something that was never going to open.

-- Raises unless this account may be at either end of a lesson link. Both
-- ends: a teacher under 18 teaching adults is a question for Taylor and a
-- lawyer, not something a link should quietly allow.
create or replace function private.lessons_need_an_adult(person uuid)
returns void
language plpgsql
stable
security definer set search_path = ''
as $fn$
begin
  if person is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;
  if exists (select 1 from private.age_refusals r where r.person_id = person) then
    raise exception 'Lesson links are not available on this account.'
      using errcode = '22023', hint = 'lesson_age';
  end if;
  -- Null or missing: a birth month nobody has given is not an adult one.
  if not exists (select 1 from private.birth_months b where b.person_id = person) then
    raise exception 'Your birth month first.'
      using errcode = '22023', hint = 'lesson_birth_month';
  end if;
  if not private.is_adult(person) then
    raise exception 'Lesson links are for people 18 and over for now.'
      using errcode = '22023', hint = 'lesson_age';
  end if;
end;
$fn$;

revoke all on function private.lessons_need_an_adult(uuid) from public, anon, authenticated;

-- As 0129, with the age rule. Renaming an open link goes through here too:
-- a teacher who may not have a link may not keep one working either.
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
  perform private.lessons_need_an_adult(me);
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

-- As 0129, with the age rule after the link's own checks and before the room
-- somebody already has. Before, rather than after: a link that is only for
-- adults should not behave one way for a stranger and another for somebody
-- who used it last week, and there is nobody in the second case to spare --
-- production has no lesson rooms at all.
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
