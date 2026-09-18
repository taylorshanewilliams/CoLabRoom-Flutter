-- A spoken note at a moment.
--
-- Moment notes (0141) are typed. A teacher with a guitar in their hands
-- would rather say it: "there -- lean back on the two and four" takes four
-- seconds to say and a minute to type with a plectrum between two fingers.
--
-- Every Musician, Same Song, 17 September 2026, slice 23. A spoken note is
-- the same object as a typed one -- a moment on a recording, and something
-- about it -- so it is the same row, with a pointer to what was said instead
-- of the words. Everything 0141 decided still holds: the audience is frozen
-- when the note is left, it is readable by exactly the people who can hear
-- the recording, whoever played it is told once, and only its author can
-- take it back. There is no length field here and no length shown anywhere;
-- the app caps a note at a minute and that is the whole of the rule.
--
-- The audio goes up the way a line voice note does (0003): into room-files,
-- under {room}/{project}/..., because every storage policy on that bucket
-- reads the room out of the first segment and the project out of the
-- second, and the takes memory records what a path of any other shape did.

-- ---------------------------------------------------------------------
-- Where the voice lives
-- ---------------------------------------------------------------------

alter table public.moment_notes
  add column voice_path text;

comment on column public.moment_notes.voice_path is
  'The object in room-files holding what was said, at '
  '{room}/{project}/moments/{id}.wav, or null for a typed note. The row is '
  'what makes the object reachable: moment_note_audio_read is keyed on it, '
  'so a note taken back is unhearable at once whether or not the object '
  'was removed. Only the Storage API can remove the object itself (0079).';

-- Words are no longer the only thing a note can be made of. A note still
-- has to say something: no words and no voice is not a note.
alter table public.moment_notes
  alter column body drop not null;

alter table public.moment_notes
  drop constraint moment_notes_body_check;

alter table public.moment_notes
  add constraint moment_notes_body_check
  check (body is null or char_length(trim(body)) between 1 and 1000);

alter table public.moment_notes
  add constraint moment_notes_says_something
  check (body is not null or voice_path is not null);

-- The voice lives in this song's own folder, and nowhere else.
--
-- Without this a row could point at any object in the bucket, and the read
-- policy below would then hand that object to everybody who can read the
-- note -- an unshared take in another song, say, if its path were known.
-- A check rather than a policy because it is a fact about the row, and a
-- check cannot be forgotten by a later policy that restates the rule.
alter table public.moment_notes
  add constraint moment_notes_voice_path_check
  check (
    voice_path is null
    or voice_path like ('%/' || project_id::text || '/moments/%')
  );

-- One object is one note. Two rows pointing at the same audio would be two
-- audiences for one recording, decided by whichever was written second.
create unique index moment_notes_voice_path_key
  on public.moment_notes (voice_path)
  where voice_path is not null;

-- ---------------------------------------------------------------------
-- Who can hear it, which is who can read the note
-- ---------------------------------------------------------------------

-- Keyed on the row, the way song_layer_files_read_members (0038) is keyed
-- on the take, and it is moment_notes_read's rule restated: the author, or
-- anybody who could hear the recording when the note was left and can hear
-- it now. Restated rather than left to the row's own policy so that the
-- two are read side by side, and so that a note taken back is unhearable
-- the moment delete_moment_note stamps it.
--
-- Said plainly: room_files_read_members already admits every member of the
-- room in the first path segment to every object under it, as it does for
-- an unshared take. So for somebody in the room who cannot read the note,
-- the row is the gate and the random id in the path is the lock, which is
-- the same lock a draft take has. Somebody outside the room gets nothing
-- from either policy.
drop policy if exists moment_note_audio_read on storage.objects;
create policy moment_note_audio_read on storage.objects
for select to authenticated using (
  bucket_id = 'room-files'
  and exists (
    select 1 from public.moment_notes n
    where n.voice_path = objects.name
      and n.deleted_at is null
      and (
        n.author_id = (select auth.uid())
        or (n.on_shared_take and private.can_hear_recording(n.project_id, n.layer_id))
      )
  )
);

-- Written before the row exists, so this one has to trust the path: the
-- bytes go up first and the row is inserted once they are there, the way
-- a take is (0041). Which recording the note is about is not in the path,
-- so the row's own insert policy is what decides that; this only asks that
-- the writer belongs to the song in the second segment.
--
-- Members, not editors: a typed note may be left by anybody who can hear
-- the recording, a viewer in a class room included (0148 lets a viewer
-- talk), and a spoken note has the same permissions as a typed one.
drop policy if exists moment_note_audio_write on storage.objects;
create policy moment_note_audio_write on storage.objects
for insert to authenticated with check (
  bucket_id = 'room-files'
  and name like '%/moments/%'
  and array_length(storage.foldername(name), 1) >= 3
  and exists (
    select 1 from public.projects p
    where p.id = private.as_uuid((storage.foldername(name))[2])
      and (private.is_room_member(p.room_id) or private.is_project_member(p.id))
  )
);

-- Only the one who said it. The app removes the object before it stamps
-- the row, because moment_notes_read hides a stamped row from everybody --
-- including this subquery, which runs as the caller -- and after that
-- nobody could remove the object at all.
drop policy if exists moment_note_audio_delete_author on storage.objects;
create policy moment_note_audio_delete_author on storage.objects
for delete to authenticated using (
  bucket_id = 'room-files'
  and exists (
    select 1 from public.moment_notes n
    where n.voice_path = objects.name
      and n.author_id = (select auth.uid())
  )
);

-- ---------------------------------------------------------------------
-- Telling the one person it is about, when there are no words to quote
-- ---------------------------------------------------------------------

-- As 0141, with one line changed. The card's body used to be the first two
-- hundred characters of what was typed; for a spoken note that is null,
-- and notifications.body is not null (0018), so the insert behind the
-- trigger would have failed and taken the note with it. The card now says
-- the note was spoken, and opening the song is how to hear it.
create or replace function private.announce_moment_note()
returns trigger
language plpgsql
security definer set search_path = ''
as $fn$
declare
  song record;
  played_by uuid;
  author_name text;
  clock text;
begin
  select p.id, p.room_id, p.title, p.created_by, p.account_id into song
  from public.projects p
  where p.id = new.project_id;

  if new.layer_id is null then
    -- The song's own recording belongs to whoever started the song; the
    -- account that owns the room is the fallback, because projects.account_id
    -- has been the room's account since 0043 and created_by is null on songs
    -- made before 0001 recorded it.
    played_by := coalesce(song.created_by, song.account_id);
  else
    select l.recorded_by into played_by
    from public.song_layers l
    where l.id = new.layer_id;
  end if;

  select pr.display_name into author_name
  from public.profiles pr
  where pr.id = new.author_id;

  -- The moment, in the words a person reads off a transport: 1:48.
  clock := (new.at_ms / 60000)::text || ':'
        || lpad(((new.at_ms / 1000) % 60)::text, 2, '0');

  perform private.notify_user(
    played_by,
    'moment_note',
    coalesce(author_name, 'Somebody') || ' left a note at ' || clock,
    coalesce(nullif(left(trim(new.body), 200), ''), 'Said out loud'),
    song.room_id,
    new.project_id,
    null,
    new.author_id
  );

  return new;
end;
$fn$;
