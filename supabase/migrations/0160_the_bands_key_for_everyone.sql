-- The band's key, for everybody.
--
-- 0144 gave a song a key of its own: `projects.key_override`, where the band
-- says what the analyser got wrong. Inside the room everything reads it --
-- the sheet, the numbers, the capo chart, Tonight. Outside the room nothing
-- did. The song's page on the Open Mic, the feed card, the showcase,
-- colabroom.com's list and the brief an ask carries all still returned
-- `project_audio_references.musical_key`, so a Mixolydian song the band had
-- moved to A was still offered to a stranger as "in D". The stranger is the
-- one reader who cannot ask the band, and the one deciding from that line
-- whether to pick up an instrument (Every Musician, Same Song, 17 September
-- 2026; decided after wave 1: the band's key reaches strangers' pages).
--
-- **One expression, five times.** `coalesce(p.key_override, r.musical_key)`
-- wherever a key is returned, spelled the way 0144 spelled it in tonight().
-- The override is a key or null and never a blank: set_song_key trims a
-- blank to null and the column's check refuses anything else. So coalesce
-- is the whole of what `SongProject.songKey` does in the app, and clearing
-- the override hands every one of these pages back to the analyser without
-- anybody touching them.
--
-- **Nothing else moves.** Each function is restated from its latest
-- definition: open_mic_song from 0113, asks_for_me and open_mic_feed from
-- 0156, public_songs and showcase from 0155. The returned shapes are the
-- same column for column, so `create or replace` is enough, and no grant is
-- missing even for a moment; they are restated anyway so each function
-- reads whole here. The key travels in a column the app already maps, so an
-- app that has not updated shows the band's key the moment this is applied.
--
-- **Not here, on purpose.** my_open_mic, open_mic_songs and songs_by return
-- no key, so there is nothing in them to correct. The tempo beside the key
-- is still the analyser's, because a song has no tempo of its own to
-- prefer. And no reading reaches any of these -- somebody's transpose, capo
-- or horn part is theirs and lives on their device. This is the shared
-- fact, and only that.

-- ---------------------------------------------------------------------
-- The song's page on the Open Mic
-- ---------------------------------------------------------------------

-- Restated from 0113, which is still its latest definition. The key is the
-- only change.
create or replace function public.open_mic_song(target_project uuid)
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
    -- What the band says it is in, when they have said (0144); what the
    -- analyser heard otherwise.
    coalesce(p.key_override, r.musical_key),
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

-- ---------------------------------------------------------------------
-- The brief an ask carries
-- ---------------------------------------------------------------------

-- Restated from 0156, which is still its latest definition. The key is the
-- only change. "2:14 · in A · 96 bpm" is the line somebody reads to decide
-- whether to answer, before they are in the room and before they can see
-- the sheet, so it is the place a wrong key costs the most: they work the
-- part out in D, and the band plays it in A.
create or replace function public.asks_for_me()
returns table (
  id uuid,
  project_id uuid,
  song_title text,
  asked_by uuid,
  asked_by_name text,
  part text,
  note text,
  created_at timestamptz,

  -- What answering it means. 'play' on every ask this app has ever made
  -- before now, and the app shows nothing for it.
  terms text,

  -- Everything below is the brief, and every field of it already existed
  -- somewhere else in the database.
  storage_path text,
  duration_ms integer,
  musical_key text,
  bpm double precision,

  -- What is already on it, as words. "Guitar and a vocal on it" tells
  -- somebody whether there is a hole shaped like them; a number of takes
  -- tells them nothing and would be a count of somebody's work, which this
  -- app does not put on screens.
  parts_on_it text[],

  -- Whether the chords and words are already worked out. For the person
  -- answering this is the difference between ten minutes and an evening.
  has_song_sheet boolean,

  -- What they would be joining, in the asker's words (0156). Last, so the
  -- columns before it keep the places they had.
  sung_in text
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
    a.created_at,
    a.terms,
    audio.storage_path,
    audio.duration_ms,
    -- What the band says it is in, when they have said (0144); what the
    -- analyser heard otherwise.
    coalesce(p.key_override, r.musical_key),
    r.bpm,
    coalesce(
      (select array_agg(distinct l.part::text)
         from public.song_layers l
        where l.project_id = p.id
          and l.shared_at is not null
          and l.part is not null),
      '{}'::text[]
    ),
    coalesce(r.analysis_state = 'ready', false),
    a.sung_in
  from public.project_asks a
  join public.projects p on p.id = a.project_id
  left join public.profiles pr on pr.id = a.asked_by
  left join public.project_audio_references r on r.project_id = p.id
  left join lateral private.song_audio(p.id) audio on true
  where a.asked_of = (select auth.uid())
    and a.status = 'open'
  order by a.created_at desc;
$$;

revoke all on function public.asks_for_me() from public, anon;
grant execute on function public.asks_for_me() to authenticated;

-- ---------------------------------------------------------------------
-- The feed card
-- ---------------------------------------------------------------------

-- Restated from 0156, which is still its latest definition. The key is the
-- only change, made once where the candidates are gathered, so the column
-- keeps its name and everything below it reads what it read before. The
-- tiers, the strangers, every fourth card and the reason line are
-- untouched: a key is never a reason and never an order.
create or replace function public.open_mic_feed(
  in_limit integer default 12,
  in_part text default null
)
returns table (
  id uuid,
  title text,
  owner_id uuid,
  owner_name text,
  owner_avatar text,
  open_mic_at timestamptz,
  asking_for text[],
  ask_note text,
  musical_key text,
  bpm double precision,
  duration_ms integer,
  storage_path text,
  reason text,
  ask_sung_in text
)
language sql
stable
security definer
set search_path = public
as $fn$
  with me as (
    select
      p.id,
      p.plays,
      p.sounds_like,
      p.sings_in,
      case when p.location_visibility = 'public' then lower(trim(p.city)) end
        as city
    from public.profiles p
    where p.id = (select auth.uid())
  ),
  played_with as (
    select distinct other.recorded_by as id
    from public.song_layers mine
    join public.song_layers other on other.project_id = mine.project_id
    where mine.recorded_by = (select auth.uid())
      and mine.shared_at is not null
      and other.shared_at is not null
      and other.recorded_by <> (select auth.uid())
  ),
  knows_me as (
    select
      coalesce(array_length((select plays from me), 1), 0) > 0
      or coalesce(array_length((select sounds_like from me), 1), 0) > 0
      or exists (select 1 from played_with)
      or (select city from me) is not null as yes
  ),
  candidates as (
    select
      p.id,
      p.title,
      p.created_by,
      pr.display_name as owner_name,
      pr.avatar_path as owner_avatar,
      p.open_mic_at,
      coalesce(
        (select array_agg(distinct a.part)
           from public.project_asks a
          where a.project_id = p.id and a.status = 'open'
            and a.part is not null),
        '{}'::text[]
      ) as asking_for,
      coalesce(
        (select a.note from public.project_asks a
          where a.project_id = p.id and a.status = 'open'
            and char_length(trim(a.note)) > 0
          order by a.created_at desc limit 1),
        ''
      ) as ask_note,
      -- From an ask made to everybody, never one sent to a person by name:
      -- that line was written for them, and this card is read by strangers.
      coalesce(
        (select a.sung_in from public.project_asks a
          where a.project_id = p.id and a.status = 'open'
            and a.asked_of is null
            and char_length(trim(a.sung_in)) > 0
          order by a.created_at desc limit 1),
        ''
      ) as ask_sung_in,
      -- What the band says it is in, when they have said (0144); what the
      -- analyser heard otherwise.
      coalesce(p.key_override, r.musical_key) as musical_key,
      r.bpm,
      audio.duration_ms,
      audio.storage_path,
      fit.needs_you,
      fit.shared_sound,
      fit.shared_sung_in,
      case
        when fit.needs_you is not null then 0
        when fit.known then 1
        when fit.shared_sound is not null then 2
        when fit.same_city then 3
        else 4
      end as tier
    from public.projects p
    left join public.project_audio_references r on r.project_id = p.id
    left join public.profiles pr on pr.id = p.created_by
    left join lateral private.song_audio(p.id) audio on true
    cross join lateral (
      select
        (select a.part
           from public.project_asks a
          where a.project_id = p.id
            and a.status = 'open'
            and a.part is not null
            and a.part = any(
              coalesce((select m.plays from me m), '{}'::text[])
            )
          limit 1) as needs_you,
        exists (select 1 from played_with w where w.id = p.created_by)
          as known,
        -- The first thing you and the person who wrote it both make.
        (select t
           from unnest(coalesce(pr.sounds_like, '{}'::text[])) as t
          where t = any(
            coalesce((select m.sounds_like from me m), '{}'::text[])
          )
          limit 1) as shared_sound,
        -- The first word you and they both sing in, in the order they
        -- wrote theirs. Both sides declared it; nothing here is guessed.
        (select t
           from unnest(coalesce(pr.sings_in, '{}'::text[]))
             with ordinality as u(t, ord)
          where t = any(
            coalesce((select m.sings_in from me m), '{}'::text[])
          )
          order by ord
          limit 1) as shared_sung_in,
        (select city from me) is not null
          and (select city from me) = (
            select lower(trim(pr2.city)) from public.profiles pr2
            where pr2.id = p.created_by
              and pr2.location_visibility = 'public'
          ) as same_city
    ) fit
    where p.open_mic_at is not null
      and p.deleted_at is null
      and audio.storage_path is not null
      and not private.blocked_between((select auth.uid()), p.created_by)
      and p.created_by is distinct from (select auth.uid())
      and (
        in_part is null
        or exists (
          select 1 from public.project_asks a
          where a.project_id = p.id and a.status = 'open' and a.part = in_part
        )
      )
  ),
  -- Named rather than compared against a literal, so adding a tier above
  -- cannot quietly turn the strangers into ordinary rows.
  sorted as (
    select c.*, (c.tier = 4) as is_stranger from candidates c
  ),
  ranked as (
    select
      s.*,
      row_number() over (
        partition by s.is_stranger
        order by s.tier, s.open_mic_at desc
      ) as fit_rank,
      row_number() over (
        partition by s.is_stranger
        order by md5(s.id::text || current_date::text)
      ) as wild_rank
    from sorted s
  )
  select
    rk.id,
    rk.title,
    rk.created_by,
    rk.owner_name,
    rk.owner_avatar,
    rk.open_mic_at,
    rk.asking_for,
    rk.ask_note,
    rk.musical_key,
    rk.bpm,
    rk.duration_ms,
    rk.storage_path,
    case
      when rk.needs_you is not null then 'Needs a ' || rk.needs_you
      when rk.tier = 1 then 'You have played together'
      when rk.shared_sound is not null then 'Both into ' || rk.shared_sound
      when rk.tier = 3 then 'Nearby'
      -- After everything that placed the card, and before the line that
      -- admits a card is a stranger's: a word you both wrote is a truer
      -- thing to say about it than "Nothing like what you play".
      when rk.shared_sung_in is not null then
        'Also sings in ' || upper(left(rk.shared_sung_in, 1)) ||
          substr(rk.shared_sung_in, 2)
      when (select yes from knows_me) then 'Nothing like what you play'
      else ''
    end,
    rk.ask_sung_in
  from ranked rk
  order by
    case
      when not rk.is_stranger
        then rk.fit_rank + ((rk.fit_rank - 1) / 3)
      else rk.wild_rank * 4
    end,
    rk.open_mic_at desc
  limit greatest(least(in_limit, 24), 1);
$fn$;

revoke all on function public.open_mic_feed(integer, text) from public, anon;
grant execute on function public.open_mic_feed(integer, text) to authenticated;

-- ---------------------------------------------------------------------
-- colabroom.com's list, and the showcase in the app
-- ---------------------------------------------------------------------

-- Restated from 0155, which is still its latest definition. The key is the
-- only change. This one is granted to anon: the band's key is a fact about
-- the song the band chose to show, the same kind of fact as the detected
-- key it stands in front of, and it says nothing about anybody.
create or replace function public.public_songs(
  in_limit integer default 500,
  in_offset integer default 0
)
returns table (
  id uuid,
  title text,
  owner_id uuid,
  owner_name text,
  showcased_at timestamptz,
  duration_ms integer,
  musical_key text,
  players jsonb,
  made_here boolean
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
    coalesce(pr.display_name, 'Somebody'),
    p.showcased_at,
    audio.duration_ms,
    -- What the band says it is in, when they have said (0144); what the
    -- analyser heard otherwise.
    coalesce(p.key_override, r.musical_key),
    coalesce(
      (select jsonb_agg(distinct jsonb_build_object(
                'name', coalesce(who.display_name, 'Somebody')))
         from public.song_layers l
         join public.profiles who on who.id = l.recorded_by
        where l.project_id = p.id
          and private.take_is_public(l.id)
          and not who.is_demo
          and l.recorded_by is distinct from p.created_by),
      '[]'::jsonb
    ),
    (select count(distinct l.recorded_by) > 1
       from public.song_layers l
      where l.project_id = p.id and private.take_is_public(l.id))
  from public.projects p
  left join public.profiles pr on pr.id = p.created_by
  left join public.project_audio_references r on r.project_id = p.id
  left join lateral private.song_audio(p.id) audio on true
  where p.showcased_at is not null
    and p.deleted_at is null
    -- Nothing silent. A page for a song with nothing to play is a page about
    -- a title.
    and audio.storage_path is not null
    and coalesce(pr.is_demo, false) = false
  order by p.showcased_at desc
  limit greatest(least(in_limit, 2000), 1)
  offset greatest(in_offset, 0);
$fn$;

revoke all on function public.public_songs(integer, integer) from public;
grant execute on function public.public_songs(integer, integer)
  to anon, authenticated;

-- Restated from 0155, which is still its latest definition. The key is the
-- only change: the same list as colabroom.com, read by the app, saying the
-- same key.
create or replace function public.showcase(
  in_limit integer default 24,
  in_before timestamptz default null
)
returns table (
  id uuid,
  title text,
  owner_id uuid,
  owner_name text,
  owner_avatar text,
  finished_at timestamptz,
  showcased_at timestamptz,
  storage_path text,
  duration_ms integer,
  musical_key text,
  players jsonb,
  made_here boolean,
  met_here boolean
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
    p.finished_at,
    p.showcased_at,
    audio.storage_path,
    audio.duration_ms,
    -- What the band says it is in, when they have said (0144); what the
    -- analyser heard otherwise.
    coalesce(p.key_override, r.musical_key),
    coalesce(
      (select jsonb_agg(distinct jsonb_build_object(
                'id', who.id, 'name', coalesce(who.display_name, 'Somebody')))
         from public.song_layers l
         join public.profiles who on who.id = l.recorded_by
        where l.project_id = p.id
          and private.take_is_public(l.id)
          and l.recorded_by is distinct from p.created_by),
      '[]'::jsonb
    ),
    (select count(distinct l.recorded_by) > 1
       from public.song_layers l
      where l.project_id = p.id and private.take_is_public(l.id)),
    exists (
      select 1 from public.project_members m
      where m.project_id = p.id
        and m.user_id is distinct from p.created_by
    )
  from public.projects p
  left join public.profiles pr on pr.id = p.created_by
  left join public.project_audio_references r on r.project_id = p.id
  left join lateral private.song_audio(p.id) audio on true
  where p.showcased_at is not null
    and p.deleted_at is null
    and audio.storage_path is not null
    and not private.blocked_between((select auth.uid()), p.created_by)
    and (in_before is null or p.showcased_at < in_before)
  order by p.showcased_at desc
  limit greatest(least(in_limit, 48), 1);
$fn$;

revoke all on function public.showcase(integer, timestamptz)
  from public, anon;
grant execute on function public.showcase(integer, timestamptz)
  to authenticated;
