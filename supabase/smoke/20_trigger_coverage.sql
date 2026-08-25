-- Every trigger in the schema must be accounted for: either the scenario runs
-- it, or somebody has written down why it doesn't.
--
-- Without this, the smoke test only protects the triggers that existed on the
-- day it was written. 0018 added a trigger nobody exercised and it was broken
-- from the first line of its body; the next migration to do that should not be
-- able to pass quietly. A new trigger in neither list fails the build, which is
-- a two-line decision for whoever added it and the whole point of the gate.

begin;

create temporary table smoke_covered (name text primary key) on commit drop;
create temporary table smoke_acknowledged (name text primary key, reason text not null) on commit drop;

-- Fired by 10_scenario.sql, with its side effects asserted there.
insert into smoke_covered (name) values
  ('on_auth_user_created'),
  ('claim_pending_invitations_on_profile'),
  ('profiles_set_updated_at'),
  ('profiles_sync_member_display_name'),
  ('rooms_set_updated_at'),
  ('projects_set_updated_at'),
  ('contributions_set_updated_at'),
  ('contributions_archive_revision'),
  ('contributions_notify_project_update'),
  ('contributions_project_event'),
  ('comments_set_updated_at'),
  ('notification_preferences_set_updated_at'),
  ('analysis_errors_set_signature'),
  ('project_audio_references_notify_ready'),
  -- Moved up from acknowledged: the scenario now attaches a recording and
  -- takes it through to 'ready', so this one genuinely fires.
  ('project_audio_references_set_updated_at');

-- Not fired, and a deliberate choice rather than an oversight. Each of these
-- is the same one-line `set updated_at = now()` body on a table the scenario
-- has no reason to build. If one of them ever grows a real body, move it up.
insert into smoke_acknowledged (name, reason) values
  ('setlists_set_updated_at',                'timestamp only; setlists are not on the song write path'),
  ('studio_drafts_set_updated_at',           'timestamp only; studio drafts have their own service'),
  ('studio_chord_cues_set_updated_at',       'timestamp only'),
  ('chord_cues_set_updated_at',              'timestamp only; written by the analysis pipeline'),
  ('lyric_sync_cues_set_updated_at',         'timestamp only; written by the analysis pipeline');

do $$
declare
  unlisted text;
  stale text;
begin
  select string_agg(format('%s on %s', t.tgname, c.relname), ', ' order by t.tgname)
    into unlisted
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
  where not t.tgisinternal
    and n.nspname in ('public', 'auth')
    and t.tgname not in (select name from smoke_covered)
    and t.tgname not in (select name from smoke_acknowledged);

  if unlisted is not null then
    raise exception using message = format(
      'Trigger with no smoke coverage: %s. Add it to 10_scenario.sql, or to the acknowledged list in this file with a reason.',
      unlisted);
  end if;

  -- The lists are only worth trusting if they describe triggers that exist.
  select string_agg(name, ', ' order by name) into stale
  from (
    select name from smoke_covered
    union all
    select name from smoke_acknowledged
  ) listed
  where not exists (
    select 1 from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where not t.tgisinternal
      and n.nspname in ('public', 'auth')
      and t.tgname = listed.name
  );

  if stale is not null then
    raise exception using message = format(
      'Smoke lists name triggers that no longer exist: %s. Remove them.', stale);
  end if;
end $$;

commit;
