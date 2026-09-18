-- Say where bar 1 is.
--
-- Bar numbers in this app come from the analysis downbeats, and bar 1 is the
-- first one of them (#362). That is right for a song that starts on its own
-- downbeat and wrong for every other kind: a song with a pickup phrase, or a
-- count-in left on the front of the recording, is then one bar off the
-- printed music the teacher is holding, and "bars nine to twelve" means two
-- different passages in the same room. The pickup itself could not be looped
-- at all, because everything ahead of the first downbeat had no number and
-- so could not be asked for (Every Musician, Same Song, 17 September 2026;
-- Taylor's default, decision 4 after wave 1).
--
-- **A shared fact, not a reading.** The same distinction 0144 drew for the
-- key. A person's transpose, their capo, their horn part and whether they
-- read numbers or letters are personal and live on their own device. Where
-- bar 1 is is not one of those: it changes what everybody's bar numbers
-- mean, so it belongs to the song and everybody in the room counts from it.
--
-- **Null is the honest default.** It means nobody has corrected anything,
-- which is true of every song now and will stay true of most of them, and it
-- reads as "bar 1 is the first downbeat" -- exactly what the app did before
-- this column existed. Clearing it is how "Use the detected bars" is spelled.
--
-- **It survives re-analysis** because it is a column on projects rather than
-- on the reference recording. Analysing again rewrites
-- `project_audio_references.downbeats_ms`; it does not touch this. The
-- number is an ordinal into that list, so a re-analysis that finds the same
-- grid keeps the same bar 1, and one that finds a different grid is a
-- different song's worth of downbeats either way.

alter table public.projects
  add column if not exists bar_one_downbeat integer
  -- Which downbeat is bar 1, counting from one. The app clamps it into the
  -- grid it actually has, so a number past the end of a shorter re-analysis
  -- is a stale answer rather than a broken song; a number below one is not
  -- an answer at all.
  check (bar_one_downbeat is null or bar_one_downbeat >= 1);

comment on column public.projects.bar_one_downbeat is
  'Which downbeat of the analysis is bar 1, counting from one. Null means '
  'nobody has said and the first downbeat stands. Set through set_bar_one '
  'by the room''s owner or an editor; survives re-analysis.';

-- ---------------------------------------------------------------------
-- Saying where bar 1 is
-- ---------------------------------------------------------------------

-- Owner or editor, the same people who can say what key the song is in
-- (0144) and whose song it is (0142). Anybody trusted to write on a song is
-- trusted to say where its bars start -- it is usually the player holding
-- the printed part who noticed, not the person who owns the catalog.
-- Somebody who can only look cannot move everybody else's bar numbers.
--
-- A null `in_downbeat` clears it, which is how "Use the detected bars" is
-- spelled. That is a real answer and not a missing argument, so it is not an
-- error.
create or replace function public.set_bar_one(
  target_project uuid,
  in_downbeat integer
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  song record;
  role_here public.room_role;
begin
  if in_downbeat is not null and in_downbeat < 1 then
    raise exception 'Bar 1 has to be one of the downbeats.'
      using errcode = '22023';
  end if;

  select p.id, p.room_id into song
  from public.projects p
  where p.id = target_project and p.deleted_at is null;

  if song.id is null then
    raise exception 'That song does not exist.' using errcode = '22023';
  end if;

  role_here := private.room_role_for(song.room_id);

  -- `is distinct from` twice, not `not in`. room_role_for is null for
  -- somebody who is not in the room, `null not in ('owner', 'editor')` is
  -- null, and `if null then` does not fire -- so the plain form waves through
  -- the exact person the check exists to stop. See 0068.
  if role_here is distinct from 'owner' and role_here is distinct from 'editor'
  then
    raise exception 'Only somebody who can edit this song can say where bar 1 is.'
      using errcode = '42501';
  end if;

  update public.projects
  set bar_one_downbeat = in_downbeat
  where id = target_project and deleted_at is null;
end;
$fn$;

revoke all on function public.set_bar_one(uuid, integer) from public, anon;
grant execute on function public.set_bar_one(uuid, integer) to authenticated;

-- ---------------------------------------------------------------------
-- The song a teacher sends carries where bar 1 is
-- ---------------------------------------------------------------------

-- Restated from 0149, its latest definition, with one change: the copy made
-- for each student carries `bar_one_downbeat` the way it already carries
-- `song_origin` and `key_override`. All three are facts about the song
-- rather than settings on somebody's phone, and this is the flow the whole
-- slice was written for -- a teacher fixes bar 1 on a song with a count-in
-- and sends it to the class, and without this every student's copy counts
-- from the wrong bar while the teacher says "bars nine to twelve" off the
-- printed part (review, 18 September 2026).
--
-- The downbeats themselves arrive later, on attach_sent_recording; bar 1 is
-- an ordinal into that list, so it is written here and waits for them.
--
-- Everything else below is 0149 unchanged, copied whole rather than patched
-- so that the function has one readable definition at its highest number.
drop function if exists public.send_song_to_students(uuid, uuid[]);

create function public.send_song_to_students(
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

    -- The song. Its origin, its key and where its bar 1 is go with it: whose
    -- song this is does not change by being copied, and the band's key (0144)
    -- and bar 1 (0161) are facts about the song. The picture does not: it
    -- lives under the original room's folder, where the student cannot see
    -- it, and a tile that fails to load is worse than the plain one. Nothing
    -- public, nothing finished.
    made := gen_random_uuid();
    insert into public.projects
      (id, room_id, account_id, title, description, status, created_by,
       sort_order, song_origin, key_override, bar_one_downbeat, copied_from)
    values
      (made, target, lesson_account, made_title, song.description, 'active',
       me, next_sort, song.song_origin, song.key_override,
       song.bar_one_downbeat, song.id);

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
