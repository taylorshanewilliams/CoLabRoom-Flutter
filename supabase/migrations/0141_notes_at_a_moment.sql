-- A note pinned to a moment in a recording.
--
-- Every comment in this app attaches to a lyric line (public.comments.
-- contribution_id, 0001). So the one thing anybody actually says about a
-- recording -- "you rushed into the turnaround", "that's the 3rd, yes" --
-- has nowhere to live except a sentence in a thread that does not say when.
-- Nothing in the database can point at 1:48 of a take.
--
-- Every Musician, Same Song, 17 September 2026: this is one of the three
-- shared primitives. A teacher answering a student's take, a bandmate saying
-- where the bass drops out, and somebody marking their own second verse are
-- the same object -- a moment, and words about it.
--
-- What it is not: a score, a count, or a rating. There is no number field
-- here and no "notes left" tally, because once a number exists somebody asks
-- to show it to the student.

-- ---------------------------------------------------------------------
-- A word for it
-- ---------------------------------------------------------------------

-- On its own and first, the way 0131 and 0133 did it: a new enum value
-- cannot be *evaluated* in the transaction that adds it. The only place
-- 'moment_note' is used below is inside plpgsql function bodies, which are
-- parsed now and planned when they are first called -- in a later
-- transaction. Nothing in this file compares or casts it at DDL time, which
-- is why this can sit in the same migration.
alter type public.notification_type add value if not exists 'moment_note';

-- ---------------------------------------------------------------------
-- The notes
-- ---------------------------------------------------------------------

create table public.moment_notes (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  -- Null means the song's own recording -- the reference track the chords
  -- and words were derived from, which is not a row in song_layers and is
  -- the first lane on the Takes screen.
  layer_id uuid references public.song_layers(id) on delete cascade,
  at_ms integer not null check (at_ms >= 0),
  -- A range, when the note is about a passage rather than an instant.
  end_ms integer check (end_ms is null or end_ms > at_ms),
  body text not null check (char_length(trim(body)) between 1 and 1000),
  author_id uuid not null default auth.uid()
    references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);

-- Ordered by the moment, not by when it was typed: the list under a take
-- reads down the recording, and three notes written in one pass are read in
-- the order they will be played.
create index moment_notes_recording_idx
  on public.moment_notes (project_id, layer_id, at_ms);

comment on table public.moment_notes is
  'Words about one moment of a recording. Readable by exactly the people who '
  'can hear that recording (0057): an unshared take is heard only by whoever '
  'recorded it, so nobody else can read or write notes on it.';
comment on column public.moment_notes.layer_id is
  'The take this is about, or null for the song''s own recording. Cascades '
  'rather than nulling on delete: a note left pointing at nothing would read '
  'as a note on the song''s own recording, which is a different audience.';

alter table public.moment_notes enable row level security;

-- ---------------------------------------------------------------------
-- Who can hear it, which is who can read and write about it
-- ---------------------------------------------------------------------

-- One function, because the read policy, the insert policy and the trigger
-- below all need the same answer and three copies of it would drift.
--
-- It is the 0057 rule, reached through 0094's helpers: room or song
-- membership, and for a take, that the take has been shared or is your own.
-- Deliberately *narrower* than the song's read policy, which also admits
-- Open Mic listeners, showcased songs and anybody who has been asked
-- (0094). A note is not a public comment: somebody who found a song on the
-- Open Mic can hear it and has no business pinning words onto it, or reading
-- what a band said to each other about bar 9.
create or replace function private.can_hear_recording(
  target_project uuid,
  target_layer uuid
)
returns boolean
language sql
stable
security definer set search_path = ''
as $fn$
  select case
    when target_layer is null then exists (
      select 1 from public.projects p
      where p.id = target_project
        and (private.is_room_member(p.room_id) or private.is_project_member(p.id))
    )
    else exists (
      select 1
      from public.song_layers l
      join public.projects p on p.id = l.project_id
      where l.id = target_layer
        -- The pair has to agree, or a note could be filed against one song
        -- and read on another.
        and l.project_id = target_project
        and (l.shared_at is not null or l.recorded_by = (select auth.uid()))
        and (private.is_room_member(p.room_id) or private.is_project_member(p.id))
    )
  end;
$fn$;

revoke all on function private.can_hear_recording(uuid, uuid) from public, anon;
grant execute on function private.can_hear_recording(uuid, uuid) to authenticated;

create policy moment_notes_read on public.moment_notes
for select to authenticated using (
  deleted_at is null
  and private.can_hear_recording(project_id, layer_id)
);

create policy moment_notes_write on public.moment_notes
for insert to authenticated with check (
  author_id = (select auth.uid())
  and private.can_hear_recording(project_id, layer_id)
);

revoke all on table public.moment_notes from anon;
grant select, insert on table public.moment_notes to authenticated;

-- Taking your own words back.
--
-- Soft, and through a function rather than an update policy. An update
-- policy narrow enough to allow only this column cannot be written -- WITH
-- CHECK cannot see the old row -- so the only honest options are a policy
-- that lets an author rewrite a note after it has been read, or this.
-- There is deliberately no update or delete policy on the table at all.
create or replace function public.delete_moment_note(target_note uuid)
returns void
language sql
security definer set search_path = ''
as $fn$
  update public.moment_notes
  set deleted_at = now()
  where id = target_note
    and author_id = (select auth.uid())
    and deleted_at is null;
$fn$;

-- Silent when the note is not yours, the way unshare_layer is: it says
-- nothing about whether a note exists at an id you were not going to be
-- shown anyway.
revoke all on function public.delete_moment_note(uuid) from public, anon;
grant execute on function public.delete_moment_note(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Telling the one person it is about
-- ---------------------------------------------------------------------

-- As 0136, with one branch added. Notes about your own playing are somebody
-- else's activity arriving uninvited, which is what the project-updates
-- switch already covers -- and the person who turned that off is the person
-- who does not want to be told a bandmate did something to their song.
--
-- The early return on `target_user = notif_actor` is what keeps somebody
-- from being told about their own note.
create or replace function private.notify_user(
  target_user uuid,
  notif_type public.notification_type,
  notif_title text,
  notif_body text,
  target_room uuid default null,
  target_project uuid default null,
  target_invitation uuid default null,
  notif_actor uuid default null
)
returns void
language plpgsql
security definer set search_path = ''
as $fn$
begin
  if target_user is null or target_user = notif_actor then
    return;
  end if;

  if notif_type in ('invite_received', 'connection_request')
     and not private.wants_invites(target_user) then
    return;
  end if;
  if notif_type in ('invite_accepted', 'invite_declined', 'connection_accepted')
     and not private.wants_invite_responses(target_user) then
    return;
  end if;
  if notif_type = 'project_update' and not private.wants_project_updates(target_user) then
    return;
  end if;
  -- Somebody else's activity arriving uninvited, which is the category every
  -- other switch here covers.
  if notif_type = 'song_ask' and not private.wants_asks(target_user) then
    return;
  end if;
  -- 0136. Messages still arrive in Messages, and a call still shows on the
  -- room; these switches are about being told the moment it happens.
  if notif_type = 'direct_message' and not private.wants_messages(target_user) then
    return;
  end if;
  if notif_type = 'call_started' and not private.wants_calls(target_user) then
    return;
  end if;
  -- 0141. Words about a recording of yours: the same switch as anything else
  -- somebody does to one of your songs.
  if notif_type = 'moment_note' and not private.wants_project_updates(target_user) then
    return;
  end if;

  insert into public.notifications (
    user_id, type, title, body, room_id, project_id, invitation_id, actor_id
  ) values (
    target_user, notif_type, notif_title, notif_body,
    target_room, target_project, target_invitation, notif_actor
  );
end;
$fn$;

revoke all on function private.notify_user(
  uuid, public.notification_type, text, text, uuid, uuid, uuid, uuid
) from public, anon, authenticated;

-- Whoever played it, and nobody else.
--
-- Not the room. A note is one person answering one person -- the whole
-- reason it is worth pinning to 1:48 rather than saying in the thread -- and
-- a room told about every note would be a notification per sentence for
-- people who were not being spoken to.
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
    left(trim(new.body), 200),
    song.room_id,
    new.project_id,
    null,
    new.author_id
  );

  return new;
end;
$fn$;

drop trigger if exists moment_notes_announce on public.moment_notes;
create trigger moment_notes_announce
after insert on public.moment_notes
for each row execute function private.announce_moment_note();
