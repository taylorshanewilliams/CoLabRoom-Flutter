-- Count your own cycle.
--
-- Bars in this app are the analysis downbeats (#362), numbered from wherever
-- the band says bar 1 is (0161). That is a bar of four, or of three, or of
-- whatever the beat tracker heard -- and for a great deal of the music people
-- actually play it is the wrong unit entirely. A seven counted 3+2+2, a
-- sixteen, a twelve with its own inner shape: none of them is a run of
-- four-beat bars, and asking somebody to find "bars nine to twelve" in a
-- count they do not use is asking them to do arithmetic on a music stand
-- (Every Musician, Same Song, 17 September 2026, section 4).
--
-- **No library of names.** Decision 20. The obvious build was a table of
-- talas, compases, iqa'at and usul shipped with the app, and the obvious
-- build would have put somebody's transcription of somebody else's tradition
-- in front of a player with nobody here able to check a line of it. What a
-- musician needs is smaller and truer, and they already know it: a count and
-- its stresses. "7: 3+2+2" is a whole cycle and claims to be nothing else.
--
-- **A shared fact, not a reading.** The fourth one, after the band's key
-- (0144), where bar 1 is (0161) and what the song is sung in (0163), and
-- shared for the same reason as all three: a person's numbers, capo, horn
-- part and transpose live on their own phone, but what the room counts
-- changes what everybody's numbers mean. "From cycle nine" has to be the
-- same nine on every phone in the room.
--
-- **Null is the honest default**, as it was for all of those: nobody has
-- counted a cycle, which is true of every song now and will stay true of
-- most, and it reads as the analysed bars -- exactly what the app did before
-- these columns existed. Clearing them is how "Use the detected bars" is
-- spelled here too.
--
-- **It survives re-analysis** because it lives on the song rather than on the
-- reference recording. Analysing again rewrites `beats_ms` and
-- `downbeats_ms`; it does not touch these. The app lays the count over
-- whatever beat grid it then has.

alter table public.projects
  add column if not exists cycle_beats integer
  -- How many beats go round before the count starts again. Two is the
  -- shortest thing that goes round at all; sixty-four is past any cycle a
  -- person counts and well inside what a row of taps can be read at. Null is
  -- nobody having counted one.
  check (cycle_beats is null or (cycle_beats >= 2 and cycle_beats <= 64));

alter table public.projects
  add column if not exists cycle_accents integer[]
  -- Which beats after the first are played heavy, ascending. The first beat
  -- is never in here: it is where the count comes back to, it is always the
  -- heaviest, and there is nothing to say about it.
  --
  -- The values themselves are ranged by set_song_cycle below and tidied
  -- again when the app reads them (SongCycle.of), not by a check constraint:
  -- Postgres will not take a subquery in a check, so unnesting the array to
  -- test every element is not available here. What a check can say without
  -- one is said: there is no stress list without a count to put it in, and
  -- never more stresses than the cycle has beats after its first.
  check (
    cycle_accents is null
    or (
      cycle_beats is not null
      and coalesce(array_length(cycle_accents, 1), 0) < cycle_beats
    )
  );

comment on column public.projects.cycle_beats is
  'How many beats the cycle this song goes round in has. Null means nobody '
  'has counted one and the analysed bars stand. Set through set_song_cycle '
  'by the room''s owner or an editor; survives re-analysis.';

comment on column public.projects.cycle_accents is
  'Which beats of the cycle after the first are played heavy, ascending. '
  'Null or empty is a cycle nobody has said anything inside.';

-- ---------------------------------------------------------------------
-- Counting the cycle
-- ---------------------------------------------------------------------

-- Owner or editor: the same two who may say what key the song is in (0144),
-- whose song it is (0142) and where bar 1 is (0161). Anybody trusted to write
-- on a song is trusted to say what it is counted in -- it is usually the
-- person playing the thing who knows, not the person who owns the catalog.
-- Somebody who can only look cannot move everybody else's numbers.
--
-- A null `in_beats` clears it, which is how "Use the detected bars" is spelled
-- here. That is a real answer and not a missing argument, so it is not an
-- error, and it takes the stresses with it: a stress list with no count to sit
-- in is not a cycle.
--
-- The stresses are tidied rather than refused. A number outside the count, a
-- repeat, a null in the array, the first beat named explicitly: each of those
-- is somebody tapping, or a build that counted differently, and none of them
-- is worth a sentence on a music stand. What comes out is ascending, without
-- repeats, with no nulls, every value between 2 and the count.
create or replace function public.set_song_cycle(
  target_project uuid,
  in_beats integer,
  in_accents integer[] default null
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  song record;
  role_here public.room_role;
  clean integer[];
begin
  if in_beats is not null and (in_beats < 2 or in_beats > 64) then
    raise exception 'A cycle goes round in between 2 and 64 beats.'
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
    raise exception 'Only somebody who can edit this song can count its cycle.'
      using errcode = '42501';
  end if;

  if in_beats is null then
    update public.projects
    set cycle_beats = null, cycle_accents = null
    where id = target_project and deleted_at is null;
    return;
  end if;

  -- A null element of the array fails `a >= 2`, which is null rather than
  -- true, so the where clause drops it along with everything out of range.
  select coalesce(array_agg(distinct a order by a), '{}'::integer[])
    into clean
  from unnest(coalesce(in_accents, '{}'::integer[])) as a
  where a >= 2 and a <= in_beats;

  update public.projects
  set cycle_beats = in_beats, cycle_accents = clean
  where id = target_project and deleted_at is null;
end;
$fn$;

revoke all on function public.set_song_cycle(uuid, integer, integer[])
  from public, anon;
grant execute on function public.set_song_cycle(uuid, integer, integer[])
  to authenticated;

-- ---------------------------------------------------------------------
-- And it goes with the song when a teacher sends it
-- ---------------------------------------------------------------------

-- send_song_to_students copies a song into each student's lesson room, and
-- 0161 restated it for exactly this reason: the facts about a song have to
-- survive the copy or the teacher and the class end up reading different
-- numbers off the same page. The cycle is one of those facts, so without
-- this a teacher counts a seven, sends the song to the class, and every
-- student's copy counts the analysed bars while the teacher says "from cycle
-- nine" (review, 18 September 2026).
--
-- Restated from its latest definition, which is 0161's -- 0163 added
-- projects.language without touching this function, and nothing newer
-- touches it either. Only the insert changes; everything else is 0161's text
-- unaltered.
--
-- One thing this does NOT carry, because it is not this slice's to decide:
-- projects.language (0163) is a shared fact of the same kind and is not
-- copied to the student either. Left alone rather than quietly folded in
-- here, where nobody reviewing a cycle would be looking for it.

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

    -- The song. Its origin, its key, where its bar 1 is and the cycle the
    -- band counts go with it: whose song this is does not change by being
    -- copied, and the band's key (0144), bar 1 (0161) and the cycle (0162)
    -- are facts about the song. A teacher who counts a seven and then says
    -- "from cycle nine" has to be saying it about the copy on the stand in
    -- front of the student. The picture does not: it
    -- lives under the original room's folder, where the student cannot see
    -- it, and a tile that fails to load is worse than the plain one. Nothing
    -- public, nothing finished.
    made := gen_random_uuid();
    insert into public.projects
      (id, room_id, account_id, title, description, status, created_by,
       sort_order, song_origin, key_override, bar_one_downbeat,
       cycle_beats, cycle_accents, copied_from)
    values
      (made, target, lesson_account, made_title, song.description, 'active',
       me, next_sort, song.song_origin, song.key_override,
       song.bar_one_downbeat, song.cycle_beats, song.cycle_accents, song.id);

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
