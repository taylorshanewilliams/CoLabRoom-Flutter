-- Asking one particular musician.
--
-- Open Mic can find somebody who plays what a song needs, and their profile
-- can show you what they sound like — and then the app stops. There is no
-- verb on that page. You can look at a bass player in your city and do
-- nothing about it, which makes the whole feature a browsing exercise, and is
-- why nobody has turned themselves on: there is nothing on the other side of
-- being listed.
--
-- **An ask grants nothing.** That is the design. Sending one is a message,
-- not a key: it tells somebody a song of yours wants a part, and the only
-- thing that gives them access is them saying yes. Getting that backwards —
-- adding a stranger to a song and then telling them about it — would be
-- handing out other people's unfinished work to anybody with a profile.
--
-- Accepting reuses the project membership from 0013, which is scoped to one
-- song rather than a whole catalog. Somebody who agrees to play bass on one
-- track gets that track, not the eleven others filed beside it.

alter table public.project_asks
  add column if not exists asked_of uuid
    references public.profiles(id) on delete cascade;

comment on column public.project_asks.asked_of is
  'The one person this was aimed at. Null on every ask that went to a room '
  'rather than to somebody, which is every ask made before this migration.';

-- 'declined' joins 'open' and 'closed'. A withdrawn ask and a refused one
-- read the same in a list otherwise, and the difference is the whole signal:
-- one says nobody is needed any more, the other says this person said no.
alter table public.project_asks
  drop constraint if exists project_asks_status_check;
alter table public.project_asks
  add constraint project_asks_status_check
  check (status in ('open', 'closed', 'declined'));

alter table public.project_asks
  add column if not exists answered_at timestamptz;

-- One open ask per person per song.
--
-- Not a rate limit on the asker — a cap on what any one musician can be made
-- to read. Somebody who has not answered yet does not need asking again, and
-- an app where a stranger can queue up notifications is one people leave.
create unique index if not exists project_asks_one_open_per_person
  on public.project_asks (project_id, asked_of)
  where asked_of is not null and status = 'open';

-- The person asked can see the ask. Without this the row is invisible to the
-- only person who needs to act on it — they are not in the room yet, which is
-- the entire point of asking them.
drop policy if exists project_asks_read_asked on public.project_asks;
create policy project_asks_read_asked on public.project_asks
for select to authenticated using (asked_of = (select auth.uid()));

-- ---------------------------------------------------------------------
-- Sending it
-- ---------------------------------------------------------------------

create or replace function public.ask_musician(
  target_project uuid,
  target_person uuid,
  in_part text default null,
  in_note text default ''
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  song record;
  asker_name text;
  cleaned_part text;
  new_ask uuid;
begin
  if target_person = auth.uid() then
    raise exception 'You cannot ask yourself.' using errcode = '22023';
  end if;

  select p.id, p.title, p.room_id into song
  from public.projects p
  where p.id = target_project;

  if song.id is null then
    raise exception 'That song does not exist.' using errcode = '22023';
  end if;

  -- You can only offer a song you are actually on. Checked here rather than
  -- left to RLS, because this function is security definer and a definer
  -- function that skips the check is how somebody asks a stranger to play on
  -- a song neither of them can see.
  if not (private.is_room_member(song.room_id)
          or private.is_project_member(song.id)) then
    raise exception 'That is not your song to offer.' using errcode = '42501';
  end if;

  cleaned_part := nullif(trim(coalesce(in_part, '')), '');

  insert into public.project_asks
    (project_id, asked_by, asked_of, part, note, audience)
  values
    (target_project, auth.uid(), target_person, cleaned_part,
     left(trim(coalesce(in_note, '')), 280), 'collaborators')
  returning id into new_ask;

  select display_name into asker_name
  from public.profiles where id = auth.uid();

  -- The notification carries the song title in its body, which is what lets
  -- somebody decide without being able to open the song yet. Nothing else
  -- about it is readable to them until they say yes.
  perform private.notify_user(
    target_person,
    'song_ask',
    coalesce(asker_name, 'Somebody') || ' asked you to play ' ||
      coalesce(cleaned_part, 'on a song'),
    coalesce(song.title, 'A song') ||
      case
        when nullif(trim(coalesce(in_note, '')), '') is null then ''
        else ' — ' || left(trim(in_note), 200)
      end,
    song.room_id,
    target_project,
    null,
    auth.uid()
  );

  return new_ask;
end;
$$;

revoke all on function public.ask_musician(uuid, uuid, text, text)
  from public, anon;
grant execute on function public.ask_musician(uuid, uuid, text, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- Answering it
-- ---------------------------------------------------------------------

-- The only thing here that grants anything, and only the person the ask was
-- aimed at can call it.
create or replace function public.answer_ask(
  target_ask uuid,
  accept boolean
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  the_ask public.project_asks%rowtype;
  my_name text;
  song_title text;
begin
  select * into the_ask
  from public.project_asks
  where id = target_ask
  for update;

  if the_ask.id is null or the_ask.asked_of is distinct from auth.uid() then
    raise exception 'That ask is not yours to answer.' using errcode = '42501';
  end if;

  if the_ask.status <> 'open' then
    -- Already answered, or withdrawn while they were deciding. Neither is an
    -- error worth putting in front of somebody: return what is true now.
    return the_ask.project_id;
  end if;

  select display_name into my_name from public.profiles where id = auth.uid();
  select title into song_title from public.projects where id = the_ask.project_id;

  if accept then
    insert into public.project_members (project_id, user_id, display_name, role)
    values (the_ask.project_id, auth.uid(), coalesce(my_name, 'Member'), 'editor')
    on conflict (project_id, user_id) do nothing;
  end if;

  update public.project_asks
  set status = case when accept then 'closed' else 'declined' end,
      answered_at = now(),
      closed_at = case when accept then now() else closed_at end
  where id = target_ask;

  -- The asker hears back either way. An ask that can only ever be answered
  -- with silence is one nobody sends twice.
  if the_ask.asked_by is not null then
    perform private.notify_user(
      the_ask.asked_by,
      'song_ask',
      coalesce(my_name, 'Somebody') ||
        case when accept then ' is in' else ' passed on this one' end,
      coalesce(song_title, 'A song') ||
        case when accept then '' else ' — worth asking somebody else' end,
      null,
      the_ask.project_id,
      null,
      auth.uid()
    );
  end if;

  return the_ask.project_id;
end;
$$;

revoke all on function public.answer_ask(uuid, boolean) from public, anon;
grant execute on function public.answer_ask(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------
-- What you have been asked
-- ---------------------------------------------------------------------

-- The deciding side. Returns enough to answer — who, which song, which part,
-- what they said — without granting a read on the song itself.
create or replace function public.asks_for_me()
returns table (
  id uuid,
  project_id uuid,
  song_title text,
  asked_by uuid,
  asked_by_name text,
  part text,
  note text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    a.id,
    a.project_id,
    p.title,
    a.asked_by,
    pr.display_name,
    a.part,
    a.note,
    a.created_at
  from public.project_asks a
  join public.projects p on p.id = a.project_id
  left join public.profiles pr on pr.id = a.asked_by
  where a.asked_of = (select auth.uid())
    and a.status = 'open'
  order by a.created_at desc;
$$;

revoke all on function public.asks_for_me() from public, anon;
grant execute on function public.asks_for_me() to authenticated;

-- ---------------------------------------------------------------------
-- Songs you could offer
-- ---------------------------------------------------------------------

-- The picker behind "Ask them to play on…". Your songs, newest first, with
-- whether this person has already been asked about each — so the sheet can
-- grey out the one you asked yesterday rather than failing on the unique
-- index and making you find out by error message.
create or replace function public.songs_i_can_offer(target_person uuid)
returns table (
  id uuid,
  title text,
  updated_at timestamptz,
  already_asked boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select
    p.id,
    p.title,
    p.updated_at,
    exists (
      select 1 from public.project_asks a
      where a.project_id = p.id
        and a.asked_of = target_person
        and a.status = 'open'
    )
  from public.projects p
  where private.is_room_member(p.room_id) or private.is_project_member(p.id)
  order by p.updated_at desc
  limit 100;
$$;

revoke all on function public.songs_i_can_offer(uuid) from public, anon;
grant execute on function public.songs_i_can_offer(uuid) to authenticated;
