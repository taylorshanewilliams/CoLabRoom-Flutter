-- Who has been listening.
--
-- A song goes on the Open Mic and then nothing comes back. No count, no
-- signal, no reason to look again — so putting something up feels like
-- dropping it down a well, and the second time is harder than the first.
--
-- **Counted, never logged.** The obvious table is one row per play with who
-- and when, and it is the wrong table: it hands a song's owner a list of
-- exactly who listened to their music and how often, which nobody agreed to
-- and nobody would want pointed at them. This app has been careful about
-- location, about who can read a profile, about what a take being private
-- means — and a play history is more revealing than any of those.
--
-- So the row is (song, listener, day) with that as the key. Somebody who
-- plays a song eleven times on Tuesday counts once. The owner is told a
-- number and never an identity, the shape of the table makes it impossible
-- to tell them more, and "how many people heard it this week" is answerable
-- without keeping a diary of anybody's listening.
--
-- **And a play is not a tap.** Somebody who skips after two seconds did not
-- listen, and counting them would make the number reassuring and useless.
-- The client only records after ten seconds of actual playback.

create table if not exists public.song_plays (
  project_id uuid not null references public.projects(id) on delete cascade,
  listener_id uuid not null references public.profiles(id) on delete cascade,
  -- Date, not timestamp. The precision that is useful is "a person, a song,
  -- a day"; anything finer is a record of when somebody was awake.
  day date not null default current_date,
  primary key (project_id, listener_id, day)
);

create index if not exists song_plays_project_idx
  on public.song_plays (project_id, day desc);

alter table public.song_plays enable row level security;

-- Nobody reads this table from a phone, including the owner of the song.
-- Counts come back through a function that returns numbers; there is no
-- query a client can run that names who listened.
--
-- Insert only, and only about yourself.
drop policy if exists song_plays_insert_own on public.song_plays;
create policy song_plays_insert_own on public.song_plays
for insert to authenticated with check (listener_id = (select auth.uid()));

-- Somebody listened.
--
-- Silent about repeats: the second play of the day is not an error and the
-- caller should not have to care. Only counts a song that is actually on the
-- Open Mic, so nothing accumulates against private work.
create or replace function public.record_play(target_project uuid)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if not exists (
    select 1 from public.projects p
    where p.id = target_project
      and p.open_mic_at is not null
      and p.deleted_at is null
  ) then
    return;
  end if;

  -- Your own song is not an audience. Somebody checking their own mix
  -- twenty times would otherwise be the only number they ever saw.
  if exists (
    select 1 from public.projects p
    where p.id = target_project and p.created_by = auth.uid()
  ) then
    return;
  end if;

  insert into public.song_plays (project_id, listener_id)
  values (target_project, auth.uid())
  on conflict (project_id, listener_id, day) do nothing;
end;
$fn$;

revoke all on function public.record_play(uuid) from public, anon;
grant execute on function public.record_play(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- What is happening to the things you put up
-- ---------------------------------------------------------------------

-- Your songs on the Open Mic, and what has come back.
--
-- Only ever your own: `where r.account_id = auth.uid()`. Nobody can ask this
-- about somebody else's song, so a listen count is a thing an owner sees
-- about their own work and not a public score anybody can compare.
--
-- That is deliberate and worth writing down: the moment a count is visible
-- on somebody else's song it becomes a ranking, and 0072 and 0074 spent two
-- migrations making sure this app does not rank people.
create or replace function public.my_open_mic()
returns table (
  id uuid,
  title text,
  open_mic_at timestamptz,
  listeners bigint,
  listeners_this_week bigint,
  offers bigint,
  asking_for text[],
  storage_path text
)
language sql
stable
security definer
set search_path = public
as $fn$
  select
    p.id,
    p.title,
    p.open_mic_at,
    (select count(*) from public.song_plays s where s.project_id = p.id),
    (select count(*) from public.song_plays s
      where s.project_id = p.id and s.day > current_date - 7),
    -- Somebody offering to play on it is the thing that actually matters;
    -- a listen is interest and an offer is a person putting their hand up.
    (select count(*) from public.project_asks a
      where a.project_id = p.id
        and a.asked_of is null
        and a.status = 'open'),
    coalesce(
      (select array_agg(distinct a.part)
         from public.project_asks a
        where a.project_id = p.id and a.status = 'open'
          and a.part is not null),
      '{}'::text[]
    ),
    audio.storage_path
  from public.projects p
  join public.rooms r on r.id = p.room_id
  left join lateral private.song_audio(p.id) audio on true
  where r.account_id = (select auth.uid())
    and p.open_mic_at is not null
    and p.deleted_at is null
  order by p.open_mic_at desc;
$fn$;

revoke all on function public.my_open_mic() from public, anon;
grant execute on function public.my_open_mic() to authenticated;
