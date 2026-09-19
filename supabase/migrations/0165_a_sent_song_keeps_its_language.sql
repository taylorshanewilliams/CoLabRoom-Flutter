-- A song sent to a student keeps its language.
--
-- 0163 let the room say what a song is sung in, because which way a line
-- runs and what a chord sits over are decided by the language and not by
-- the characters (Every Musician, Same Song, 17 September 2026, world
-- traditions item 3). 0149's send_song_to_students copies a song into each
-- student's lesson room, and it does not copy that column -- so a teacher
-- declares Arabic on a song, sends it to the class, and every student's
-- copy arrives with language null and lays out left to right with the
-- chords over the wrong end of every line. A song in Chinese arrives with
-- every chord in a line over its first character. The teacher's page and
-- the class's page are then two different pages, which is the one thing a
-- shared fact exists to prevent.
--
-- 0162 saw this and left it alone on purpose: its comment says the cycle
-- slice was not the place to fold in a column nobody reviewing a cycle
-- would be looking for. This is that place. Nothing else changes: the
-- language is still declared by the room's owner or an editor through
-- set_song_language and never inferred, and a song nobody has answered for
-- still copies as null, which reads the way this app read every song before
-- the column existed.
--
-- Copies already sent are left as they are, on purpose rather than for want
-- of an update statement. This changes what a send does, not what was sent:
-- a copy that arrived between 0163 and this one still has nothing said on
-- it, and sending the song again finds that copy and returns without
-- touching it. A one-off backfill here would repair a day's worth of rows
-- and leave the same thing happening every day after, because a teacher who
-- declares a language after sending is in exactly that position tomorrow --
-- the declaration reaches the original and stops there, as the key (0144),
-- bar 1 (0161) and the cycle (0162) already do. Whether a shared fact
-- declared later should follow the copies already made is one question
-- about all four columns and wants deciding once, not answered sideways
-- here for the newest of them. A teacher who needs it meanwhile owns the
-- lesson rooms and can say it on the copy.
--
-- Restated from its latest definition, which is 0162's -- 0163 and 0164
-- added columns and a read without touching this function. Only the insert
-- changes; everything else is 0162's text unaltered, the returns-table
-- shape is the same, and the grants below are the same two lines.

create or replace function public.send_song_to_students(
  in_project uuid,
  in_rooms uuid[]
)
returns table (to_room uuid, song_copy uuid, recording text, fresh boolean)
language plpgsql
security definer set search_path = ''
as $fn$
declare
  me uuid := auth.uid();
  song public.projects%rowtype;
  song_file public.files%rowtype;
  teacher_name text;
  target uuid;
  student uuid;
  lesson_account uuid;
  student_name text;
  existing uuid;
  made uuid;
  made_title text;
  suffix text;
  attempt integer;
  next_sort double precision;
  each_line record;
  new_line uuid;
begin
  if me is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;
  -- Said before anything is looked up, so a call with nothing in it reads
  -- as a refusal rather than as a song that could not be found.
  if in_project is null then
    raise exception 'That song is not yours to send.' using errcode = '42501';
  end if;
  if in_rooms is null or cardinality(in_rooms) = 0 then
    raise exception 'Pick a student first.' using errcode = '22023';
  end if;

  select * into song
  from public.projects p
  where p.id = in_project and p.deleted_at is null;
  if song.id is null then
    raise exception 'That song could not be found.' using errcode = '22023';
  end if;

  -- The owner of the room the song lives in, and nobody else: not an
  -- editor, not somebody invited to the song on its own (0013), and not a
  -- stranger, all refused in the same words. The test put_on_open_mic
  -- makes, for its reason: a song leaving its room is the room owner's
  -- decision. `is distinct from` rather than `<>`, because room_role_for
  -- is null for somebody with no role, and `null <> 'owner'` is null,
  -- which waves through the exact person the check exists to stop (0068).
  if private.room_role_for(song.room_id) is distinct from 'owner' then
    raise exception 'That song is not yours to send.' using errcode = '42501';
  end if;

  -- Whether a recording follows, and which. Null when nothing does.
  song_file := private.recording_to_send(song);

  select left(coalesce(nullif(trim(pr.display_name), ''), 'Your teacher'), 80)
    into teacher_name
  from public.profiles pr where pr.id = me;
  if teacher_name is null then
    teacher_name := 'Your teacher';
  end if;

  foreach target in array in_rooms loop
    -- A null in the list is refused rather than skipped: a room that is
    -- nothing is not a lesson of theirs.
    if target is null then
      raise exception 'That is not a lesson of yours.' using errcode = '42501';
    end if;

    -- The song's own room is skipped before anything is asked of it: the
    -- song is already there, and the caller owns that room (the gate
    -- above), so whether it is a lesson does not matter. A song written in
    -- a lesson room and sent on to the other lessons passes through here.
    if target = song.room_id then
      continue;
    end if;

    -- The lesson itself: a room made by this caller's own lesson link, still
    -- there, for a student named in it. lesson_links is joined without a
    -- closed_at filter on purpose, as 0143 does -- a teacher who took their
    -- poster down still teaches the people who scanned it.
    student := null;
    lesson_account := null;
    select lr.student_id, room.account_id into student, lesson_account
    from public.lesson_rooms lr
    join public.lesson_links l on l.id = lr.link_id
    join public.rooms room on room.id = lr.room_id and room.deleted_at is null
    where lr.room_id = target and l.teacher_id = me
    limit 1;
    if student is null then
      raise exception 'That is not a lesson of yours.' using errcode = '42501';
    end if;
    -- And the caller still owns the room.
    if private.room_role_for(target) is distinct from 'owner' then
      raise exception 'That is not a lesson of yours.' using errcode = '42501';
    end if;

    -- A lesson with nobody on the other end -- the student left, or was
    -- removed, or either of them has blocked the other, which closes the
    -- lesson the way it closes the link that made it (0129) -- is skipped.
    -- It is the caller's room; there is just nobody in it to send to.
    if not exists (
      select 1 from public.room_members rm
      where rm.room_id = target and rm.user_id = student
    ) then
      continue;
    end if;
    if private.blocked_between(me, student) then
      continue;
    end if;

    -- Already there: a room holding a live copy.
    existing := null;
    select p.id into existing
    from public.projects p
    where p.room_id = target
      and p.copied_from = song.id
      and p.deleted_at is null
    limit 1;
    if existing is not null then
      -- A copy whose recording never arrived is handed back so that the
      -- app can finish it, and said to be not fresh so that the app does
      -- not count it; nothing else about it is touched, and the student,
      -- who already has the song, is not told again.
      if song_file.id is not null and not exists (
        select 1 from public.project_audio_references r
        where r.project_id = existing
      ) then
        to_room := target;
        song_copy := existing;
        recording := song_file.storage_path;
        fresh := false;
        return next;
      end if;
      continue;
    end if;

    select coalesce(nullif(trim(pr.display_name), ''), 'A student')
      into student_name
    from public.profiles pr where pr.id = student;
    if student_name is null then
      student_name := 'A student';
    end if;

    -- The song's own title where it can be, which is a room in another
    -- account. Titles are unique within an account among songs still there
    -- (projects_account_title_unique), and the lesson room is in the
    -- teacher's account with the original, so most copies become
    -- "Caro mio ben · Jess" -- named the way the room itself is (0129) --
    -- and "Caro mio ben · Jess 2" beside a copy that already has that name.
    -- The title is shortened before the name rather than after, so the
    -- student's name is never the part that gets cut.
    made_title := song.title;
    attempt := 1;
    while exists (
      select 1 from public.projects p
      where p.account_id = lesson_account
        and p.deleted_at is null
        and lower(regexp_replace(trim(p.title), '\s+', ' ', 'g'))
          = lower(regexp_replace(trim(made_title), '\s+', ' ', 'g'))
    ) loop
      attempt := attempt + 1;
      suffix := ' · ' || left(student_name, 30)
        || case when attempt > 2 then ' ' || (attempt - 1)::text else '' end;
      made_title := rtrim(left(trim(song.title), 80 - char_length(suffix))) || suffix;
    end loop;

    select coalesce(max(p.sort_order), 0) + 1024 into next_sort
    from public.projects p where p.room_id = target;

    -- The song. Its origin, its key, where its bar 1 is, the cycle the band
    -- counts and what it is sung in go with it: whose song this is does not
    -- change by being copied, and the band's key (0144), bar 1 (0161), the
    -- cycle (0162) and the language (0163) are facts about the song. A
    -- teacher who counts a seven and then says "from cycle nine" has to be
    -- saying it about the copy on the stand in front of the student, and a
    -- song declared to be sung in Arabic has to run right to left on that
    -- copy as well -- a language that stayed behind would leave the class
    -- reading a different page from the teacher, which is the one thing a
    -- shared fact exists to prevent. Null copies as null: a song nobody has
    -- answered for is laid out on the student's stand exactly as it is on
    -- the teacher's. The picture does not follow: it
    -- lives under the original room's folder, where the student cannot see
    -- it, and a tile that fails to load is worse than the plain one. Nothing
    -- public, nothing finished.
    made := gen_random_uuid();
    insert into public.projects
      (id, room_id, account_id, title, description, status, created_by,
       sort_order, song_origin, key_override, bar_one_downbeat,
       cycle_beats, cycle_accents, language, copied_from)
    values
      (made, target, lesson_account, made_title, song.description, 'active',
       me, next_sort, song.song_origin, song.key_override,
       song.bar_one_downbeat, song.cycle_beats, song.cycle_accents,
       song.language, song.id);

    -- The words, each line with its writer and its colour, as the sheet
    -- shows them. A fresh song starts its history at revision 1; what the
    -- original's lines went through is the original's. Cut lines stay cut
    -- (0153): they are their writer's, not the song's. Word timings follow
    -- each line under its new id, so the sheet lights up on the copy
    -- exactly as it did on the original.
    for each_line in
      select c.*
      from public.contributions c
      where c.project_id = song.id and c.deleted_at is null
      order by c.position, c.created_at, c.id
    loop
      new_line := gen_random_uuid();
      insert into public.contributions
        (id, project_id, author_id, author_name, body, color_value, kind,
         revision, position)
      values
        (new_line, made, each_line.author_id, each_line.author_name,
         each_line.body, each_line.color_value, each_line.kind, 1,
         each_line.position);
      insert into public.lyric_sync_cues
        (contribution_id, project_id, start_ms, end_ms, confidence, source)
      select new_line, made, cue.start_ms, cue.end_ms, cue.confidence, cue.source
      from public.lyric_sync_cues cue
      where cue.contribution_id = each_line.id;
    end loop;

    -- The chords, whoever the song is by: a chord chart is not a recording.
    insert into public.chord_cues
      (project_id, start_ms, end_ms, chord, confidence, beat_index, source)
    select made, cue.start_ms, cue.end_ms, cue.chord, cue.confidence,
           cue.beat_index, cue.source
    from public.chord_cues cue
    where cue.project_id = song.id;

    -- The recording is not written here. Storage has to copy the object
    -- first, which only the app can ask for, and attach_sent_recording
    -- below puts the rows on the copy once it has. Until then the copy has
    -- no recording, which is a true thing for it to say.

    -- Quietly, and only if they want to hear about their songs at all.
    -- notify_user checks that switch itself; nothing here second-guesses it.
    perform private.notify_user(
      student,
      'project_update',
      teacher_name || ' sent you a song',
      made_title,
      target,
      made,
      null,
      me
    );

    to_room := target;
    song_copy := made;
    recording := song_file.storage_path;
    fresh := true;
    return next;
  end loop;

  return;
end;
$fn$;

revoke all on function public.send_song_to_students(uuid, uuid[]) from public, anon;
grant execute on function public.send_song_to_students(uuid, uuid[]) to authenticated;
