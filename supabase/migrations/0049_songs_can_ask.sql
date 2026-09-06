-- A song can say what it needs, and a person can say they heard one.
--
-- Both halves come from the same observation. South Dean has nine songs and
-- one take between them, and reading that as an answer rate would be wrong:
-- most of those songs were never asking for anything. Taylor, 2026-09-05:
-- "sometimes we just want to share ideas ... it doesn't always need any input
-- or takes added."
--
-- So sharing stays the default and stays obligation-free, and asking becomes
-- something a song does explicitly. Two shapes of asking, because musicians
-- have two different problems:
--
--   * an **open** ask, "I don't know what this needs, what do you hear?",
--     which is the honest state of most unfinished songs and costs the person
--     posting it no decision at all;
--   * a **specific** ask, "this needs a bridge", for when you know exactly
--     what you want and only need somebody who can play it.
--
-- One table, one nullable column: a null `part` is an open ask. They are the
-- same object because the audience dial, the answering flow and the closing
-- flow are identical for both, and a product that only serves the specific
-- one is a gig board.
--
-- `audience` is on the ask from the first day even though only 'room' is
-- reachable today. The worldwide version of this app is this column moving,
-- not a second system bolted alongside the first, and a column that exists
-- from the start is a column no later migration has to backfill.

create table public.project_asks (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,

  -- Set null rather than cascade: an ask outliving the person who left is
  -- better than a song silently stopping asking.
  asked_by uuid default auth.uid() references public.profiles(id) on delete set null,

  -- Null means open. Free text otherwise, matching song_layers.part and for
  -- the same reason given there: a list that needs a migration every time a
  -- band names something new is a list that will be wrong.
  part text check (part is null or char_length(trim(part)) between 1 and 40),

  -- What they would say out loud about it. Short on purpose, because this is
  -- a caption and not a brief.
  note text not null default '' check (char_length(note) <= 280),

  audience text not null default 'room'
    check (audience in ('room', 'collaborators', 'public')),

  status text not null default 'open' check (status in ('open', 'closed')),

  created_at timestamptz not null default now(),
  closed_at timestamptz
);

create index project_asks_project_idx
  on public.project_asks (project_id, created_at desc);

-- One open ask per song per part, so a song cannot ask twice for the same
-- thing and cannot hold two open general asks. coalesce because null is not
-- equal to null, and a plain unique index would allow unlimited open ones.
create unique index project_asks_one_open_per_part
  on public.project_asks (project_id, coalesce(part, ''))
  where status = 'open';

alter table public.project_asks enable row level security;

create policy project_asks_read_members on public.project_asks
for select to authenticated using (
  exists (
    select 1 from public.projects p
    where p.id = project_id and private.is_room_member(p.room_id)
  )
);

-- Anybody in the room can ask, not only whoever uploaded the song. A bandmate
-- saying "this wants drums" is a normal thing to happen in a band, and there
-- is no reason the app should make the owner say it for them.
create policy project_asks_write_members on public.project_asks
for insert to authenticated with check (
  asked_by = (select auth.uid())
  and exists (
    select 1 from public.projects p
    where p.id = project_id and private.is_room_member(p.room_id)
  )
);

-- Closing it is narrower: the person who asked, or the room owner.
create policy project_asks_close on public.project_asks
for update to authenticated using (
  asked_by = (select auth.uid())
  or exists (
    select 1 from public.projects p
    where p.id = project_id and private.room_role_for(p.room_id) = 'owner'
  )
);

-- ---------------------------------------------------------------------
-- Heard it.
-- ---------------------------------------------------------------------

-- Not project_reads, and the difference is the whole point.
--
-- project_reads (0042) records that somebody *opened* a song, so a badge can
-- say there is something new. Its own migration is explicit that it must stay
-- private: there is no legitimate reason for one member to see when another
-- last listened, that is a presence signal this app has deliberately decided
-- not to have, and leaving it readable would be shipping it by accident. That
-- reasoning still holds and this table does not touch it.
--
-- This is the opposite act. Read state is something the app observes; a nod is
-- something a person chooses to send. It exists because a shared idea
-- currently returns silence: the only response the app offers is a take, which
-- costs real effort, so the cheap thing to share has no cheap way to be
-- answered, and silence reads as indifference even when everybody liked it.
--
-- Deliberately not a like count. A room sees *who* nodded, never a running
-- total, and nothing aggregates across a profile. A number that goes up is a
-- number people start playing to, and then what gets posted changes to suit
-- it.
create table public.project_nods (
  project_id uuid not null references public.projects(id) on delete cascade,
  profile_id uuid not null default auth.uid()
    references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (project_id, profile_id)
);

alter table public.project_nods enable row level security;

-- Visible to the room, unlike read state. Being seen is the entire function:
-- a nod nobody can see is silence with extra steps.
create policy project_nods_read_members on public.project_nods
for select to authenticated using (
  exists (
    select 1 from public.projects p
    where p.id = project_id and private.is_room_member(p.room_id)
  )
);

create policy project_nods_write_own on public.project_nods
for insert to authenticated with check (
  profile_id = (select auth.uid())
  and exists (
    select 1 from public.projects p
    where p.id = project_id and private.is_room_member(p.room_id)
  )
);

-- Takeable back. Somebody who taps it by accident should not have to live with
-- having said something they did not mean.
create policy project_nods_delete_own on public.project_nods
for delete to authenticated using (profile_id = (select auth.uid()));

-- ---------------------------------------------------------------------
-- Telling people, which is the part that actually fixes the defect.
-- ---------------------------------------------------------------------

-- 'asked' joins the song's own activity stream. 0046 drew the line this
-- follows: edits belong on the song and not in an inbox. An ask belongs in
-- both, on the song because that is where the context is, and in the inbox
-- because unlike an edit it is addressed to somebody.
alter table public.project_events drop constraint project_events_kind_check;
alter table public.project_events add constraint project_events_kind_check
  check (kind in ('message', 'edited', 'analyzed', 'recording', 'joined', 'asked'));

create or replace function private.announce_project_ask()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
declare
  song_title text;
  song_room uuid;
  asker_name text;
  said text;
  member record;
begin
  select p.title, p.room_id into song_title, song_room
  from public.projects p
  where p.id = new.project_id;

  select pr.display_name into asker_name
  from public.profiles pr
  where pr.id = new.asked_by;

  -- The two shapes read differently to a person, so they are worded
  -- differently rather than being one string with a slot in the middle.
  said := case
    when new.part is null
      then coalesce(asker_name, 'Somebody') || ' is asking what ' ||
           coalesce(song_title, 'a song') || ' needs'
    else coalesce(asker_name, 'Somebody') || ' says ' ||
         coalesce(song_title, 'a song') || ' needs ' || new.part
  end;

  insert into public.project_events (project_id, actor_id, kind, body)
  values (new.project_id, new.asked_by, 'asked', said);

  -- Only the room, whatever the audience column says. The other two positions
  -- on that dial are found by looking rather than by being told, and a public
  -- ask that pushed itself at strangers would be the spam problem this whole
  -- design exists to avoid.
  if new.audience = 'room' and song_room is not null then
    for member in
      select rm.user_id from public.room_members rm
      where rm.room_id = song_room
        and rm.user_id is distinct from new.asked_by
    loop
      perform private.notify_user(
        member.user_id,
        'song_ask',
        said,
        case when new.note = '' then 'Open the song to add a take.' else new.note end,
        song_room,
        new.project_id,
        null,
        new.asked_by
      );
    end loop;
  end if;

  return new;
end;
$$;

drop trigger if exists project_asks_announce on public.project_asks;
create trigger project_asks_announce
after insert on public.project_asks
for each row execute function private.announce_project_ask();
