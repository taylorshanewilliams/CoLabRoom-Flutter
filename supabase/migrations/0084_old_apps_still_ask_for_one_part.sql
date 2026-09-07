-- Old apps still ask for one part.
--
-- 0083 changed `find_musicians` to take a list and **dropped the single-part
-- version in the same breath**. Every phone with a build older than that
-- calls the old signature, PostgREST cannot find a function by that name and
-- arguments, and the whole People half of the Open Mic comes back empty with
-- an error.
--
-- Which is exactly what happened, on a real phone, within the hour.
--
-- **A migration cannot assume the app matching it is installed.** Nobody
-- updates the moment a build lands, and the two are deployed by completely
-- separate paths — a migration applies in seconds and an APK reaches a phone
-- whenever somebody gets round to it. Anything the client calls has to keep
-- answering the old shape until the old shape is genuinely gone.
--
-- So the single-part form comes back, as a thin call through to the list one.
-- It is not a duplicate implementation: it has no logic of its own, cannot
-- drift, and can be dropped without ceremony once nothing calls it.

create or replace function public.find_musicians(
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
  shared_sounds text[],
  is_demo boolean,
  matched_parts text[]
)
language sql
stable
security definer
set search_path = public
as $fn$
  select *
  from public.find_musicians(
    case
      when in_part is null or char_length(trim(in_part)) = 0 then null
      else array[lower(trim(in_part))]
    end,
    in_city,
    in_limit,
    in_sounds_like
  );
$fn$;

revoke all on function public.find_musicians(text, text, integer, text)
  from public, anon;
grant execute on function public.find_musicians(text, text, integer, text)
  to authenticated;

comment on function public.find_musicians(text, text, integer, text) is
  'Compatibility shim for app builds older than 0083, which called this with '
  'a single part. Delegates to the text[] version and holds no logic of its '
  'own. Safe to drop once nothing on a phone calls it.';
