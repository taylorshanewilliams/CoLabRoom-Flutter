-- SQL cannot delete a stored object, and two functions here assumed it could.
--
-- Supabase guards `storage.objects` with a trigger:
--
--   ERROR: Direct deletion from storage tables is not allowed.
--          Use the Storage API instead.
--   HINT:  This prevents accidental data loss from orphaned objects.
--
-- Both `take_down_image` (0077) and `purge_demo` (0078) delete from that
-- table. Neither can have worked, and one of them is the moderation path —
-- the whole point of which is that it removes something.
--
-- **The smoke file passed both.** The shim builds a plain table with no
-- trigger on it, so CI proved the delete worked in a database where the
-- delete is allowed. That is the shim reporting on itself, the same failure
-- as the missing bucket columns two migrations ago, and it is fixed in
-- `00_shim.sql` alongside this so nothing else can be written against a
-- storage layer that does not behave like the real one.
--
-- **What changes.** These functions now do the half SQL is allowed to do —
-- unpoint the row, so nothing in the app resolves it — and hand back exactly
-- what the caller must delete through the Storage API. The callers are
-- `tools/take_down.py` and `tools/seed_demo.py`, which have the service key
-- and can reach the API.
--
-- This is a real weakening of `take_down_image` used alone, and it is stated
-- rather than hidden: clearing `avatar_path` stops the app drawing a picture,
-- but `avatars_read_authenticated` lets any signed-in account read any path
-- in that bucket. Somebody holding the old path could still fetch it. The
-- object must actually be deleted, and only the API can do it — so the
-- takedown is not finished until the tool has run.

-- Dropped rather than replaced: it grows a `bucket` column, and
-- `create or replace` cannot change the shape of a `returns table`.
drop function if exists public.take_down_image(uuid, text);

create function public.take_down_image(
  target_report uuid,
  in_note text default ''
)
returns table (what text, bucket text, cleared_path text)
language plpgsql
security definer
set search_path = public
as $fn$
declare
  report record;
  removed text;
  in_bucket text;
  label text;
begin
  select * into report from public.content_reports where id = target_report;
  if not found then
    raise exception 'No report with that id.' using errcode = '22023';
  end if;

  -- Read the path before clearing it, in every branch. `update ... returning`
  -- hands back the new value, which is null by construction here, and the
  -- path is the whole point of what this returns.
  if report.kind = 'profile' then
    select avatar_path into removed from public.profiles
    where id = report.target_profile;
    update public.profiles set avatar_path = null
    where id = report.target_profile;
    in_bucket := 'avatars';
    label := 'profile picture';

  elsif report.kind = 'room_logo' then
    select logo_path into removed from public.rooms
    where id = report.target_room;
    update public.rooms set logo_path = null where id = report.target_room;
    in_bucket := 'room-files';
    label := 'room logo';

  elsif report.kind = 'song_cover' then
    select cover_image_path into removed from public.projects
    where id = report.target_project;
    update public.projects set cover_image_path = null
    where id = report.target_project;
    in_bucket := 'room-files';
    label := 'song cover';

  else
    raise exception
      'take_down_image handles profile, room_logo and song_cover, not %.',
      report.kind
      using errcode = '22023';
  end if;

  perform public.resolve_report(
    target_report,
    'actioned',
    case
      when nullif(trim(coalesce(in_note, '')), '') is null
        then 'Image unpointed; object deletion pending.'
      else 'Image unpointed; object deletion pending. ' || trim(in_note)
    end
  );

  return query select label, in_bucket, removed;
end;
$fn$;

revoke all on function public.take_down_image(uuid, text)
  from public, anon, authenticated;

comment on function public.take_down_image(uuid, text) is
  'Clears a reported image from the row the app reads and closes the report, '
  'then returns the bucket and path the caller must delete through the '
  'Storage API — SQL is not allowed to delete a stored object. Not a '
  'complete takedown on its own: use tools/take_down.py. Service key only.';

-- ---------------------------------------------------------------------
-- And the same correction for the demo purge
-- ---------------------------------------------------------------------

-- Returns the prefixes to sweep rather than sweeping them, for the same
-- reason. `purge_demo_paths()` is read-only and safe to call first, so the
-- tool can delete the objects while the rows that name them still exist —
-- once the projects are gone there is nothing left to say which objects
-- belonged to them, and the bytes would be unreachable and still charged for.
create or replace function public.purge_demo_paths()
returns table (bucket text, prefix text)
language sql
stable
security definer
set search_path = public
as $fn$
  select 'room-files'::text, r.id::text || '/'
  from public.rooms r
  join public.profiles p on p.id = r.account_id
  where p.is_demo
  union all
  select 'avatars'::text, p.id::text || '/'
  from public.profiles p
  where p.is_demo;
$fn$;

revoke all on function public.purge_demo_paths()
  from public, anon, authenticated;

create or replace function public.purge_demo()
returns table (what text, removed bigint)
language plpgsql
security definer
set search_path = public
as $fn$
declare
  people uuid[];
  rooms_hit uuid[];
  projects_hit uuid[];
  n bigint;
begin
  select coalesce(array_agg(id), '{}'::uuid[]) into people
  from public.profiles where is_demo;

  if array_length(people, 1) is null then
    return query select 'nothing was seeded'::text, 0::bigint;
    return;
  end if;

  select coalesce(array_agg(id), '{}'::uuid[]) into rooms_hit
  from public.rooms where account_id = any(people);

  select coalesce(array_agg(id), '{}'::uuid[]) into projects_hit
  from public.projects where room_id = any(rooms_hit);

  -- No storage deletes here. See purge_demo_paths(): the objects are the
  -- caller's job, through the API, and must go first.
  delete from public.song_layers where project_id = any(projects_hit);
  get diagnostics n = row_count;
  what := 'takes'; removed := n; return next;

  delete from public.project_asks where project_id = any(projects_hit);
  get diagnostics n = row_count;
  what := 'asks'; removed := n; return next;

  delete from public.projects where id = any(projects_hit);
  get diagnostics n = row_count;
  what := 'songs'; removed := n; return next;

  delete from public.rooms where id = any(rooms_hit);
  get diagnostics n = row_count;
  what := 'rooms'; removed := n; return next;

  delete from public.room_members where user_id = any(people);
  get diagnostics n = row_count;
  what := 'memberships'; removed := n; return next;

  delete from public.project_members where user_id = any(people);
  get diagnostics n = row_count;
  what := 'song memberships'; removed := n; return next;

  delete from auth.users where id = any(people);
  get diagnostics n = row_count;
  what := 'accounts'; removed := n; return next;

  return;
end;
$fn$;

revoke all on function public.purge_demo() from public, anon, authenticated;

comment on function public.purge_demo() is
  'Removes every seeded demo account and everything it made. Storage objects '
  'are NOT included — call purge_demo_paths() and delete them through the '
  'Storage API first. Service key only.';
