-- Pages that can be found.
--
-- The app renders to a canvas. A crawler visiting app.colabroom.com sees a
-- blank document with a script tag, so nothing in this product is indexable
-- and no amount of work on the app will change that. Everything that can ever
-- be found has to be real HTML on colabroom.com — and the only content worth
-- having there is the content the users make.
--
-- These two functions are what a static generator reads to build those pages.
-- They exist rather than the generator querying tables directly for one
-- reason: **the decision about what is publishable belongs in the database,
-- where it is reviewed, and not in a script that anybody can edit.**
--
-- ---------------------------------------------------------------------
-- What "public" means here, and what it deliberately does not
-- ---------------------------------------------------------------------
--
-- Getting this wrong is unrecoverable in a way almost nothing else in this
-- app is. A private song indexed by Google is cached, mirrored and quoted
-- within hours, and taking the page down afterwards does not take it back.
-- So every gate below is a positive act by the person whose work it is, and
-- nothing is published on the strength of an absence.
--
--   showcased_at    The consent, and the only one that counts for a song.
--                   *Finishing* is private — 0088 is explicit that reading
--                   finished_at here "would publish every band's private work
--                   the moment somebody pressed Done". Being on the Open Mic
--                   is not consent either: an ask is a request for help, not
--                   a publication, and an unfinished song with somebody's
--                   scratch vocal on it must never become a permanent web
--                   page.
--
--   discoverable    The consent for a person. Default false, and 0058 says
--                   why: everybody in this app joined a private room to write
--                   with people they know, and none of them agreed to be
--                   listed anywhere.
--
--   location_vis.   A city is only ever emitted at 'public'. The default is
--                   'nobody' and 'collaborators' means *after* the music, not
--                   before it — neither is a licence to put somebody's town
--                   on the open web.
--
--   is_demo         Seeded accounts are machinery. They exist so the app has
--                   a crowd to be tested against and they are not people;
--                   giving them indexed pages would be manufacturing a
--                   population, which is the one thing a directory must never
--                   do.
--
-- **No lyrics.** They live in `contributions`, they are the actual creative
-- work, and putting a song on the showcase is consent to have it *heard* —
-- the audio and who played on it — not consent to have its words transcribed
-- onto a public page. Lyrics would be the strongest search material this
-- product has and that is exactly why they need their own explicit decision,
-- made by the person who wrote them, rather than being taken as implied.
--
-- No block filtering either, and that is not an oversight: `showcase()` filters
-- on `blocked_between(auth.uid(), …)` because it has a viewer. A static page
-- has no viewer, so there is nobody to filter for. Blocking governs what
-- people see of each other inside the app; it cannot govern a public page,
-- and pretending otherwise would be a promise this cannot keep.

-- ---------------------------------------------------------------------
-- Songs somebody chose to show
-- ---------------------------------------------------------------------

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
    r.musical_key,
    coalesce(
      (select jsonb_agg(distinct jsonb_build_object(
                'name', coalesce(who.display_name, 'Somebody')))
         from public.song_layers l
         join public.profiles who on who.id = l.recorded_by
        where l.project_id = p.id
          and l.shared_at is not null
          and not who.is_demo
          and l.recorded_by is distinct from p.created_by),
      '[]'::jsonb
    ),
    (select count(distinct l.recorded_by) > 1
       from public.song_layers l
      where l.project_id = p.id and l.shared_at is not null)
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

comment on function public.public_songs(integer, integer) is
  'Songs their owner put on the showcase, for the static pages on '
  'colabroom.com. Consent is showcased_at and nothing else; no lyrics, no '
  'demo accounts, and no viewer to filter blocks for.';

-- ---------------------------------------------------------------------
-- People who chose to be found
-- ---------------------------------------------------------------------

create or replace function public.public_musicians(
  in_limit integer default 500,
  in_offset integer default 0
)
returns table (
  id uuid,
  display_name text,
  plays text[],
  sounds_like text[],
  city text,
  songs_on_showcase integer
)
language sql
stable
security definer
set search_path = public
as $fn$
  select
    pr.id,
    pr.display_name,
    pr.plays,
    pr.sounds_like,
    -- Only at 'public'. The default is 'nobody' and 'collaborators' means
    -- after the music rather than before it; neither is a licence to put
    -- somebody's town on the open web.
    case when pr.location_visibility = 'public' then pr.city else null end,
    (select count(*)::integer
       from public.projects p
      where p.created_by = pr.id
        and p.showcased_at is not null
        and p.deleted_at is null)
  from public.profiles pr
  where pr.discoverable
    and not pr.is_demo
    -- Somebody discoverable who has said nothing about themselves has no page
    -- worth making, and a directory of empty profiles is worse for everybody
    -- in it than a shorter one.
    and (cardinality(pr.plays) > 0 or cardinality(pr.sounds_like) > 0)
  order by pr.display_name
  limit greatest(least(in_limit, 2000), 1)
  offset greatest(in_offset, 0);
$fn$;

revoke all on function public.public_musicians(integer, integer) from public;
grant execute on function public.public_musicians(integer, integer)
  to anon, authenticated;

comment on function public.public_musicians(integer, integer) is
  'Musicians who turned discoverable on and said something about themselves, '
  'for the static pages on colabroom.com. City only at location_visibility '
  '= public.';
