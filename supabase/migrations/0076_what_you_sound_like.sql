-- What you sound like.
--
-- `find_musicians` carries this comment, written when it shipped:
--
--   "guitarist" does not distinguish a metal player from a jazz one, and
--   that judgement is made by listening.
--
-- True, and the reason the feed cannot yet do what it is supposed to. A
-- profile holds `plays`, `city` and `discoverable` and nothing about the
-- music somebody actually makes, so a bluegrass fiddler and a metal fiddler
-- are the same person to this system. "Ordered for you" on that basis means
-- ordered by instrument and postcode, which is not what anybody means when
-- they say they want to find like-minded musicians.
--
-- **Self-declared, and therefore never a ladder.** This is the property that
-- matters. Everything 0072 and 0074 refuse to do — rank people, count their
-- output, put a beginner permanently below a professional — stays refused,
-- because nobody *earns* a genre. You write down what you make and it moves
-- you sideways towards people making the same thing, never up or down past
-- anybody.
--
-- Free text in an array rather than an enum, for the reason `plays` gives:
-- a fixed list needs a migration every time somebody names something new,
-- and will be wrong for most of the world before it is wrong for anybody
-- else. The client offers suggestions; the column accepts what people type.

alter table public.profiles
  add column if not exists sounds_like text[] not null default '{}';

comment on column public.profiles.sounds_like is
  'What this person says their music sounds like, in their own words. Used '
  'to order feeds towards people making similar music. Never ranked, never '
  'counted as a score — overlap moves somebody sideways, never up.';

-- Kept small on purpose. Five is enough to place somebody and few enough
-- that each one means something; a profile listing twenty genres has said
-- nothing, and matches everybody.
create or replace function private.tidy_sounds_like(raw text[])
returns text[]
language sql
immutable
as $fn$
  -- Deduplicated case-insensitively, kept in the order somebody chose them,
  -- capped at five. `with ordinality` is what makes that order survive the
  -- grouping — a bare `limit 5` over a `distinct` takes an arbitrary five,
  -- which would silently drop whichever tags the planner felt like.
  select coalesce(
    (select array_agg(tag order by ord)
     from (
       select tag, min(ord) as ord
       from (
         select lower(trim(t)) as tag, ord
         from unnest(coalesce(raw, '{}'::text[])) with ordinality as u(t, ord)
         where char_length(trim(t)) between 1 and 40
       ) cleaned
       group by tag
       order by min(ord)
       limit 5
     ) kept),
    '{}'::text[]
  );
$fn$;

-- ---------------------------------------------------------------------
-- Saying it
-- ---------------------------------------------------------------------

create or replace function public.set_open_mic_presence(
  in_discoverable boolean,
  in_city text default null,
  in_location_visibility text default null,
  in_plays text[] default null,
  in_sounds_like text[] default null
)
returns void
language plpgsql
security invoker
set search_path = public
as $fn$
begin
  if in_location_visibility is not null
     and in_location_visibility not in ('nobody', 'collaborators', 'public') then
    raise exception 'Location can be shown to nobody, collaborators or everyone.'
      using errcode = '22023';
  end if;

  update public.profiles
  set discoverable = in_discoverable,
      -- Null means "leave it alone"; an empty string means "take it off my
      -- profile". A setting you can turn on and not off is not a setting.
      city = case
        when in_city is null then city
        else nullif(trim(in_city), '')
      end,
      location_visibility =
        coalesce(in_location_visibility, location_visibility),
      plays = coalesce(in_plays, plays),
      sounds_like = case
        when in_sounds_like is null then sounds_like
        else private.tidy_sounds_like(in_sounds_like)
      end
  where id = auth.uid();
end;
$fn$;

revoke all on function public.set_open_mic_presence(boolean, text, text, text[], text[])
  from public, anon;
grant execute on function public.set_open_mic_presence(boolean, text, text, text[], text[])
  to authenticated;

-- The old four-argument form would otherwise sit alongside the new one and
-- take every call that does not name the fifth parameter.
drop function if exists public.set_open_mic_presence(boolean, text, text, text[]);

-- ---------------------------------------------------------------------
-- Showing it
-- ---------------------------------------------------------------------

drop function if exists public.musician_profile(uuid);

create function public.musician_profile(target uuid)
returns table (
  id uuid,
  display_name text,
  avatar_path text,
  city text,
  plays text[],
  sounds_like text[],
  parts_recorded jsonb,
  songs_played_on bigint,
  people_worked_with bigint,
  discoverable boolean,
  location_visibility text
)
language sql
stable
security definer
set search_path = public
as $fn$
  select
    p.id,
    p.display_name,
    p.avatar_path,
    case
      when p.id = (select auth.uid()) then p.city
      when p.location_visibility = 'public' then p.city
      else null
    end,
    p.plays,
    -- Public to anybody who can see the profile at all. It is a description
    -- of the music, not of the person, and it is the one field here whose
    -- whole purpose is to be matched against.
    p.sounds_like,
    public.parts_recorded_by(p.id),
    (select count(distinct l.project_id) from public.song_layers l
      where l.recorded_by = p.id and l.shared_at is not null),
    (select count(distinct other.recorded_by)
       from public.song_layers mine
       join public.song_layers other on other.project_id = mine.project_id
      where mine.recorded_by = p.id
        and mine.shared_at is not null
        and other.shared_at is not null
        and other.recorded_by <> p.id),
    case when p.id = (select auth.uid()) then p.discoverable else null end,
    case when p.id = (select auth.uid()) then p.location_visibility else null end
  from public.profiles p
  where p.id = target
    and (
      p.id = (select auth.uid())
      or p.discoverable
      or exists (
        select 1 from public.room_members mine
        join public.room_members theirs on theirs.room_id = mine.room_id
        where mine.user_id = (select auth.uid()) and theirs.user_id = p.id
      )
    )
    and not private.blocked_between((select auth.uid()), p.id);
$fn$;

revoke all on function public.musician_profile(uuid) from public, anon;
grant execute on function public.musician_profile(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Finding by it
-- ---------------------------------------------------------------------

drop function if exists public.find_musicians(text, text, integer);

create function public.find_musicians(
  in_part text default null,
  in_city text default null,
  in_limit integer default 30,
  in_sounds_like text default null
)
returns table (
  id uuid,
  display_name text,
  avatar_path text,
  city text,
  plays text[],
  sounds_like text[],
  parts_recorded jsonb,
  songs_played_on bigint,
  people_worked_with bigint,
  -- What you have in common, so the list can say why somebody is on it.
  shared_sounds text[]
)
language sql
stable
security definer
set search_path = public
as $fn$
  with me as (
    select p.sounds_like from public.profiles p where p.id = (select auth.uid())
  )
  select
    p.id,
    p.display_name,
    p.avatar_path,
    case when p.location_visibility = 'public' then p.city else null end,
    p.plays,
    p.sounds_like,
    public.parts_recorded_by(p.id),
    (select count(distinct l.project_id) from public.song_layers l
      where l.recorded_by = p.id and l.shared_at is not null),
    (select count(distinct other.recorded_by)
       from public.song_layers mine
       join public.song_layers other on other.project_id = mine.project_id
      where mine.recorded_by = p.id
        and mine.shared_at is not null
        and other.shared_at is not null
        and other.recorded_by <> p.id),
    coalesce(shared.tags, '{}'::text[])
  from public.profiles p
  cross join lateral (
    select array_agg(t) as tags
    from unnest(p.sounds_like) as t
    where t = any(coalesce((select m.sounds_like from me m), '{}'::text[]))
  ) shared
  where p.discoverable
    and not private.blocked_between((select auth.uid()), p.id)
    and (
      in_part is null
      or in_part = any(p.plays)
      or exists (
        select 1 from public.song_layers l
        where l.recorded_by = p.id
          and l.shared_at is not null
          and l.part::text = in_part
      )
    )
    and (
      in_city is null
      or (p.location_visibility = 'public'
          and lower(trim(p.city)) = lower(trim(in_city)))
    )
    and (
      in_sounds_like is null
      or lower(trim(in_sounds_like)) = any(p.sounds_like)
    )
  order by
    -- Anybody making the same kind of music first. A boolean, not a count of
    -- how many tags matched: a count is a score, and the moment a list is
    -- ordered by a score somebody is at the bottom of it. This says "these
    -- are your corner of the room" and nothing about who is better.
    case when coalesce(array_length(shared.tags, 1), 0) > 0 then 0 else 1 end,
    -- Then the daily shuffle from 0072, unchanged: stable while you look,
    -- different tomorrow, and nobody's position earned.
    md5(p.id::text || current_date::text)
  limit greatest(least(in_limit, 100), 1);
$fn$;

revoke all on function public.find_musicians(text, text, integer, text)
  from public, anon;
grant execute on function public.find_musicians(text, text, integer, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- And hearing it
-- ---------------------------------------------------------------------

-- Taste joins the feed's tiers above city: for a *listening* surface, making
-- the same kind of music matters more than being in the same town. The
-- wildcard rule is unchanged — every fourth card is still somebody outside
-- all of this — but it now keys on a named flag rather than on the literal
-- number 3, which was one new tier away from silently breaking.
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
  reason text
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
      r.musical_key,
      r.bpm,
      audio.duration_ms,
      audio.storage_path,
      fit.needs_you,
      fit.shared_sound,
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
      when (select yes from knows_me) then 'Nothing like what you play'
      else ''
    end
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
