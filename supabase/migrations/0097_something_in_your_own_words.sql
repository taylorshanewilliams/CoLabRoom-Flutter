-- Something in your own words.
--
-- Everything a profile says about somebody is currently either counted by the
-- app or picked from a list. `parts_recorded` is the record, `plays` and
-- `sounds_like` are chips, `city` is a place. There is nowhere to say the one
-- thing a person would actually lead with — that they have been playing
-- twenty years, or that they only write at night, or that they are looking
-- for a band rather than a session.
--
-- Two fields, both self-authored, both optional, and deliberately kept apart
-- from anything the app counts. The page already keeps *counted* and *claimed*
-- separate on purpose and this belongs firmly on the claimed side.

-- ---------------------------------------------------------------------
-- The bio
-- ---------------------------------------------------------------------

alter table public.profiles
  add column if not exists bio text;

-- Capped, and the cap is a design decision rather than a storage one.
--
-- Three hundred characters is a real paragraph — long enough to say what you
-- play and what you are after, short enough that a page of profiles stays
-- scannable and nobody arrives at somebody's page facing an essay. A field
-- with no limit becomes a press release on the day the first person decides
-- to write one, and every profile after it looks thin by comparison.
alter table public.profiles
  drop constraint if exists profiles_bio_length;
alter table public.profiles
  add constraint profiles_bio_length check (bio is null or length(bio) <= 300);

comment on column public.profiles.bio is
  'What somebody says about themselves, in their own words. Never counted, '
  'never ranked, and shown wherever their name is worth more than a row.';

-- ---------------------------------------------------------------------
-- Writing it
-- ---------------------------------------------------------------------

-- A function of its own rather than another parameter on
-- `set_open_mic_presence`.
--
-- That one takes `in_discoverable` as a required argument, so setting a bio
-- through it would mean re-asserting a privacy switch every time somebody
-- edits a sentence about themselves. Writing a bio must never be able to turn
-- discoverability on or off by accident, and the cheapest way to guarantee
-- that is a function that cannot.
create or replace function public.set_bio(in_bio text)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  cleaned text;
begin
  cleaned := nullif(btrim(coalesce(in_bio, '')), '');

  if cleaned is not null and length(cleaned) > 300 then
    raise exception 'A bio can be up to 300 characters.'
      using errcode = '22023';
  end if;

  -- Null clears it. A field you can fill in and not empty is not a field.
  update public.profiles
     set bio = cleaned
   where id = auth.uid();
end;
$$;

revoke all on function public.set_bio(text) from public, anon;
grant execute on function public.set_bio(text) to authenticated;

-- ---------------------------------------------------------------------
-- Reading it
-- ---------------------------------------------------------------------

-- `musician_profile` gains two columns and keeps everything else exactly as
-- 0063 left it, including the city rule and the three ways a page is allowed
-- to exist at all.
--
-- `sounds_like` is added at the same time because it has been collected since
-- 0076 and shown on this page never. It is the field that makes "like-minded"
-- mean anything and it was only ever reaching the matcher.
create or replace function public.musician_profile(target uuid)
returns table (
  id uuid,
  display_name text,
  avatar_path text,
  city text,
  plays text[],
  sounds_like text[],
  bio text,
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
as $$
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
    p.sounds_like,
    p.bio,
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
    -- A blocked profile has no page, the same way a profile that never opted
    -- in has no page. Returning nothing is the honest answer and it is also
    -- the one that says least.
    and not private.blocked_between((select auth.uid()), p.id)
    and (
      p.id = (select auth.uid())
      or p.discoverable
      or exists (
        select 1 from public.room_members rm
        where rm.user_id = p.id and private.is_room_member(rm.room_id)
      )
    );
$$;

revoke all on function public.musician_profile(uuid) from public, anon;
grant execute on function public.musician_profile(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- And on the page the world can see
-- ---------------------------------------------------------------------

-- The generated musician pages get it too, on the same consent as everything
-- else there: `discoverable` is the switch, and a bio is self-authored text
-- written to be read by somebody deciding whether to work with you — which is
-- precisely what that page is for. Nothing here reaches anybody who has not
-- turned themselves on.
create or replace function public.public_musicians(
  in_limit integer default 500,
  in_offset integer default 0
)
returns table (
  id uuid,
  display_name text,
  bio text,
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
    pr.bio,
    pr.plays,
    pr.sounds_like,
    case when pr.location_visibility = 'public' then pr.city else null end,
    (select count(*)::integer
       from public.projects p
      where p.created_by = pr.id
        and p.showcased_at is not null
        and p.deleted_at is null)
  from public.profiles pr
  where pr.discoverable
    and not pr.is_demo
    and (cardinality(pr.plays) > 0
         or cardinality(pr.sounds_like) > 0
         or pr.bio is not null)
  order by pr.display_name
  limit greatest(least(in_limit, 2000), 1)
  offset greatest(in_offset, 0);
$fn$;

revoke all on function public.public_musicians(integer, integer) from public;
grant execute on function public.public_musicians(integer, integer)
  to anon, authenticated;
