-- Heard it, from the Open Mic.
--
-- On the Open Mic a song had one answer: "Offer to play on this", which
-- costs an evening. A stranger who liked it and had nothing to add could do
-- nothing at all, and the person who put the song up saw a play count. 0049
-- gave the room the cheap answer -- a nod, "heard it", visible by name and
-- never a total -- and kept it to the room. This lets anyone who can hear a
-- song say they heard it, and say one line about it if they like.
--
-- The rules from 0049 stay: who nodded is visible, nothing aggregates across
-- a profile, and a nod is takeable back. A note is a sentence to the person
-- who put the song up, not a comment under it: it reaches their inbox and
-- nowhere else.

alter table public.project_nods
  add column if not exists note text
    check (note is null or char_length(note) <= 140);

comment on column public.project_nods.note is
  'One line to whoever put the song up, or null for a nod with nothing '
  'added. Reaches their inbox and nowhere else.';

-- Anybody who can hear the song can say they heard it: the room, as before,
-- and anyone at all while the song is on the Open Mic.
drop policy if exists project_nods_write_own on public.project_nods;
create policy project_nods_write_own on public.project_nods
for insert to authenticated with check (
  profile_id = (select auth.uid())
  and exists (
    select 1 from public.projects p
    where p.id = project_id
      and (private.is_room_member(p.room_id) or p.open_mic_at is not null)
  )
);

-- The note can be added to a nod that already exists (the app upserts), by
-- its owner and nobody else.
drop policy if exists project_nods_update_own on public.project_nods;
create policy project_nods_update_own on public.project_nods
for update to authenticated
using (profile_id = (select auth.uid()))
with check (profile_id = (select auth.uid()));

-- You can always see your own nod, wherever the song lives. Without this a
-- listener on the Open Mic could say they heard it and never see that they
-- had.
drop policy if exists project_nods_read_own on public.project_nods;
create policy project_nods_read_own on public.project_nods
for select to authenticated using (profile_id = (select auth.uid()));

-- ---------------------------------------------------------------------
-- Telling the person who put the song up.
-- ---------------------------------------------------------------------

-- A bandmate's nod is already on the song ("3 heard it" beside the ask
-- bar), so the inbox only hears about the ones with nowhere else to be
-- seen: a nod from outside the room, or one that says something. project
-- updates are the type, because that is what it is, and the preference
-- switch for them applies.
create or replace function private.announce_nod()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
declare
  song record;
  who_name text;
  in_room boolean;
  has_note boolean;
begin
  select p.title, p.room_id, p.created_by into song
  from public.projects p
  where p.id = new.project_id;

  if song.created_by is null or song.created_by = new.profile_id then
    return new;
  end if;

  has_note := new.note is not null and char_length(trim(new.note)) > 0;

  if tg_op = 'UPDATE' then
    -- Re-saving the same nod is not news.
    if new.note is not distinct from old.note then
      return new;
    end if;
  end if;

  select exists (
    select 1 from public.room_members m
    where m.room_id = song.room_id and m.user_id = new.profile_id
  ) into in_room;

  if in_room and not has_note then
    return new;
  end if;

  select pr.display_name into who_name
  from public.profiles pr
  where pr.id = new.profile_id;

  perform private.notify_user(
    song.created_by,
    'project_update',
    coalesce(who_name, 'Somebody') || ' heard ' || coalesce(song.title, 'your song'),
    case when has_note then left(trim(new.note), 200) else 'On the Open Mic.' end,
    song.room_id,
    new.project_id,
    null,
    new.profile_id
  );

  return new;
end;
$$;

drop trigger if exists project_nods_announce on public.project_nods;
create trigger project_nods_announce
after insert or update of note on public.project_nods
for each row execute function private.announce_nod();

-- ---------------------------------------------------------------------
-- What the owner sees, and what a listener sees.
-- ---------------------------------------------------------------------

-- Both return a table, and a returns-table shape cannot be changed with
-- create or replace: dropped and made again with the new columns last.

drop function if exists public.my_open_mic();
create function public.my_open_mic()
returns table (
  id uuid,
  title text,
  open_mic_at timestamptz,
  listeners bigint,
  listeners_this_week bigint,
  offers bigint,
  asking_for text[],
  storage_path text,
  heard bigint
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
    audio.storage_path,
    -- People who chose to say so, which is a different thing from a play.
    (select count(*) from public.project_nods n where n.project_id = p.id)
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

drop function if exists public.open_mic_song(uuid);
create function public.open_mic_song(target_project uuid)
returns table (
  id uuid,
  title text,
  owner_id uuid,
  owner_name text,
  owner_avatar text,
  open_mic_at timestamptz,
  musical_key text,
  bpm double precision,
  asking_for text[],
  ask_note text,
  storage_path text,
  duration_ms integer,
  heard bigint,
  heard_by_me boolean
)
language sql
stable
security definer
set search_path = public
as $fn$
  select
    p.id,
    p.title,
    p.created_by,
    pr.display_name,
    pr.avatar_path,
    p.open_mic_at,
    r.musical_key,
    r.bpm,
    coalesce(
      (select array_agg(distinct a.part)
         from public.project_asks a
        where a.project_id = p.id and a.status = 'open' and a.part is not null),
      '{}'::text[]
    ),
    (select a.note from public.project_asks a
      where a.project_id = p.id and a.status = 'open'
        and char_length(trim(a.note)) > 0
      order by a.created_at desc limit 1),
    audio.storage_path,
    audio.duration_ms,
    (select count(*) from public.project_nods n where n.project_id = p.id),
    exists (
      select 1 from public.project_nods n
      where n.project_id = p.id and n.profile_id = (select auth.uid())
    )
  from public.projects p
  left join public.profiles pr on pr.id = p.created_by
  left join public.project_audio_references r on r.project_id = p.id
  left join lateral private.song_audio(p.id) audio on true
  where p.id = target_project
    and p.open_mic_at is not null
    and p.deleted_at is null
    and not private.blocked_between((select auth.uid()), p.created_by)
  limit 1;
$fn$;

revoke all on function public.open_mic_song(uuid) from public, anon;
grant execute on function public.open_mic_song(uuid) to authenticated;
