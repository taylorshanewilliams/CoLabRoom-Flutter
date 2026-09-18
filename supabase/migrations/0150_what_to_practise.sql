-- What to practise, and where it is.
--
-- Every Musician, Same Song, 17 September 2026: build-order slice 20, the
-- second half of an assignment. 0149 put a copy of the teacher's song in
-- each student's lesson room; this is what rides with it. A brief says
-- which passage, how fast, what the teacher will be listening for -- a few
-- short phrases, said before the student records, a rubric made of words --
-- and when by, in the teacher's own words ("before Thursday"). Home turns
-- it into one card on the student's side, in the grammar the practice card
-- already has, and Practise opens the song already looping that passage at
-- that speed.
--
-- The rules:
--
--   * A brief is attached to one song in one lesson room, and there is one
--     a song. Saying what to practise again replaces what was said before:
--     the second week of the same aria is a new passage on the same copy,
--     not a second card.
--   * Only the teacher of that lesson sets it, still owning the room, for
--     the student the room belongs to (0129). The student is an editor of
--     the room and can write on the song, which is exactly why this is a
--     table of its own and not columns on projects: projects_update_editors
--     (0005) would have let the student rewrite their own brief.
--   * Only those two people read it. The row names them both and the
--     policy asks nothing else, so a third person invited into the lesson
--     room, or the song moved to a band room, shows the brief to nobody
--     new.
--   * Nothing here counts anything, and nothing will. There is no column
--     for a score, a mark out of anything, a tick or a tally, and no place
--     to put one later without a migration somebody would have to argue
--     for. The speed and the two ends of the passage are where the song
--     plays, not how well.
--   * When it is due is words. It is never parsed, never compared with
--     today, and nothing is scheduled from it: no reminder, no countdown,
--     and no push when Thursday passes.
--   * Nobody is told. The copy arriving told the student once (0149); a
--     brief is read when they next open Home, the way the card a lesson
--     leaves is. And nothing is written when they do: there is no opened
--     flag here and no read receipt, so a teacher sees what is sent to them
--     and never whether a card was looked at. set_at exists only to put
--     several cards in order, and no screen says it.

create table public.song_briefs (
  -- New every time the brief is set, so a card the student closed comes
  -- back when the teacher says something new and stays closed otherwise.
  id uuid primary key default gen_random_uuid(),

  -- The song it rides with: the copy in the student's lesson room.
  project_id uuid not null unique references public.projects(id) on delete cascade,

  -- The two people it is between, written by set_song_briefs from the
  -- lesson itself and never taken from the caller's say-so.
  teacher_id uuid not null references public.profiles(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,

  -- What the card calls the teacher, kept as 0128 keeps a leader's name.
  teacher_name text not null check (char_length(trim(teacher_name)) between 1 and 80),

  -- The passage, named the way Perform names it: "Bars 1–16", "Chorus 2",
  -- "The whole song". Both ends null is the whole song, as in 0128's parts.
  passage text not null check (char_length(trim(passage)) between 1 and 40),
  start_ms integer,
  end_ms integer,

  -- The same range keep_practice_mark (0128) and leave_practice_mark (0143)
  -- accept, so three writers do not hold three opinions about what a speed
  -- is. The app offers the practice rates and nothing else.
  rate numeric not null default 1 check (rate >= 0.25 and rate <= 2),

  -- What the teacher is listening for: a few short phrases, in the order
  -- they were said. Tidied by set_song_briefs.
  listening_for text[] not null default '{}'::text[],

  -- "before Thursday". Words, on purpose; see above.
  due_words text check (due_words is null or char_length(due_words) between 1 and 40),

  set_at timestamptz not null default now(),

  constraint song_briefs_whole_or_a_passage check (
    (start_ms is null and end_ms is null)
    or (start_ms is not null and end_ms is not null
        and start_ms >= 0 and end_ms > start_ms)
  ),
  constraint song_briefs_a_few_phrases check (cardinality(listening_for) <= 5)
);

create index song_briefs_student_idx on public.song_briefs (student_id, set_at desc);
create index song_briefs_teacher_idx on public.song_briefs (teacher_id);

alter table public.song_briefs enable row level security;

-- The two of them and nobody else. Not is_room_member: a lesson room can
-- gain a third person, and a song can be moved to another room, and neither
-- should widen who reads what one person asked of another.
create policy song_briefs_read_the_two on public.song_briefs
for select to authenticated using (
  student_id = (select auth.uid())
  or teacher_id = (select auth.uid())
);

-- Written only through set_song_briefs, which checks the lesson. Reading is
-- the one thing a phone may do here, and the policy above decides for whom.
revoke all on table public.song_briefs from public, anon, authenticated;
grant select on table public.song_briefs to authenticated;

-- ---------------------------------------------------------------------
-- Saying it
-- ---------------------------------------------------------------------

-- A few short phrases: trimmed, runs of white space folded to one space,
-- empty ones dropped, nothing over eighty characters, five at most, in the
-- order they were given. Reads no table, so there is nothing to guard, and
-- it is called only from the security definer function below, which runs
-- as its owner.
create or replace function private.tidy_listening_for(raw text[])
returns text[]
language sql
immutable
as $fn$
  select coalesce(
    (select array_agg(phrase order by ord)
     from (
       select phrase, ord
       from (
         select left(btrim(regexp_replace(coalesce(t, ''), '\s+', ' ', 'g')), 80) as phrase,
                ord
         from unnest(coalesce(raw, '{}'::text[])) with ordinality as u(t, ord)
       ) cleaned
       where char_length(phrase) > 0
       order by ord
       limit 5
     ) kept),
    '{}'::text[]
  );
$fn$;

revoke all on function private.tidy_listening_for(text[]) from public, anon, authenticated;

-- Puts one brief on each of in_projects, every one a song in a lesson room
-- the caller teaches and still owns, and returns the songs that took it.
-- One song that is not in a lesson of theirs refuses the lot, because the
-- function raises and the statement rolls back with it: a teacher should
-- not end a Sunday with half a studio briefed. A lesson whose student has
-- left, or where either of them has blocked the other, is skipped rather
-- than refused, as 0149 skips it and for its reason -- the list was made
-- from a screen that can be a minute stale, and it is the caller's room;
-- there is just nobody in it to ask anything of.
create or replace function public.set_song_briefs(
  in_projects uuid[],
  in_passage text,
  in_rate numeric,
  in_start_ms integer default null,
  in_end_ms integer default null,
  in_listening_for text[] default null,
  in_due_words text default null
)
returns setof uuid
language plpgsql
security definer set search_path = ''
as $fn$
declare
  me uuid := auth.uid();
  cleaned_passage text := left(trim(coalesce(in_passage, '')), 40);
  cleaned_due text := nullif(
    left(btrim(regexp_replace(coalesce(in_due_words, ''), '\s+', ' ', 'g')), 40), '');
  phrases text[] := private.tidy_listening_for(in_listening_for);
  loop_start integer;
  loop_end integer;
  -- Not called teacher_name: the table has a column of that name, and a
  -- variable that shares one is a way to be told a reference is ambiguous.
  said_by text;
  target uuid;
  song_room uuid;
  student uuid;
begin
  if me is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;
  if in_projects is null or cardinality(in_projects) = 0 then
    raise exception 'Pick a student first.' using errcode = '22023';
  end if;
  -- 0143's two sentences, because they are the same two mistakes.
  if cleaned_passage = '' then
    raise exception 'Practice needs a part of the song.' using errcode = '22023';
  end if;
  if in_rate is null or in_rate < 0.25 or in_rate > 2 then
    raise exception 'That is not a speed to practise at.' using errcode = '22023';
  end if;

  -- A passage is a loop only when it has both ends and they are the right
  -- way round; anything else is the whole song (0143).
  if in_start_ms is not null and in_end_ms is not null
     and in_start_ms >= 0 and in_end_ms > in_start_ms then
    loop_start := in_start_ms;
    loop_end := in_end_ms;
  end if;

  select left(coalesce(nullif(trim(pr.display_name), ''), 'Your teacher'), 80)
    into said_by
  from public.profiles pr where pr.id = me;
  if said_by is null then
    said_by := 'Your teacher';
  end if;

  foreach target in array in_projects loop
    -- A null in the list is refused rather than skipped: a song that is
    -- nothing is not in a lesson of theirs.
    if target is null then
      raise exception 'That is not a lesson of yours.' using errcode = '42501';
    end if;

    song_room := null;
    select p.room_id into song_room
    from public.projects p
    where p.id = target and p.deleted_at is null;
    if song_room is null then
      raise exception 'That song could not be found.' using errcode = '22023';
    end if;

    -- The lesson itself: a room made by this caller's own lesson link, for
    -- the student named in it. lesson_links is joined without a closed_at
    -- filter on purpose, as 0143 and 0149 do -- a teacher who took their
    -- poster down still teaches the people who scanned it.
    student := null;
    select lr.student_id into student
    from public.lesson_rooms lr
    join public.lesson_links l on l.id = lr.link_id
    where lr.room_id = song_room and l.teacher_id = me
    limit 1;
    if student is null then
      raise exception 'That is not a lesson of yours.' using errcode = '42501';
    end if;
    -- And the caller still owns the room. `is distinct from` rather than
    -- `<>`: room_role_for is null for somebody with no role, and
    -- `null <> 'owner'` is null, which waves through the exact person the
    -- check exists to stop (0068).
    if private.room_role_for(song_room) is distinct from 'owner' then
      raise exception 'That is not a lesson of yours.' using errcode = '42501';
    end if;

    -- Nobody on the other end: skipped, not refused.
    if not exists (
      select 1 from public.room_members rm
      where rm.room_id = song_room and rm.user_id = student
    ) then
      continue;
    end if;
    if private.blocked_between(me, student) then
      continue;
    end if;

    -- One a song, brought up to date, under a new id so that the student's
    -- phone can tell this week's brief from the one they closed last week.
    insert into public.song_briefs
      (project_id, teacher_id, student_id, teacher_name, passage, start_ms,
       end_ms, rate, listening_for, due_words)
    values
      (target, me, student, said_by, cleaned_passage, loop_start,
       loop_end, in_rate, phrases, cleaned_due)
    on conflict (project_id) do update
    set id = gen_random_uuid(),
        teacher_id = excluded.teacher_id,
        student_id = excluded.student_id,
        teacher_name = excluded.teacher_name,
        passage = excluded.passage,
        start_ms = excluded.start_ms,
        end_ms = excluded.end_ms,
        rate = excluded.rate,
        listening_for = excluded.listening_for,
        due_words = excluded.due_words,
        set_at = now();

    -- Nobody is told, on purpose: see the top of this file.
    return next target;
  end loop;

  return;
end;
$fn$;

revoke all on function public.set_song_briefs(
  uuid[], text, numeric, integer, integer, text[], text
) from public, anon;
grant execute on function public.set_song_briefs(
  uuid[], text, numeric, integer, integer, text[], text
) to authenticated;
