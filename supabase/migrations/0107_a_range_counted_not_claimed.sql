-- A singer's range, on their page, counted rather than claimed.
--
-- 0106 gave every analysed recording its lowest and highest sung note. This
-- puts the span of them on a profile, next to "Played here" -- the section
-- whose rule is that nothing in it was typed. A range is the most useful
-- fact about a singer that no directory of musicians has ever carried,
-- because no directory ever heard them.
--
-- What counts, and why:
--
--   * recordings this person *uploaded* (`project_audio_references.uploaded_by`),
--     because that is the only link the app has between a recording and a
--     person. A take is a different thing and has no melody.
--   * only when they say they sing (`plays` overlaps vocal / harmony / rap).
--     A producer uploads the band's demos; without this gate their page would
--     carry the singer's range under the producer's name. Declaring the part
--     is the claim; the recordings are the count.
--   * the lowest low and the highest high across those recordings, and how
--     many recordings that is -- said on the page, so "E3 – A4" reads as
--     "from three recordings" and not as a certificate.
--
-- Served through musician_profile only, on exactly the visibility that
-- function already enforces. Not through find_musicians: a range is a thing
-- to read on somebody's page, not a column to rank by.
--
-- The function's return shape grows by three columns, so it is dropped and
-- recreated -- `create or replace` cannot change a RETURNS TABLE. Everything
-- else in it is exactly as 0097 left it.

drop function if exists public.musician_profile(uuid);

create function public.musician_profile(target uuid)
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
  location_visibility text,
  vocal_low_midi integer,
  vocal_high_midi integer,
  vocal_range_songs integer
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
    case when p.id = (select auth.uid()) then p.location_visibility else null end,
    case when sings.yes then sung.low end,
    case when sings.yes then sung.high end,
    case when sings.yes then sung.songs else 0 end
  from public.profiles p
  cross join lateral (
    select coalesce(p.plays, array[]::text[]) && array['vocal', 'harmony', 'rap']::text[] as yes
  ) sings
  cross join lateral (
    select
      min(r.melody_low_midi)::integer as low,
      max(r.melody_high_midi)::integer as high,
      count(*)::integer as songs
    from public.project_audio_references r
    join public.projects pj on pj.id = r.project_id and pj.deleted_at is null
    where r.uploaded_by = p.id
      and r.melody_low_midi is not null
      and r.melody_high_midi is not null
  ) sung
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
