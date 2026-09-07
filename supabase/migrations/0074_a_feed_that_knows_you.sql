-- A feed that knows you, and does not hold you to it.
--
-- The feed was newest-first for everybody: the same eight songs in the same
-- order for a bluegrass fiddler and a metal drummer. Scroll past four things
-- you do not care about and the honest conclusion is that this place is not
-- for you.
--
-- What somebody wants from this screen is not "recent music". It is *these
-- are my people*. So most of it is ordered by how close a song is to the
-- person looking.
--
-- **Closeness, never quality.** This is what keeps 0072 true. Ranking by how
-- good somebody is builds a ladder and puts the newest person permanently at
-- the bottom. Ordering by fit does the opposite: a beginner is *closer* to
-- another beginner working in the same corner than a session player is, so
-- fit puts them in front of the people most likely to want them. A pure
-- shuffle puts everybody in front of everybody, which in practice is in
-- front of nobody. Nothing here counts plays, takes or followers. Every tier
-- answers "does this concern you", none of them "is this any good".
--
-- ---------------------------------------------------------------------
-- And then it breaks its own pattern, on purpose
-- ---------------------------------------------------------------------
--
-- A feed that only shows you your own kind is a room with one conversation
-- in it. For a listening app that is merely dull; for a *creative* one it is
-- a defect — the collaborations worth having are mostly the ones nobody
-- would have gone looking for, and a system confident enough to only ever
-- show you more of what it already decided you are will never produce one.
--
-- So **every fourth card is somebody outside your fit entirely**, drawn from
-- the people this ordering has no reason to show you, and shuffled on the day
-- rather than by recency so it is a different stranger tomorrow.
--
-- Three quarters your world, one quarter outside it. The fit is a lean, not
-- a wall, and it is stated on each card rather than applied silently — a
-- feed that quietly decides for you is one you can neither trust nor argue
-- with.

-- ---------------------------------------------------------------------
-- Why the cursor is gone
-- ---------------------------------------------------------------------

-- `in_after` walked backwards through `open_mic_at`, which only works while
-- the order *is* time. Once the order is fit and deliberate interleaving, a
-- timestamp cursor points at nothing, and one that silently returns the
-- wrong page is worse than none.
--
-- It is also the wrong shape for this screen, which says so itself: a
-- listening session with an end rather than an infinite scroll. "The
-- twenty-four closest to you today, with strangers folded in" stays the
-- right answer when there are ten thousand — more right than page forty of a
-- list by date.

drop function if exists public.open_mic_feed(timestamptz, integer, text);

create function public.open_mic_feed(
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
  -- Why this one reached you, in the app's own words. "They need a bass
  -- player" is the most useful sentence this screen can say to a bass
  -- player, and naming the wildcards is what stops them reading as noise.
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
      case when p.location_visibility = 'public' then lower(trim(p.city)) end
        as city
    from public.profiles p
    where p.id = (select auth.uid())
  ),
  -- Everybody this person has actually shared a song with. Not a follow
  -- graph — this app has none — but the only connection it holds that was
  -- earned by making music together.
  played_with as (
    select distinct other.recorded_by as id
    from public.song_layers mine
    join public.song_layers other on other.project_id = mine.project_id
    where mine.recorded_by = (select auth.uid())
      and mine.shared_at is not null
      and other.shared_at is not null
      and other.recorded_by <> (select auth.uid())
  ),
  -- Whether we know anything about this person at all. For somebody who has
  -- just arrived and told us nothing, every song is equally new and calling
  -- any of them a wildcard would be a lie.
  knows_me as (
    select
      coalesce(array_length((select plays from me), 1), 0) > 0
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
      case
        when fit.needs_you is not null then 0
        when fit.known then 1
        when fit.same_city then 2
        else 3
      end as tier
    from public.projects p
    left join public.project_audio_references r on r.project_id = p.id
    left join public.profiles pr on pr.id = p.created_by
    left join lateral private.song_audio(p.id) audio on true
    cross join lateral (
      select
        -- The part it is asking for that this person plays. The whole product
        -- in one line: you heard something good, and it needs exactly you.
        (select a.part
           from public.project_asks a
          where a.project_id = p.id
            and a.status = 'open'
            and a.part is not null
            -- coalesce, not a bare scalar subquery. `= any((select ...))`
            -- is read as the *subquery* form of ANY, which compares a text
            -- to a whole text[] row and will not type-check; wrapping it
            -- makes it an array expression and the array form applies. The
            -- empty default also covers somebody who has not said what they
            -- play, for whom nothing should match rather than everything.
            and a.part = any(
              coalesce((select m.plays from me m), '{}'::text[])
            )
          limit 1) as needs_you,
        exists (select 1 from played_with w where w.id = p.created_by)
          as known,
        (select city from me) is not null
          and (select city from me) = (
            select lower(trim(pr2.city)) from public.profiles pr2
            where pr2.id = p.created_by
              and pr2.location_visibility = 'public'
          ) as same_city
    ) fit
    where p.open_mic_at is not null
      and p.deleted_at is null
      -- Nothing silent. A card in a listening feed with nothing to play is
      -- worse than a shorter feed.
      and audio.storage_path is not null
      and not private.blocked_between((select auth.uid()), p.created_by)
      -- Your own songs are not somebody to meet. You know how they sound.
      and p.created_by is distinct from (select auth.uid())
      and (
        in_part is null
        or exists (
          select 1 from public.project_asks a
          where a.project_id = p.id and a.status = 'open' and a.part = in_part
        )
      )
  ),
  -- Two queues. Inside the fit, newest first — recency is the one ordering
  -- that judges nobody: it says something happened, not that somebody is
  -- better. Inside the strangers, the daily shuffle from 0072, so the ones
  -- you meet change without anybody earning a place.
  ranked as (
    select
      c.*,
      -- Partitioned on "is this a stranger", so each queue is numbered from
      -- one within itself. Ranking across both would leave the strangers
      -- holding whatever numbers the fit rows did not use, and scatter them
      -- to slots far past the end of the page.
      row_number() over (
        partition by (c.tier = 3)
        order by c.tier, c.open_mic_at desc
      ) as fit_rank,
      row_number() over (
        partition by (c.tier = 3)
        order by md5(c.id::text || current_date::text)
      ) as wild_rank
    from candidates c
  )
  -- Every column qualified with `rk`, deliberately.
  --
  -- `returns table (...)` puts every one of those names — id, title,
  -- open_mic_at, storage_path — in scope inside the body as output
  -- parameters. An unqualified `id` here matches both the output name and
  -- the column, and Postgres refuses it as ambiguous rather than guessing.
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
      when rk.tier = 2 then 'Nearby'
      when (select yes from knows_me)
        then 'Nothing like what you play'
      else ''
    end
  from ranked rk
  -- Slots 1,2,3, 5,6,7, 9,10,11 … for the fit; 4, 8, 12 … for the strangers.
  -- Neither collides with the other, and a gap where a queue runs dry is
  -- harmless: the order simply closes up.
  order by
    case
      when rk.tier < 3
        then rk.fit_rank + ((rk.fit_rank - 1) / 3)
      else rk.wild_rank * 4
    end,
    rk.open_mic_at desc
  limit greatest(least(in_limit, 24), 1);
$fn$;

revoke all on function public.open_mic_feed(integer, text) from public, anon;
grant execute on function public.open_mic_feed(integer, text) to authenticated;
