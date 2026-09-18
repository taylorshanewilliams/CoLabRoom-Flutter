-- A song for each student.
--
-- Every Musician, Same Song, 17 September 2026: build-order slice 19, and
-- the first half of an assignment. A teacher picks one of their own songs
-- and sends a copy into the lesson rooms they choose, one copy a room, so
-- each student works on their own copy where only the two of them can hear
-- it. The brief that goes with it (a passage, a speed, what I am listening
-- for) is slice 20; this is the song arriving.
--
-- **Copied, never shared.** The plan weighed granting every student access
-- to one source song and chose the copy: a song inside a two-person room is
-- private by construction, where sharing one source would have needed the
-- most bug-prone RLS change there is, on takes and on storage. What is
-- copied is the song's own rows -- the project, the words with their
-- writers, the chords and the word timings -- and, when the song may carry
-- audio, the recording itself.
--
-- **The recording is copied too, not pointed at.** The first draft of this
-- had every copy's files row name the teacher's own storage object, so that
-- nothing was analysed twice. But a files row owns its object everywhere
-- else: the delete policy (0013) lets anybody who edits a project delete
-- the object its files row names, and the app removes that object when a
-- recording is replaced or taken off a song. One object behind ten rows
-- would have let a student delete the teacher's master recording from
-- their own copy, and the teacher replacing their recording would have
-- silenced every copy at once, quietly, because those removals are wrapped
-- in try/catch. So each copy gets an object of its own under its own
-- folder, {lesson room}/{copy}/analysis/..., where the student may hear it
-- (room_files_read_members) and may delete only it. SQL cannot write
-- storage, so the copy is made in two halves: send_song_to_students makes
-- the song and says which recording should follow it; the app has Storage
-- copy the object server-side; attach_sent_recording puts the files row
-- and the analysis on the copy. Nothing is analysed again either way: the
-- copy's files row carries the audio's hash, and analysis_cache (0024) is
-- keyed by it.
--
-- **Whose song it is, asked twice.** Who may send is the owner of the room
-- the song lives in, and nobody else: not an editor, and not somebody
-- invited to the song on its own (0013). The same test put_on_open_mic
-- makes (0067, 0142), for the same reason: an editor can write on a song,
-- and deciding that nine other rooms may have it is a different size of
-- decision, and belongs to whoever owns the catalog it lives in. The
-- plan's words are "one of their own songs", and a co-writer's lines,
-- with their name on each, reach only the rooms the owner of the room
-- they were written in chose. What follows the song is the other
-- question: audio is copied only for a song marked ours or public domain
-- (0142). For somebody else's song the copy carries the words and the
-- chords and nothing that plays; for a song nobody has been asked about
-- yet, the same, because null is not an answer and the app asks before it
-- sends. Stems are never copied, and neither is anybody's take: a take is
-- one person's, and it stays where they put it.
--
-- **Each copy belongs to the lesson room.** The room is the teacher's
-- (0129), so the copy's account is the teacher's, the student is an editor
-- in it and can write in it, and what the student sends on it reaches the
-- teacher the way a take in a lesson room already does. The original is
-- untouched: it is still the teacher's, in the room it was in.
--
-- **Sending twice sends nothing new.** A room that already holds a live
-- copy of this song is skipped, so a tap that was retried, or a second send
-- a week later, does not put two of the same song in front of a student.
-- The one exception is a copy whose recording never arrived -- the object
-- is copied after this function returns, and a phone can lose its network
-- between the two -- which is handed back so that sending again finishes
-- the job, and marked as not fresh: a student who has had the song for a
-- week did not receive it today. The app counts the fresh rows for its one
-- sentence ("Sent to 9 students") and counts nothing else.
--
-- **A lesson the student has left is skipped, not refused.** lesson_rooms
-- outlives the student: leaving, being removed and blocking all leave the
-- row (only a re-join replaces it, 0129). The app does not list such a
-- room, but a list can go stale between opening the sheet and tapping
-- Send, and a refusal there would send nothing to anybody and say only
-- that the teacher lacks access. A room that is not the caller's at all is
-- still refused, and one such room still refuses the whole send.
--
-- **The student is told** through the switch that already covers somebody
-- doing something to one of their songs (project_update, as 0143 uses it):
-- a teacher put a song in their room, which is what that switch means.

-- Which song a copy was made from, when it was made by this function. Null
-- for every song that was written rather than sent, which is nearly all of
-- them. Set null when the source goes: the copy is the student's now and
-- outlives it. Not a policy of its own -- projects_update_editors (0005)
-- can write it through PostgREST, and all it changes is whether a later send
-- of the same song skips this room.
alter table public.projects
  add column if not exists copied_from uuid
    references public.projects(id) on delete set null;

create index if not exists projects_copied_from_idx
  on public.projects (copied_from) where copied_from is not null;

comment on column public.projects.copied_from is
  'The song this one was copied from by send_song_to_students (0149), or '
  'null for a song that was written rather than sent. Cleared when the '
  'source is deleted; the copy stays.';

-- ---------------------------------------------------------------------
-- What may follow a song
-- ---------------------------------------------------------------------

-- The recording that goes with a song when the person calling sends it,
-- or nothing. Three things have to hold: the song is theirs to send (they
-- own its room, the same test the send itself makes), it is marked ours
-- or public domain (0142), and there is a live recording on it. Asked by
-- both halves of a send so the rule lives in one place. `in` on a null
-- origin is null, and coalesce reads that as no, which is what an
-- unanswered question means; a null role fails `= 'owner'` the same way.
create or replace function private.recording_to_send(song public.projects)
returns public.files
language sql
stable
security definer set search_path = ''
as $fn$
  select f.*
  from public.project_audio_references r
  join public.files f on f.id = r.file_id and f.deleted_at is null
  where r.project_id = song.id
    and coalesce(song.song_origin in ('ours', 'public_domain'), false)
    and private.room_role_for(song.room_id) = 'owner'
  limit 1;
$fn$;

revoke all on function private.recording_to_send(public.projects)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Send to students
-- ---------------------------------------------------------------------

-- Copies in_project into each of in_rooms, and returns the rooms that
-- received something with the copy's id, whether the copy is fresh (false
-- for a copy handed back only so its recording can be finished) and, when
-- a recording should follow it, the storage path of the recording to copy
-- (null when nothing plays). Every room must be a lesson room of a link
-- the caller teaches and the caller must still own it; one wrong room in
-- the list sends nothing, because the function raises and the statement
-- rolls back with it. The song's own room, a lesson the student has left,
-- and a room already holding a finished copy are skipped and do not come
-- back.
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

    -- The song. Its origin and its key go with it: whose song this is does
    -- not change by being copied, and the band's key (0144) is a fact about
    -- the song. The picture does not: it lives under the original room's
    -- folder, where the student cannot see it, and a tile that fails to load
    -- is worse than the plain one. Nothing public, nothing finished.
    made := gen_random_uuid();
    insert into public.projects
      (id, room_id, account_id, title, description, status, created_by,
       sort_order, song_origin, key_override, copied_from)
    values
      (made, target, lesson_account, made_title, song.description, 'active',
       me, next_sort, song.song_origin, song.key_override, song.id);

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

-- ---------------------------------------------------------------------
-- The recording arriving
-- ---------------------------------------------------------------------

-- The second half of a send: once Storage has copied the recording to
-- in_storage_path, puts a files row and the original's analysis on the copy
-- in_copy. Only the person who sent the copy, still owning its room, may
-- do this, and only for a recording that may follow the song at all
-- (recording_to_send above, asked again here so that a teacher whose song
-- was marked a cover after the send, or who lost the room, cannot finish
-- what the first half would no longer start). The path must be under the
-- copy's own folder, {room}/{copy}/, where only the room's editors may
-- write: a files row is what lets a room hear an object, so a row that
-- could name any object would be a way to hear anything. True when the
-- rows were written; false when the copy already had a recording -- a
-- retried call, or one the student put on it themselves between the two
-- halves -- so that the app knows the object it just copied is not the one
-- the copy plays. No policy lets anybody delete an object no row names
-- (0013 deletes by files row), so the app cannot remove it either; it
-- reports the path instead, because a policy for deleting orphans is more
-- RLS than a race this narrow deserves.
drop function if exists public.attach_sent_recording(uuid, text);

create function public.attach_sent_recording(
  in_copy uuid,
  in_storage_path text
)
returns boolean
language plpgsql
security definer set search_path = ''
as $fn$
declare
  me uuid := auth.uid();
  sent public.projects%rowtype;
  song public.projects%rowtype;
  song_file public.files%rowtype;
  song_ref public.project_audio_references%rowtype;
  own_folder text;
  new_file uuid;
begin
  if me is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;
  if in_copy is null then
    raise exception 'That is not a song you sent.' using errcode = '42501';
  end if;

  select * into sent
  from public.projects p
  where p.id = in_copy and p.deleted_at is null;
  if sent.id is null then
    raise exception 'That song could not be found.' using errcode = '22023';
  end if;
  -- Theirs to finish: a copy they made, in a room they still own.
  if sent.copied_from is null
     or sent.created_by is distinct from me
     or private.room_role_for(sent.room_id) is distinct from 'owner' then
    raise exception 'That is not a song you sent.' using errcode = '42501';
  end if;

  -- Already there: a retried call, or a recording the student put on it
  -- themselves in the meantime. Either way the copy has what it needs.
  if exists (
    select 1 from public.project_audio_references r where r.project_id = sent.id
  ) then
    return false;
  end if;

  own_folder := sent.room_id::text || '/' || sent.id::text || '/';
  if in_storage_path is null
     or not starts_with(in_storage_path, own_folder)
     or char_length(in_storage_path) <= char_length(own_folder) then
    raise exception 'That is not where the copy''s recording goes.'
      using errcode = '22023';
  end if;

  -- The source, still there, still theirs, still with a recording that may
  -- go. The copy is its own song now, so a source that has gone is a
  -- recording that cannot arrive rather than a copy that cannot exist.
  select * into song
  from public.projects p
  where p.id = sent.copied_from and p.deleted_at is null;
  if song.id is null then
    raise exception 'The song this was copied from is gone.' using errcode = '22023';
  end if;
  song_file := private.recording_to_send(song);
  if song_file.id is null then
    raise exception 'That recording is not yours to send.' using errcode = '42501';
  end if;
  select * into song_ref
  from public.project_audio_references r
  where r.project_id = song.id;

  -- The files row, naming the copy's own object and carrying the hash the
  -- cache is keyed by, and the analysis that was made from the same audio.
  -- A recording still being analysed, or one whose analysis failed, arrives
  -- as merely uploaded with no job attached: the job is the original's, and
  -- a student should not inherit an error they never caused. Asking for the
  -- analysis on the copy then finds the finished one in analysis_cache.
  new_file := gen_random_uuid();
  insert into public.files
    (id, project_id, uploaded_by, storage_path, display_name, mime_type,
     byte_size, duration_ms, audio_sha256)
  values
    (new_file, sent.id, me, in_storage_path, song_file.display_name,
     song_file.mime_type, song_file.byte_size, song_file.duration_ms,
     song_file.audio_sha256);
  insert into public.project_audio_references
    (project_id, file_id, uploaded_by, analysis_state, duration_ms, bpm,
     musical_key, analyzer_version, lyric_confidence, chord_confidence,
     chord_coverage, transcript_text, transcript_words, analysis_warning,
     beats_ms, downbeats_ms, beats_per_bar, structure_sections,
     instruments, melody, melody_low_midi, melody_high_midi)
  values
    (sent.id, new_file, me,
     case when song_ref.analysis_state = 'ready' then 'ready' else 'uploaded' end,
     song_ref.duration_ms, song_ref.bpm, song_ref.musical_key,
     song_ref.analyzer_version, song_ref.lyric_confidence,
     song_ref.chord_confidence, song_ref.chord_coverage,
     song_ref.transcript_text, song_ref.transcript_words,
     song_ref.analysis_warning, song_ref.beats_ms, song_ref.downbeats_ms,
     song_ref.beats_per_bar, song_ref.structure_sections,
     song_ref.instruments, song_ref.melody, song_ref.melody_low_midi,
     song_ref.melody_high_midi);
  return true;
end;
$fn$;

revoke all on function public.attach_sent_recording(uuid, text) from public, anon;
grant execute on function public.attach_sent_recording(uuid, text) to authenticated;
