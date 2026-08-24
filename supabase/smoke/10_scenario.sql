-- Writes a song the way the app writes one, so that every trigger in the
-- write path has to actually run.
--
-- This exists because `create or replace function` is not a check of anything.
-- plpgsql does not plan the statements inside a function body until the
-- function is called, so a body referencing a column that isn't there, or an
-- aggregate that doesn't exist for the type, is accepted without complaint and
-- fails the first time a real person triggers it. That is exactly how
-- `min(uuid)` reached production in 0018 and stayed there until somebody
-- noticed they could not add a line to a song.
--
-- So: no mocking, no assertions about function text. Insert the rows, let the
-- triggers fire, and check the side effects landed.

\set writer   '11111111-1111-1111-1111-111111111111'
\set bandmate '22222222-2222-2222-2222-222222222222'
\set room     '33333333-3333-3333-3333-333333333333'
\set project  '44444444-4444-4444-4444-444444444444'

begin;

-- Two accounts. Fires on_auth_user_created, which creates the profiles, and
-- claim_pending_invitations_on_profile behind it.
insert into auth.users (id, email, raw_user_meta_data) values
  (:'writer',   'writer@smoke.test',   '{"display_name": "Writer"}'),
  (:'bandmate', 'bandmate@smoke.test', '{"display_name": "Bandmate"}');

do $$
begin
  if (select count(*) from public.profiles) <> 2 then
    raise exception 'on_auth_user_created did not create a profile per user (got %)',
      (select count(*) from public.profiles);
  end if;
end $$;

-- From here on the session is the writer, the way a request carries a JWT.
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';

-- Fires profiles_set_updated_at and profiles_sync_member_display_name.
update public.profiles set display_name = 'The Writer' where id = :'writer';

insert into public.rooms (id, account_id, name) values (:'room', :'writer', 'Smoke Room');

insert into public.room_members (room_id, user_id, display_name, role) values
  (:'room', :'writer',   'The Writer', 'owner'),
  (:'room', :'bandmate', 'Bandmate',   'editor');

update public.rooms set name = 'Smoke Room, renamed' where id = :'room';

insert into public.projects (id, room_id, account_id, title, created_by)
values (:'project', :'room', :'writer', 'Smoke Song', :'writer');

update public.projects set description = 'a song for the test' where id = :'project';

-- One line at a time: the single-row branch of notify_project_update.
insert into public.contributions (project_id, author_id, author_name, body)
values (:'project', :'writer', 'The Writer', 'the first line');

-- Three lines in one statement: the multi-row branch, which is where the
-- statement-level trigger reaches into its transition table — and where
-- min(uuid) sat. A per-row test would never have got here.
insert into public.contributions (project_id, author_id, author_name, body) values
  (:'project', :'writer', 'The Writer', 'the second line'),
  (:'project', :'writer', 'The Writer', 'the third line'),
  (:'project', :'writer', 'The Writer', 'the fourth line');

do $$
begin
  if (select count(*) from public.contributions where project_id = '44444444-4444-4444-4444-444444444444') <> 4 then
    raise exception 'expected four lines to survive the insert triggers, found %',
      (select count(*) from public.contributions where project_id = '44444444-4444-4444-4444-444444444444');
  end if;
end $$;

-- Rewriting a line: contributions_set_updated_at, contributions_archive_revision.
update public.contributions
set body = 'the first line, rewritten'
where project_id = :'project' and body = 'the first line';

do $$
begin
  if (select count(*) from public.contribution_revisions) = 0 then
    raise exception 'contributions_archive_revision stored no revision for an edited line';
  end if;
end $$;

-- A bandmate reading the song and saying something about it.
insert into public.comments (contribution_id, author_id, body)
select id, :'bandmate', 'love this one'
from public.contributions
where project_id = :'project'
order by created_at
limit 1;

update public.comments set body = 'love this one, still' where author_id = :'bandmate';

insert into public.notification_preferences (user_id) values (:'writer')
on conflict (user_id) do nothing;
update public.notification_preferences set project_updates = false where user_id = :'writer';

-- The reporter the editor now calls when a save is refused.
insert into public.analysis_errors (user_id, service, stage, message, project_id)
values (:'writer', 'song_editor', 'save_document', 'smoke test error', :'project');

do $$
begin
  if (select count(*) from public.analysis_errors where coalesce(signature, '') = '') > 0 then
    raise exception 'analysis_errors_set_signature left a row without a signature';
  end if;
end $$;

-- Deleting a line, which is the third thing the editor's reconcile does.
delete from public.contributions
where project_id = :'project' and body = 'the fourth line';

-- The song's own activity stream should have noticed at least one of that.
do $$
begin
  if (select count(*) from public.project_events) = 0 then
    raise exception 'contributions_project_event recorded nothing for a written, edited and deleted song';
  end if;
end $$;

commit;
