-- Leave it for the student.
--
-- 0128 keeps what a followed session left: the part that was worked on, the
-- speed it was got to, and the teacher's parting words, on the student's own
-- account, offered back by Home with one verb. That only ever happened at
-- the end of a live hour. A teacher who thinks on Wednesday evening that
-- Jess should spend the week on the second chorus, slowly, had nowhere to
-- put it -- the lesson was over, and a message in the thread is a sentence
-- to read rather than a song to open.
--
-- So: in a lesson room (0129), the teacher can leave practice without a
-- session. It writes the same mark 0128 writes, owned by the student and led
-- by the teacher, so the student's Home shows the card they already know.
--
-- Every Musician, Same Song, 17 September 2026. The rules it inherits, and
-- the ones it adds:
--
--   * The mark is the student's. The teacher writes it and cannot read it
--     back: practice_marks_read_own (0128) shows a row to nobody but its
--     owner, and there is no function here that widens that. A teacher who
--     could see the marks would be seeing whether somebody practised, and
--     practice is where people are allowed to be bad at things.
--   * Only in a lesson room the caller teaches, on a song in it, for the
--     student that room belongs to. Not a band room: a band room is four
--     people and none of them is anybody's teacher, and the same call there
--     would be one member writing on another member's Home.
--   * One mark per teacher per song, brought up to date. Leaving practice
--     again on the same song replaces everything this teacher left before --
--     including what their lessons left, one row each (0128) -- because Home
--     shows one card a song and prefers whichever one carries words (see
--     _cardMark in songs_screen). Without the replace, a teacher who left
--     "Verse 1 at half speed" today would watch the student's card go on
--     saying what last week's lesson said.
--   * The student is told, through the switch that already covers somebody
--     else doing something to one of their songs. No new notification type:
--     this is a teacher acting on a song, which is what project_update has
--     always meant, and a type of its own would arrive as a new thing to be
--     turned off separately.
--   * Nothing here counts anything. No date is stored beyond the row's own
--     updated_at, which 0128 already keeps and no screen reads out.

create or replace function public.leave_practice_mark(
  in_project uuid,
  in_student uuid,
  in_label text,
  in_rate numeric,
  in_start_ms integer default null,
  in_end_ms integer default null,
  in_note text default null
)
returns uuid
language plpgsql
security definer set search_path = ''
as $fn$
declare
  me uuid := auth.uid();
  song_room uuid;
  song_title text;
  teacher_name text;
  cleaned_label text := left(trim(coalesce(in_label, '')), 40);
  cleaned_note text := nullif(left(trim(coalesce(in_note, '')), 280), '');
  loop_start integer;
  loop_end integer;
  built jsonb;
  existing uuid;
  mark_id uuid;
begin
  if me is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;
  -- Said before anything is looked up, so a call with nothing in it reads
  -- as a refusal rather than as a song that could not be found.
  if in_project is null or in_student is null then
    raise exception 'That is not a lesson of yours.' using errcode = '42501';
  end if;

  select p.room_id, p.title into song_room, song_title
  from public.projects p
  where p.id = in_project and p.deleted_at is null;
  if song_room is null then
    raise exception 'That song could not be found.' using errcode = '22023';
  end if;

  -- The lesson itself: a room made by this caller's own lesson link, for
  -- this student. lesson_links is joined without a closed_at filter on
  -- purpose -- 0129 turns the link off and leaves the rooms, because those
  -- are lessons rather than the link, and a teacher who took their poster
  -- down still teaches the people who scanned it.
  if not exists (
    select 1
    from public.lesson_rooms lr
    join public.lesson_links l on l.id = lr.link_id
    where lr.room_id = song_room
      and lr.student_id = in_student
      and l.teacher_id = me
  ) then
    raise exception 'That is not a lesson of yours.' using errcode = '42501';
  end if;

  -- And the caller still owns the room, and the student is still in it.
  -- `is distinct from` rather than `<>`: room_role_for returns null for
  -- somebody who is not a member at all, and `null <> 'owner'` is null,
  -- which passes a check it should fail.
  if private.room_role_for(song_room) is distinct from 'owner' then
    raise exception 'That is not a lesson of yours.' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.room_members rm
    where rm.room_id = song_room and rm.user_id = in_student
  ) then
    raise exception 'That is not a lesson of yours.' using errcode = '42501';
  end if;

  -- Either of them having blocked the other closes the lesson, the same way
  -- it closes the link that made it (0129).
  if private.blocked_between(me, in_student) then
    raise exception 'That is not a lesson of yours.' using errcode = '42501';
  end if;

  if cleaned_label = '' then
    raise exception 'Practice needs a part of the song.' using errcode = '22023';
  end if;
  -- The same range keep_practice_mark accepts, so the two writers into this
  -- table do not hold two different opinions about what a speed is. The app
  -- offers three of them.
  if in_rate is null or in_rate < 0.25 or in_rate > 2 then
    raise exception 'That is not a speed to practise at.' using errcode = '22023';
  end if;

  -- A part is a loop only when it has both ends and they are the right way
  -- round; anything else is the whole song, which is what a null pair means
  -- in 0128's parts.
  if in_start_ms is not null and in_end_ms is not null
     and in_start_ms >= 0 and in_end_ms > in_start_ms then
    loop_start := in_start_ms;
    loop_end := in_end_ms;
  end if;

  -- Capped at eighty, because that is what the column takes (0128): a mark
  -- whose leader's name is one character too long should say the name it
  -- can rather than refuse the practice.
  select left(coalesce(nullif(trim(pr.display_name), ''), 'Your teacher'), 80)
    into teacher_name
  from public.profiles pr where pr.id = me;
  if teacher_name is null then
    teacher_name := 'Your teacher';
  end if;

  -- Zero seconds because nothing was played: the field exists only to put
  -- several parts in order (0128), and no screen has ever shown it.
  built := jsonb_build_array(jsonb_build_object(
    'start', loop_start,
    'end', loop_end,
    'label', cleaned_label,
    'rate', in_rate,
    'seconds', 0
  ));

  select m.id into existing
  from public.practice_marks m
  where m.profile_id = in_student
    and m.project_id = in_project
    and m.led_by = me
  order by m.updated_at desc
  limit 1;

  if existing is not null then
    -- Folded onto the newest of them, and the rest are dropped below. There
    -- can be several: keep_practice_mark names a mark per followed stretch
    -- (0128, and the phone makes a fresh id each time it follows), so a
    -- student who followed this teacher twice on this song already has two
    -- rows led by them.
    -- The note is replaced outright, not coalesced the way 0128's upsert
    -- does it. That rule protects a teacher's words from a student's phone
    -- saving over them automatically; this is the teacher themselves, and a
    -- note they deliberately left off should come off.
    update public.practice_marks
    set led_by_name = teacher_name,
        note = cleaned_note,
        parts = built,
        updated_at = now()
    where id = existing;
    mark_id := existing;
  else
    mark_id := gen_random_uuid();
    insert into public.practice_marks
      (id, profile_id, project_id, led_by, led_by_name, note, parts)
    values (mark_id, in_student, in_project, me, teacher_name, cleaned_note, built);
  end if;

  -- Every other mark this teacher led on this song goes, not just the one
  -- that was brought up to date. Home shows one card a song and prefers
  -- whichever mark on it carries words (_cardMark in songs_screen), so an
  -- older mark left behind with a note on it outranks the one just written
  -- and the student reads last week's instruction as this week's. One mark
  -- per teacher per song is the rule; this is what makes it true rather than
  -- nearly true.
  delete from public.practice_marks
  where profile_id = in_student
    and project_id = in_project
    and led_by = me
    and id is distinct from mark_id;

  -- Quietly, and only if they want to hear about their songs at all.
  -- notify_user checks that switch itself; nothing here second-guesses it.
  perform private.notify_user(
    in_student,
    'project_update',
    teacher_name || ' left you something to practise',
    coalesce(song_title, 'A song') || ' · ' || cleaned_label,
    song_room,
    in_project,
    null,
    me
  );

  return mark_id;
end;
$fn$;

revoke all on function public.leave_practice_mark(
  uuid, uuid, text, numeric, integer, integer, text
) from public, anon;
grant execute on function public.leave_practice_mark(
  uuid, uuid, text, numeric, integer, integer, text
) to authenticated;
