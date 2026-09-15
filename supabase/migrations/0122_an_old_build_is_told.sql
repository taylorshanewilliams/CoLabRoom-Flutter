-- An old build is told.
--
-- The daily crash-free workflow has failed every morning since 10 September
-- and the email said only the percentage, so six days of alerts produced no
-- diagnosis. Read properly, the week says this:
--
--   0.4.2   86.54%   52 sessions, 7 with an error
--   0.4.1   92.11%   38 sessions, 3 with an error
--   0.4.0   83.33%   36 sessions, 6 with an error
--
-- and the errors under it are mostly one thing: builds that predate the app
-- learning to ignore a notification type it has never met. They throw on
-- `load` -- the whole library, not one screen -- the moment somebody sends
-- a message, because `direct_message` did not exist when they were built.
-- 0.4.0 and 0.4.1 phones are simply broken now, and two of the errors came
-- from builds that call themselves 0.4.2 as well.
--
-- `minimum_app_version` is the lever for exactly this, and it could not be
-- pulled: every build of the last week shares one version number, so no
-- comparison could separate the broken from the fixed. The app is 0.5.0 as
-- of today, which makes the line drawable, and this draws it.
--
-- Anyone below it sees one card asking them to update. It is true: their
-- app cannot load an inbox that now holds messages.

create or replace function public.minimum_app_version()
returns text
language sql
stable
set search_path = public
as $$
  select '0.5.0'::text
$$;

comment on function public.minimum_app_version() is
  'The oldest app version that still matches everybody else. A build below '
  'it shows one card asking its owner to update. Raise by migration, and '
  'only once a build at or above the new floor is actually installable — '
  'telling somebody to update to something that does not exist yet is worse '
  'than saying nothing.';
