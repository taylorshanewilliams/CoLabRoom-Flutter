-- Looking at one musician, including yourself.
--
-- 0058 gave the app a way to *browse* musicians, and browsing is gated on
-- `discoverable` for a good reason: nobody currently in this app agreed to be
-- listed anywhere. But that gate makes your own profile unreachable to you.
-- You cannot see the page other people would see, and you cannot tell whether
-- turning yourself on would show anything worth showing — which is exactly the
-- question somebody deciding to opt in wants answered first.
--
-- So this is the same shape find_musicians returns, for one person, under a
-- rule that adds nobody to the open list:
--
--   * yourself, always;
--   * anybody discoverable, which is already public via find_musicians;
--   * anybody you share a room with, who you can already read under the
--     profiles policy from 0001.
--
-- Nothing here widens what a stranger can see. It only lets the app open a
-- profile it already had the right to show.

create or replace function public.musician_profile(target uuid)
returns table (
  id uuid,
  display_name text,
  avatar_path text,
  city text,
  plays text[],
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
    -- Your own city is yours to see. Somebody else's arrives only when they
    -- published it; a collaborators-only city is answered by
    -- shared_city_with(), which checks that you actually made something
    -- together before it says anything.
    case
      when p.id = (select auth.uid()) then p.city
      when p.location_visibility = 'public' then p.city
      else null
    end,
    p.plays,
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
    -- Only ever true about yourself. Somebody else's setting is their
    -- business, and a client that could read it could build the list of
    -- people who chose not to be listed.
    case when p.id = (select auth.uid()) then p.discoverable else null end,
    case when p.id = (select auth.uid()) then p.location_visibility else null end
  from public.profiles p
  where p.id = target
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
-- Turning yourself on
-- ---------------------------------------------------------------------

-- The update policy on profiles would let a client write these columns
-- directly, and for `plays` and `city` that is fine. This exists so that
-- appearing in the open is one deliberate call with one name, rather than a
-- boolean somebody sets in passing — and so the two settings that decide what
-- strangers can see about you are always written together with the value
-- checked.
create or replace function public.set_open_mic_presence(
  in_discoverable boolean,
  in_city text default null,
  in_location_visibility text default null,
  in_plays text[] default null
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
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
      plays = coalesce(in_plays, plays)
  where id = auth.uid();
end;
$$;

revoke all on function public.set_open_mic_presence(boolean, text, text, text[])
  from public, anon;
grant execute on function public.set_open_mic_presence(boolean, text, text, text[])
  to authenticated;
