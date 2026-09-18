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
\set reffile  '55555555-5555-5555-5555-555555555555'

begin;

-- Push delivery configured before anything happens, so every notification
-- this file causes runs the 0051 trigger down its real path rather than
-- returning early. net.http_post is the shim in 00_shim.sql: the request is
-- never made, but the trigger body, the jsonb it builds and the columns it
-- reads are all executed.
insert into private.push_config (function_url, hook_secret)
values ('https://smoke.invalid/functions/v1/send-push', 'smoke-secret');

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

-- Distinct colours on purpose: a room's members are uniquely coloured
-- (room_members_room_color_unique, 0006) so that the bullet rail can tell
-- who wrote which line at a glance. Two members sharing the default is not
-- a state the app can produce.
insert into public.room_members (room_id, user_id, display_name, role, color_value) values
  (:'room', :'writer',   'The Writer', 'owner',  4294937164),
  (:'room', :'bandmate', 'Bandmate',   'editor', 4283215696);

update public.rooms set name = 'Smoke Room, renamed' where id = :'room';

insert into public.projects (id, room_id, account_id, title, created_by)
values (:'project', :'room', :'writer', 'Smoke Song', :'writer');

update public.projects set description = 'a song for the test' where id = :'project';

-- One line at a time. This used to exercise notify_project_update's
-- single-row branch; that trigger is gone as of 0046, and the edit now
-- reaches people through project_events instead.
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

-- Moving a line. Since 17 September 2026 the editor's save keeps a moved
-- line on its own row, so it changes only the line's position, and when
-- there is no room left between two lines it spaces the song out again. The
-- line being moved is usually somebody else's: here the bandmate, a room
-- editor, moves one of the writer's, through the column grant from 0006.
set local request.jwt.claims = '{"sub": "22222222-2222-2222-2222-222222222222"}';
set local role authenticated;

update public.contributions
set position = -1024
where project_id = :'project' and body = 'the third line';

reset role;
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';

do $$
begin
  if (
    select position from public.contributions
    where project_id = '44444444-4444-4444-4444-444444444444' and body = 'the third line'
  ) is distinct from -1024 then
    raise exception 'a room editor could not move a bandmate''s line';
  end if;
  if (
    select author_id from public.contributions
    where project_id = '44444444-4444-4444-4444-444444444444' and body = 'the third line'
  ) is distinct from '11111111-1111-1111-1111-111111111111'::uuid then
    raise exception 'moving a line changed who wrote it';
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

-- Attaching a recording and analysing it. The notification at the end is the
-- point: whoever started the analysis should be told it finished rather than
-- having to watch a progress ring to find out.
insert into public.files (id, project_id, uploaded_by, storage_path, display_name, mime_type)
values (:'reffile', :'project', :'writer',
        'smoke/analysis/reference.mp3', 'reference.mp3', 'audio/mpeg');

insert into public.project_audio_references (project_id, file_id, uploaded_by, analysis_state)
values (:'project', :'reffile', :'writer', 'processing');

update public.project_audio_references
set analysis_state = 'ready', bpm = 118, musical_key = 'D major'
where project_id = :'project';

do $$
begin
  if (select count(*) from public.notifications where type = 'analysis_ready') <> 1 then
    raise exception 'finishing an analysis did not notify the person who started it (got %)',
      (select count(*) from public.notifications where type = 'analysis_ready');
  end if;
end $$;

-- Writing 'ready' a second time must stay silent. Every re-analysis ends by
-- setting the same state, and without the transition guard on the trigger
-- each one would tell somebody again about a song that finished once.
update public.project_audio_references
set analysis_state = 'ready', bpm = 120
where project_id = :'project';

do $$
begin
  if (select count(*) from public.notifications where type = 'analysis_ready') <> 1 then
    raise exception 'a repeated ready write sent a duplicate notification (got %)',
      (select count(*) from public.notifications where type = 'analysis_ready');
  end if;
end $$;

-- ---------------------------------------------------------------------
-- A bandmate adds a part.
--
-- The trigger's whole job is to tell everyone *else* in the room, so the
-- assertions are about who did and did not hear about it. Getting this wrong
-- is not a crash: it is a band that never finds out somebody added a lead, or
-- a person notified about their own playing.
-- ---------------------------------------------------------------------

-- Recorded, and not shared. Since 0057 this is a private draft: it exists,
-- it belongs to the writer, and nobody else has been told anything. That is
-- the whole point of the change and it is asserted before anything else.
insert into public.song_layers
  (project_id, recorded_by, storage_path, label, part, performer, duration_ms)
values
  (:'project', :'writer', :'project' || '/layers/one.m4a',
   'Rhythm', 'rhythm', 'The Writer', 42000);

do $$
begin
  if exists (select 1 from public.notifications n
             where n.user_id = '22222222-2222-2222-2222-222222222222'
               and n.title like '%added a part%') then
    raise exception 'recording a take told the room before it was shared';
  end if;
end $$;

-- Now the writer decides the room can hear it.
select public.share_layer(
  (select id from public.song_layers
   where project_id = '44444444-4444-4444-4444-444444444444'
     and label = 'Rhythm')
);

do $$
begin
  -- The bandmate hears about it.
  if (select count(*) from public.notifications n
      where n.type = 'project_update'
        and n.user_id = '22222222-2222-2222-2222-222222222222'
        and n.title like '%added a part%') <> 1 then
    raise exception 'adding a layer did not notify the other member (got %)',
      (select count(*) from public.notifications n
       where n.user_id = '22222222-2222-2222-2222-222222222222'
         and n.title like '%added a part%');
  end if;

  -- The person who played it does not. notify_user returns early when the
  -- target is the actor, and the trigger relies on that rather than
  -- excluding the recorder itself — worth asserting, because the day that
  -- behaviour changes this is how we find out.
  if exists (select 1 from public.notifications n
             where n.user_id = '11111111-1111-1111-1111-111111111111'
               and n.title like '%added a part%') then
    raise exception 'the person who recorded the layer was notified about it';
  end if;
end $$;

-- A second layer, shared on insert -- which is what a client that shares
-- straight away does, and a path the trigger has to handle as well as the
-- update one.
insert into public.song_layers
  (project_id, recorded_by, storage_path, label, part, duration_ms, shared_at)
values
  (:'project', :'writer', :'project' || '/layers/two.m4a', 'Lead', 'lead', 30000, now());

do $$
begin
  if (select count(*) from public.notifications n
      where n.user_id = '22222222-2222-2222-2222-222222222222'
        and n.title like '%added a part%') <> 2 then
    raise exception 'a second layer did not produce a second notification (got %)',
      (select count(*) from public.notifications n
       where n.user_id = '22222222-2222-2222-2222-222222222222'
         and n.title like '%added a part%');
  end if;
end $$;

-- Editing a take that was already shared says nothing. The trigger fires on
-- any change to shared_at, so without the transition guard renaming a layer
-- would announce it to the room a second time -- which is exactly the kind of
-- pointless notification this whole change exists to remove.
update public.song_layers
set label = 'Lead, second pass'
where project_id = :'project' and part = 'lead';

update public.song_layers
set shared_at = now()
where project_id = :'project' and part = 'lead';

do $$
begin
  if (select count(*) from public.notifications n
      where n.user_id = '22222222-2222-2222-2222-222222222222'
        and n.title like '%added a part%') <> 2 then
    raise exception 'a take that was already shared announced itself again (got %)',
      (select count(*) from public.notifications n
       where n.user_id = '22222222-2222-2222-2222-222222222222'
         and n.title like '%added a part%');
  end if;
end $$;

-- A shared take is news, and the news can be played.
--
-- 0104: until then project_events had never held a single 'recording' row in
-- production -- the kind was allowed from 0032 and nothing wrote it -- so the
-- most exciting thing this app does never reached anybody's feed. These two
-- triggers put it there, and recent_activity carries the audio so it can be
-- heard from the top of Your music rather than described.
do $$
declare
  events integer;
  named integer;
begin
  -- No psql variables in here: the substitution happens during lexing and
  -- does not reach inside a dollar-quoted block, which is why every other
  -- check in this file counts rather than filters by id.
  select count(*) into events
  from public.project_events where kind = 'recording';

  -- Two shared layers were inserted above, and one of them had its shared_at
  -- rewritten while already shared. That last one must not produce a third
  -- event, for the same reason it must not produce a second notification.
  if events <> 2 then
    raise exception 'a shared take did not become news exactly once (got %)', events;
  end if;

  select count(*) into named
  from public.project_events where kind = 'recording' and ref_id is not null;
  if named <> 2 then
    raise exception 'a recording event does not say which take it is about';
  end if;
end $$;

-- A private take is a person practising. It is not news, and putting it in
-- somebody else's feed would publish a thing they did not publish -- 0057's
-- rule, which this trigger has to keep.
insert into public.song_layers
  (project_id, recorded_by, storage_path, label, part, duration_ms, shared_at)
values
  (:'project', :'writer', :'project' || '/layers/private.m4a', 'Scratch', 'other', 9000, null);

do $$
declare
  events integer;
begin
  select count(*) into events
  from public.project_events where kind = 'recording';
  if events <> 2 then
    raise exception 'an unshared take leaked into the feed (got % events)', events;
  end if;
end $$;

-- Taken back out. Everything after this counts the song's layers, and a
-- scratch take left lying around would fail a check about something else
-- entirely -- which is what happened the first time this was written.
delete from public.song_layers
where project_id = :'project' and part = 'other';

-- A saved version holds ids, not audio: deleting the layers it names must not
-- be blocked by it, and a version costs one row however many layers it lists.
insert into public.song_layer_versions (project_id, created_by, name, layer_ids)
select :'project', :'writer', 'Smoke mix', array_agg(id)
from public.song_layers where project_id = :'project';

do $$
begin
  if (select cardinality(layer_ids) from public.song_layer_versions limit 1) <> 2 then
    raise exception 'the saved version did not record both layers';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- A crash before anybody signs in.
--
-- The path that exists because the sign-in screen was the one place the app
-- could break without producing a single row. What matters is not only that a
-- report lands, but that the three guards hold — otherwise this is an
-- unauthenticated write into a table nothing else limits.
-- ---------------------------------------------------------------------

select public.report_anonymous_error(
  'auth', 'Could not reach the sign-in service', 'startup', 'error', '0.4.0', 'ios');

do $$
begin
  if (select count(*) from public.analysis_errors where anonymous) <> 1 then
    raise exception 'an anonymous crash report did not land (got %)',
      (select count(*) from public.analysis_errors where anonymous);
  end if;
  if (select user_id from public.analysis_errors where anonymous limit 1) is not null then
    raise exception 'an anonymous report was attributed to a user';
  end if;
end $$;

-- The same crash again, immediately. A crash loop must cost one row, not
-- thousands, and the client's own cooldown cannot be relied on for this — a
-- caller that ignores it is exactly who this guard is for.
select public.report_anonymous_error(
  'auth', 'Could not reach the sign-in service', 'startup', 'error', '0.4.0', 'ios');

do $$
begin
  if (select count(*) from public.analysis_errors where anonymous) <> 1 then
    raise exception 'a repeated anonymous crash was recorded twice';
  end if;
end $$;

-- A different crash still gets through, so the repeat guard is not simply a
-- lid on the whole feature.
select public.report_anonymous_error(
  'startup', 'Something else entirely went wrong', null, 'error', '0.4.0', 'android');

do $$
begin
  if (select count(*) from public.analysis_errors where anonymous) <> 2 then
    raise exception 'a distinct anonymous crash was refused (got %)',
      (select count(*) from public.analysis_errors where anonymous);
  end if;
end $$;

-- An empty message is nothing to report, and an unrecognised service is
-- either a caller bug or somebody else's traffic — it is filed under 'app'
-- rather than believed.
select public.report_anonymous_error('auth', '   ', null, 'error', null, null);
select public.report_anonymous_error(
  'not-a-real-service', 'Filed under app instead', null, 'error', null, null);

do $$
begin
  if (select count(*) from public.analysis_errors where anonymous) <> 3 then
    raise exception 'an empty anonymous message was recorded (got %)',
      (select count(*) from public.analysis_errors where anonymous);
  end if;
  if not exists (
    select 1 from public.analysis_errors
    where anonymous and message = 'Filed under app instead' and service = 'app'
  ) then
    raise exception 'an unrecognised service was not normalised to app';
  end if;
end $$;

-- A song's account follows the room it lives in (0043).
--
-- Exercised rather than acknowledged, because the reason this trigger exists
-- at all is that the invariant was already written down — in the projects
-- insert policy — and a different write path was allowed to break it
-- afterwards. A rule stated in one place and enforced in none is exactly what
-- this file is for.
insert into public.rooms (id, account_id, name)
values ('66666666-6666-6666-6666-666666666666', :'bandmate', 'The Other Band');

-- Inserted claiming the wrong account on purpose: the trigger has to overrule
-- the caller rather than trust them.
insert into public.projects (id, room_id, account_id, title, created_by)
values (
  '77777777-7777-7777-7777-777777777777',
  '66666666-6666-6666-6666-666666666666',
  :'writer',
  'A Song In The Other Band',
  :'writer'
);

do $$
begin
  if (select account_id from public.projects
      where id = '77777777-7777-7777-7777-777777777777')
     is distinct from '22222222-2222-2222-2222-222222222222'::uuid then
    raise exception 'a new song kept an account its room does not belong to (got %)',
      (select account_id from public.projects
       where id = '77777777-7777-7777-7777-777777777777');
  end if;
end $$;

-- The case that was actually broken. Moving a song into a room owned by
-- somebody else left account_id pointing at the room it came from — a row the
-- insert policy would have refused to create, reached by editing one it had
-- already accepted.
update public.projects
set room_id = '66666666-6666-6666-6666-666666666666'
where id = '44444444-4444-4444-4444-444444444444';

do $$
begin
  if (select account_id from public.projects
      where id = '44444444-4444-4444-4444-444444444444')
     is distinct from '22222222-2222-2222-2222-222222222222'::uuid then
    raise exception 'a moved song kept the account of the room it left (got %)',
      (select account_id from public.projects
       where id = '44444444-4444-4444-4444-444444444444');
  end if;
end $$;

-- Two people accepting an invitation to the same Room (0047).
--
-- This file used to hand-write two distinct colours into room_members with a
-- comment reading "two members sharing the default is not a state the app can
-- produce". The app produced it in every Room it had: 0018 rewrote
-- accept_room_invitation_by_id and dropped the palette pick, so the first
-- person to accept took the column default and the second collided with them
-- on room_members_room_color_unique and could not join at all.
--
-- The scenario missed it by never running the accept path — it built the
-- membership rows directly, the way no user can. So build this one the way
-- the app does: an owner row with no colour of its own, then two real
-- invitations accepted by two real accounts.
insert into auth.users (id, email, raw_user_meta_data) values
  ('88888888-8888-8888-8888-888888888888', 'joiner.one@smoke.test', '{"display_name": "Joiner One"}'),
  ('99999999-9999-9999-9999-999999999999', 'joiner.two@smoke.test', '{"display_name": "Joiner Two"}');

set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';

insert into public.rooms (id, account_id, name)
values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'writer', 'The Invite Room');

-- No color_value on purpose: the owner takes the table default, which is the
-- production shape — the colour every later joiner used to be handed too.
insert into public.room_members (room_id, user_id, display_name, role)
values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'writer', 'The Writer', 'owner');

select public.create_room_invitation(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'joiner.one@smoke.test', 'editor');
select public.create_room_invitation(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'joiner.two@smoke.test', 'editor');

-- Each invitee accepts as themselves. The email claim matters: the function
-- refuses an invitation addressed to a different address.
set local request.jwt.claims = '{"sub": "88888888-8888-8888-8888-888888888888", "email": "joiner.one@smoke.test"}';
select public.accept_room_invitation_by_id(i.id)
from public.invitations i
where i.room_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  and lower(i.email) = 'joiner.one@smoke.test'
  and i.status = 'pending';

-- The one that used to raise 23505. If 0047 is missing or wrong, the
-- statement above succeeded and this one fails the build here.
set local request.jwt.claims = '{"sub": "99999999-9999-9999-9999-999999999999", "email": "joiner.two@smoke.test"}';
select public.accept_room_invitation_by_id(i.id)
from public.invitations i
where i.room_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
  and lower(i.email) = 'joiner.two@smoke.test'
  and i.status = 'pending';

set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';

do $$
declare
  members int;
  colours int;
begin
  select count(*), count(distinct color_value)
    into members, colours
  from public.room_members
  where room_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

  if members <> 3 then
    raise exception 'both invitees should have joined the Room (got % members)', members;
  end if;
  -- The unique index would have caught a duplicate on its own; asserting it
  -- here says the trigger is what kept them apart, not luck.
  if colours <> 3 then
    raise exception 'members of a Room must hold distinct colours (got % across % members)',
      colours, members;
  end if;

  if exists (
    select 1 from public.invitations
    where room_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
      and status <> 'accepted'
  ) then
    raise exception 'accepting an invitation should mark it accepted';
  end if;
end $$;

-- Re-accepting keeps the colour you already have rather than spending a new
-- one. Cheap to assert and the reason the trigger looks for an existing row
-- before it looks at the palette.
do $$
declare
  before_colour bigint;
  after_colour bigint;
begin
  select color_value into before_colour
  from public.room_members
  where room_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    and user_id = '88888888-8888-8888-8888-888888888888';

  insert into public.room_members (room_id, user_id, display_name, role)
  values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
          '88888888-8888-8888-8888-888888888888', 'Joiner One', 'editor')
  on conflict (room_id, user_id) do update set role = excluded.role;

  select color_value into after_colour
  from public.room_members
  where room_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    and user_id = '88888888-8888-8888-8888-888888888888';

  if before_colour is distinct from after_colour then
    raise exception 're-joining changed a member colour (% -> %)',
      before_colour, after_colour;
  end if;
end $$;

-- project_members gets the same trigger, and had the same defect without a
-- unique index to make it loud: everyone invited to a single song was handed
-- the identical colour.
insert into public.project_members (project_id, user_id, display_name, role) values
  ('44444444-4444-4444-4444-444444444444', '88888888-8888-8888-8888-888888888888', 'Joiner One', 'editor'),
  ('44444444-4444-4444-4444-444444444444', '99999999-9999-9999-9999-999999999999', 'Joiner Two', 'editor');

do $$
begin
  if (select count(distinct color_value) from public.project_members
      where project_id = '44444444-4444-4444-4444-444444444444') <> 2 then
    raise exception 'members of a song must hold distinct colours';
  end if;
end $$;


-- A song asking for something, in both shapes (0049).
--
-- Run through the real insert rather than hand-built, for the reason the
-- member-colour bug taught: a trigger nobody exercises is a trigger that can
-- be broken from the first line of its body. announce_project_ask writes a
-- project_events row and notifies every other member of the room, and both of
-- those reach into tables it does not own.
--
-- A song of its own, in Smoke Room, on purpose. The song this file has been
-- carrying around gets moved into 'The Other Band' by the account-follows-room
-- case above, and that room has no members — so asking on it would run the
-- notification loop against an empty room and quietly assert nothing.
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';

insert into public.projects (id, room_id, account_id, title, created_by)
values (
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
  :'room',
  :'writer',
  'A Song That Asks',
  :'writer'
);

-- Open: no part named. The honest state of most unfinished songs, and the
-- shape that costs the person posting it no decision at all.
insert into public.project_asks (project_id, asked_by, part, note)
values ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', :'writer', null,
        'Not sure where this goes.');

-- Specific: a named part on the same song.
insert into public.project_asks (project_id, asked_by, part)
values ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', :'writer', 'drums');

do $$
begin
  if not exists (
    select 1 from public.project_events
    where project_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
      and kind = 'asked' and body like '%is asking what%'
  ) then
    raise exception 'an open ask did not reach the song activity stream';
  end if;

  if not exists (
    select 1 from public.project_events
    where project_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
      and kind = 'asked' and body like '%needs drums%'
  ) then
    raise exception 'a specific ask did not reach the song activity stream';
  end if;

  -- The bandmate is the other member of Smoke Room and should have been told
  -- twice. The person asking should never be told about their own ask.
  if (select count(*) from public.notifications
      where type = 'song_ask'
        and user_id = '22222222-2222-2222-2222-222222222222') <> 2 then
    raise exception 'the room was not told about both asks (got %)',
      (select count(*) from public.notifications
       where type = 'song_ask'
         and user_id = '22222222-2222-2222-2222-222222222222');
  end if;

  if exists (
    select 1 from public.notifications
    where type = 'song_ask'
      and user_id = '11111111-1111-1111-1111-111111111111'
  ) then
    raise exception 'the person asking was notified about their own ask';
  end if;
end $$;

-- 0092: an ask you can silence.
--
-- Being asked is the one kind of other people's activity that had no switch,
-- and it is the type most likely to arrive often if this app works. The
-- assertion that matters is the second half: silencing it must not silence
-- anything else, and turning it back on must actually turn it back on. A
-- one-way switch would be worse than no switch.
insert into public.notification_preferences (user_id, asks)
values ('22222222-2222-2222-2222-222222222222', false)
on conflict (user_id) do update set asks = false;

insert into public.project_asks (project_id, asked_by, part)
values ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', :'writer', 'percussion');

do $$
begin
  if (select count(*) from public.notifications
      where type = 'song_ask'
        and user_id = '22222222-2222-2222-2222-222222222222') <> 2 then
    raise exception 'an ask was delivered to somebody who had turned asks off';
  end if;
end $$;

update public.notification_preferences
set asks = true
where user_id = '22222222-2222-2222-2222-222222222222';

insert into public.project_asks (project_id, asked_by, part)
values ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', :'writer', 'harmony');

do $$
begin
  if (select count(*) from public.notifications
      where type = 'song_ask'
        and user_id = '22222222-2222-2222-2222-222222222222') <> 3 then
    raise exception 'turning asks back on did not start delivering them again';
  end if;

  -- And the switch is about being asked, nothing else. An invitation still
  -- arrives for somebody who only silenced asks.
  if not private.wants_invites('22222222-2222-2222-2222-222222222222') then
    raise exception 'silencing asks reached the other preferences';
  end if;
end $$;

-- 0136: messages and calls can be quieted too, each on its own switch.
insert into public.notification_preferences (user_id, messages, calls)
values ('22222222-2222-2222-2222-222222222222', false, true)
on conflict (user_id) do update set messages = false, calls = true;

do $$
declare
  before_messages int;
  before_calls int;
begin
  select count(*) into before_messages from public.notifications
  where type = 'direct_message' and user_id = '22222222-2222-2222-2222-222222222222';
  select count(*) into before_calls from public.notifications
  where type = 'call_started' and user_id = '22222222-2222-2222-2222-222222222222';

  perform private.notify_user('22222222-2222-2222-2222-222222222222', 'direct_message',
    'Writer', 'hello', null, null, null, '11111111-1111-1111-1111-111111111111');
  perform private.notify_user('22222222-2222-2222-2222-222222222222', 'call_started',
    'Writer started a call', 'Room. Join from the room.', null, null, null,
    '11111111-1111-1111-1111-111111111111');

  if (select count(*) from public.notifications
      where type = 'direct_message' and user_id = '22222222-2222-2222-2222-222222222222') <> before_messages then
    raise exception 'a message was announced to somebody who had quieted messages';
  end if;
  if (select count(*) from public.notifications
      where type = 'call_started' and user_id = '22222222-2222-2222-2222-222222222222') <> before_calls + 1 then
    raise exception 'quieting messages quieted calls as well';
  end if;

  update public.notification_preferences set messages = true, calls = false
  where user_id = '22222222-2222-2222-2222-222222222222';
  perform private.notify_user('22222222-2222-2222-2222-222222222222', 'direct_message',
    'Writer', 'hello again', null, null, null, '11111111-1111-1111-1111-111111111111');
  perform private.notify_user('22222222-2222-2222-2222-222222222222', 'call_started',
    'Writer started a call', 'Room. Join from the room.', null, null, null,
    '11111111-1111-1111-1111-111111111111');

  if (select count(*) from public.notifications
      where type = 'direct_message' and user_id = '22222222-2222-2222-2222-222222222222') <> before_messages + 1 then
    raise exception 'turning messages back on did not announce them again';
  end if;
  if (select count(*) from public.notifications
      where type = 'call_started' and user_id = '22222222-2222-2222-2222-222222222222') <> before_calls + 1 then
    raise exception 'a call was announced to somebody who had quieted calls';
  end if;

  update public.notification_preferences set calls = true
  where user_id = '22222222-2222-2222-2222-222222222222';
end $$;

-- Leaving nothing open behind, so the unique index tests below start clean.
update public.project_asks
set status = 'closed', closed_at = now()
where project_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
  and part in ('percussion', 'harmony');

-- One open ask per part, so a song cannot ask twice for the same thing.
do $$
begin
  begin
    insert into public.project_asks (project_id, asked_by, part)
    values ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
            '11111111-1111-1111-1111-111111111111', 'drums');
    raise exception 'a second open ask for drums was allowed';
  exception when unique_violation then
    null;
  end;
end $$;

-- Closed, then asked for again. A part answered months ago can be asked for a
-- second time, and the partial index has to allow that rather than making the
-- first ask permanent.
update public.project_asks
set status = 'closed', closed_at = now()
where project_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' and part = 'drums';

insert into public.project_asks (project_id, asked_by, part)
values ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
        '11111111-1111-1111-1111-111111111111', 'drums');

-- Heard it: the cheap answer to the cheap ask, and visible to the room in the
-- way read state deliberately is not.
insert into public.project_nods (project_id, profile_id)
values ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
        '22222222-2222-2222-2222-222222222222');

do $$
begin
  if not exists (
    select 1 from public.project_nods
    where project_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
      and profile_id = '22222222-2222-2222-2222-222222222222'
  ) then
    raise exception 'a nod did not land';
  end if;
end $$;


-- The provenance record (0055).
--
-- A function that reads six tables and unions them is a function that breaks
-- the first time any one of them changes a column, and plpgsql does not plan
-- a body until somebody calls it -- which is how min(uuid) reached production
-- and stayed there. So it is called here, on the song this file has been
-- building all along, and the shape of what comes back is asserted.
do $$
declare
  rows_back integer;
  first_event text;
begin
  select count(*) into rows_back
  from public.song_provenance('44444444-4444-4444-4444-444444444444');

  if rows_back = 0 then
    raise exception 'the provenance record for a song with lyrics and takes is empty';
  end if;

  select event into first_event
  from public.song_provenance('44444444-4444-4444-4444-444444444444')
  order by at asc limit 1;

  -- Oldest first, and the oldest thing that can happen to a song is that
  -- somebody made it. If this ever comes back as something else, the ordering
  -- has inverted and the record reads as a story told backwards.
  if first_event is distinct from 'song created' then
    raise exception 'the record does not begin with the song being created (got %)',
      first_event;
  end if;

  -- The lyric lines this file wrote have to be in there, with an author.
  if not exists (
    select 1 from public.song_provenance('44444444-4444-4444-4444-444444444444')
    where event = 'lyric written' and who is not null
  ) then
    raise exception 'lyrics are missing from the provenance record';
  end if;
end $$;

do $$
declare
  summary record;
begin
  select * into summary
  from public.song_provenance_summary('44444444-4444-4444-4444-444444444444');

  if summary.title is null then
    raise exception 'the provenance summary found no song';
  end if;
  if coalesce(summary.contributors, 0) < 1 then
    raise exception 'the provenance summary counted no contributors';
  end if;
end $$;


-- Finding a musician (0058).
--
-- Three things worth proving, and the second is the one that would go wrong
-- silently: that a private take counts for nothing, that the search reads the
-- record rather than only the declaration, and that a city nobody made public
-- does not come back from the open browse surface.
update public.profiles
set discoverable = true,
    plays = array['vocal'],
    city = 'Glasgow',
    location_visibility = 'collaborators'
where id = :'writer';

do $$
declare
  found record;
begin
  select * into found from public.find_musicians(array['lead'], null, 10)
  where id = '11111111-1111-1111-1111-111111111111';

  if found.id is null then
    raise exception 'somebody who has recorded a lead take was not found by "lead"';
  end if;

  -- Declared 'vocal', recorded 'lead' and 'rhythm'. Both routes have to work
  -- or half of everybody is invisible to the search.
  if (found.parts_recorded ->> 'lead') is null then
    raise exception 'the record of what they have played is missing';
  end if;

  -- collaborators, not public. An open browse surface must not hand out a
  -- city its owner only offered to people they have made music with.
  if found.city is not null then
    raise exception 'a collaborators-only city leaked into the open search (got %)',
      found.city;
  end if;
end $$;

do $$
begin
  -- Found by what they said, as well as by what they did.
  if not exists (
    select 1 from public.find_musicians(array['vocal'], null, 10)
    where id = '11111111-1111-1111-1111-111111111111'
  ) then
    raise exception 'a declared instrument did not find its owner';
  end if;

  -- And not found by a city they never made public.
  if exists (
    select 1 from public.find_musicians(null::text[], 'Glasgow', 10)
    where id = '11111111-1111-1111-1111-111111111111'
  ) then
    raise exception 'searching a city found somebody who never published one';
  end if;

  -- Nobody who has not opted in appears at all.
  if exists (
    select 1 from public.find_musicians(null::text[], null, 50)
    where id = '22222222-2222-2222-2222-222222222222'
  ) then
    raise exception 'a profile that never opted in was listed';
  end if;
end $$;


-- Showcase links (0059).
--
-- The allowlist is the security-relevant part of this migration, so it is
-- tested from the hostile side as well as the friendly one. A profile that
-- renders arbitrary user-supplied URLs is a phishing surface with a
-- musician's name on it.
insert into public.profile_links (profile_id, url, title)
values (:'writer', 'https://open.spotify.com/track/abc123', 'Ladder Of Life');

do $$
begin
  if (select platform from public.profile_links
      where profile_id = '11111111-1111-1111-1111-111111111111') <> 'Spotify' then
    raise exception 'the platform was not derived from the host';
  end if;
end $$;

do $$
begin
  -- A host nobody named.
  begin
    insert into public.profile_links (profile_id, url)
    values ('11111111-1111-1111-1111-111111111111', 'https://evil.example/track');
    raise exception 'a link to an unlisted host was accepted';
  exception when sqlstate '22023' then null;
  end;

  -- The classic disguise: credentials in front of a friendly-looking host.
  begin
    insert into public.profile_links (profile_id, url)
    values ('11111111-1111-1111-1111-111111111111',
            'https://open.spotify.com@evil.example/track');
    raise exception 'a URL with credentials in the host was accepted';
  exception when sqlstate '22023' then null;
  end;

  -- Not https.
  begin
    insert into public.profile_links (profile_id, url)
    values ('11111111-1111-1111-1111-111111111111',
            'javascript:alert(1)//soundcloud.com');
    raise exception 'a javascript: URL was accepted';
  exception when sqlstate '22023' then null;
  end;
end $$;


-- A profile of your own (0060).
--
-- musician_profile() is the only way the app can show somebody their own page,
-- and it is the one read that deliberately reaches past `discoverable`. Two
-- things have to hold: it answers about you whatever your settings say, and it
-- never turns somebody's private settings into an answer about them.
do $$
declare
  mine record;
  theirs record;
begin
  select * into mine
  from public.musician_profile('11111111-1111-1111-1111-111111111111');

  if mine.id is null then
    raise exception 'a signed-in person could not open their own profile';
  end if;

  -- Your own settings come back as settings. Compared against the column
  -- rather than against a literal, because whether the writer has opted in by
  -- this point in the scenario is a detail of the block above and not the
  -- thing being tested.
  if mine.discoverable is distinct from
     (select p.discoverable from public.profiles p
      where p.id = '11111111-1111-1111-1111-111111111111') then
    raise exception 'own discoverable came back as % rather than the stored value',
      mine.discoverable;
  end if;

  -- The bandmate shares a room, so the page opens; their settings do not.
  select * into theirs
  from public.musician_profile('22222222-2222-2222-2222-222222222222');

  if theirs.id is null then
    raise exception 'a roommate profile could not be opened';
  end if;
  if theirs.discoverable is not null or theirs.location_visibility is not null then
    raise exception 'somebody else''s Open Mic settings were readable';
  end if;
end $$;

-- Turning yourself on, and the check that stops a bad value getting in.
select public.set_open_mic_presence(true, 'Glasgow', 'public',
                                    array['bass', 'keys']);

do $$
declare
  mine record;
begin
  select * into mine
  from public.musician_profile('11111111-1111-1111-1111-111111111111');

  if not mine.discoverable then
    raise exception 'set_open_mic_presence did not list the writer';
  end if;
  if mine.city <> 'Glasgow' or mine.plays <> array['bass', 'keys'] then
    raise exception 'set_open_mic_presence wrote % / %', mine.city, mine.plays;
  end if;

  -- And now they are in the open list, which they were not two blocks ago.
  if not exists (
    select 1 from public.find_musicians(array['bass'], 'Glasgow', 50)
    where id = '11111111-1111-1111-1111-111111111111'
  ) then
    raise exception 'somebody who opted in did not appear in find_musicians';
  end if;

  begin
    perform public.set_open_mic_presence(true, null, 'everyone', null);
    raise exception 'an unknown location visibility was accepted';
  exception when sqlstate '22023' then null;
  end;

  -- A setting you can turn on and not off is not a setting: an empty city
  -- clears it, where a null one would have left it alone.
  perform public.set_open_mic_presence(false, '', null, null);
  select * into mine
  from public.musician_profile('11111111-1111-1111-1111-111111111111');
  if mine.city is not null then
    raise exception 'an empty city did not clear the city';
  end if;
  if mine.plays <> array['bass', 'keys'] then
    raise exception 'a null plays overwrote what was there';
  end if;
end $$;


-- Asking one person (0061).
--
-- The security property is the whole feature: an ask must grant nothing. If
-- sending one gave a stranger a read on the song, Open Mic would be a way to
-- hand out other people's unfinished work.
-- The refusal first, and on a song that genuinely is not the writer's to
-- offer: line 398 moves :'project' into The Other Band, which the writer is
-- not a member of.
--
-- This is here because of how the test was written the first time. It asked
-- about :'project', was refused, and looked like a bug in ask_musician — it
-- was the check working on a song that had moved. Keeping it as an assertion
-- turns that accident into the only proof in this file that the refusal is
-- reachable at all.
do $$
begin
  begin
    -- Spelled out rather than :'project': psql does not substitute its
    -- variables inside a dollar-quoted body, so the reference would reach
    -- the server literally and fail on the colon.
    perform public.ask_musician(
      '44444444-4444-4444-4444-444444444444',
      '22222222-2222-2222-2222-222222222222', 'bass', '');
    raise exception 'a song in somebody else''s catalog was offered';
  exception when insufficient_privilege then null;
  end;
end $$;

-- And a song of the writer's own, to offer for real.
insert into public.projects (id, room_id, account_id, title, created_by)
values ('aaaaaaaa-0000-0000-0000-00000000000a', :'room', :'writer',
        'Song To Offer', :'writer');

-- Something to hear, and something already played on it (0094). An ask
-- nobody can listen to is not a request, it is a riddle.
insert into public.song_layers
  (project_id, recorded_by, storage_path, label, part, duration_ms, shared_at)
values
  ('aaaaaaaa-0000-0000-0000-00000000000a', :'writer',
   'aaaaaaaa/layers/offer.m4a', 'Guitar', 'rhythm', 92000, now());

-- 0095: what the song has not got.
--
-- The picker behind "ask them to play on…" now carries what is already on
-- each song, so the sheet can light the chip for the thing this person does
-- that the song lacks instead of asking somebody for a decision it watched
-- them make two screens ago. Not "missing": need is a musical judgement and
-- the app has no standing to make it. What is on it is a fact.
do $$
declare
  offered record;
begin
  select * into offered
  from public.songs_i_can_offer('22222222-2222-2222-2222-222222222222')
  where id = 'aaaaaaaa-0000-0000-0000-00000000000a';

  if offered.id is null then
    raise exception 'the song picker did not offer a song of my own';
  end if;
  if not (offered.parts_on_it @> array['rhythm']) then
    raise exception 'the picker did not say what is already on the song (got %)',
      offered.parts_on_it;
  end if;
  if offered.already_asked then
    raise exception 'a song nobody has been asked about came back as asked';
  end if;
end $$;

select public.ask_musician(
  'aaaaaaaa-0000-0000-0000-00000000000a',
  '22222222-2222-2222-2222-222222222222',
  'bass',
  'Something simple under the chorus.'
);

do $$
declare
  sent record;
begin
  select * into sent from public.project_asks
  where asked_of = '22222222-2222-2222-2222-222222222222';

  if sent.id is null then
    raise exception 'the ask was not written';
  end if;
  if sent.status <> 'open' or sent.part <> 'bass' then
    raise exception 'the ask was written wrong: % / %', sent.status, sent.part;
  end if;

  -- The person asked was told, and the notification carries the title, which
  -- is the only thing about the song they can see before answering.
  if not exists (
    select 1 from public.notifications n
    where n.user_id = '22222222-2222-2222-2222-222222222222'
      and n.type = 'song_ask'
  ) then
    raise exception 'nobody told the person who was asked';
  end if;

  -- And nothing was granted.
  if exists (
    select 1 from public.project_members m
    where m.project_id = sent.project_id
      and m.user_id = '22222222-2222-2222-2222-222222222222'
  ) then
    raise exception 'asking somebody put them on the song before they agreed';
  end if;

  -- Asking twice about the same song is refused rather than queued.
  begin
    perform public.ask_musician(
      sent.project_id, '22222222-2222-2222-2222-222222222222', 'keys', '');
    raise exception 'a second open ask to the same person was accepted';
  exception when unique_violation then null;
  end;
end $$;

-- Now the bandmate answers, the way a second request would.
set local request.jwt.claims = '{"sub": "22222222-2222-2222-2222-222222222222"}';

do $$
declare
  mine record;
  the_ask uuid;
begin
  select * into mine from public.asks_for_me() limit 1;
  if mine.id is null then
    raise exception 'asks_for_me showed the asked person nothing';
  end if;
  if mine.song_title is null then
    raise exception 'the ask did not carry the song title';
  end if;
  the_ask := mine.id;

  -- 0094: the ask carries the brief.
  --
  -- Before this, all of it existed in the database and none of it reached
  -- the person being asked — so the only honest answer was "let me go and
  -- look", and the number of people who go and look is the number of
  -- collaborations this app can ever have.
  if mine.storage_path is null then
    raise exception 'the ask arrived with nothing to listen to';
  end if;
  if mine.duration_ms is null then
    raise exception 'the ask did not say how long the song is';
  end if;
  if not (mine.parts_on_it @> array['rhythm']) then
    raise exception 'the ask did not say what is already on the song (got %)',
      mine.parts_on_it;
  end if;

  -- And they can actually reach it. Somebody asked to play on a song is not
  -- in its room, not on the song, has no invitation, and the song is
  -- usually on neither public surface — so every branch 0067 and 0088 added
  -- misses them, and the card would name a song it could not play.
  if not exists (
    select 1 from public.projects
    where id = 'aaaaaaaa-0000-0000-0000-00000000000a'
  ) then
    raise exception 'the person asked cannot see the song they were asked about';
  end if;
  if not exists (
    select 1 from public.song_layers
    where storage_path = 'aaaaaaaa/layers/offer.m4a'
  ) then
    raise exception 'the person asked cannot hear the take on it';
  end if;

  perform public.answer_ask(the_ask, true);

  -- And the loan ends with the ask. Consent that outlived the question it
  -- was granted for would be a fourth audience nobody chose.
  if exists (
    select 1 from public.project_asks a
    where a.project_id = 'aaaaaaaa-0000-0000-0000-00000000000a'
      and a.asked_of = '22222222-2222-2222-2222-222222222222'
      and a.status = 'open'
  ) then
    raise exception 'the ask stayed open after it was answered';
  end if;

  if not exists (
    select 1 from public.project_members m
    where m.user_id = '22222222-2222-2222-2222-222222222222'
  ) then
    raise exception 'saying yes did not put them on the song';
  end if;

  if (select status from public.project_asks where id = the_ask) <> 'closed' then
    raise exception 'answering did not close the ask';
  end if;

  -- Answering twice is not an error, and does not undo anything.
  perform public.answer_ask(the_ask, false);
  if (select status from public.project_asks where id = the_ask) <> 'closed' then
    raise exception 'a second answer overwrote the first';
  end if;
end $$;

-- 0093: what happened between people.
--
-- The ledger is written by triggers rather than by the app, which is the
-- whole reason to trust it — but a trigger nobody exercises is a trigger
-- nobody notices has stopped firing. These are the three kinds that carry
-- the signal, and the one distinction the state table cannot make.
do $$
declare
  asked_by_me uuid := '11111111-1111-1111-1111-111111111111';
  the_other uuid := '22222222-2222-2222-2222-222222222222';
begin
  if not exists (
    select 1 from private.collaboration_events
    where kind = 'asked' and by_user = asked_by_me
  ) then
    raise exception 'asking somebody was not written down';
  end if;

  -- Saying yes, recorded from the answerer's side: they acted, the asker is
  -- who it was with.
  if not exists (
    select 1 from private.collaboration_events
    where kind = 'accepted'
      and by_user = the_other
      and with_user = asked_by_me
  ) then
    raise exception 'an accepted ask was not written down';
  end if;

  -- The distinction project_asks cannot make on its own: both of these end
  -- as status 'closed', and answered_at is what tells them apart.
  if exists (
    select 1 from private.collaboration_events
    where kind = 'withdrawn' and by_user = the_other
  ) then
    raise exception 'an accepted ask was recorded as a withdrawal';
  end if;

  -- And nothing about a person that could be shown as a score. The table is
  -- readable by the database and by nobody else.
  if has_table_privilege('authenticated', 'private.collaboration_events',
                         'select') then
    raise exception 'the collaboration ledger is readable by signed-in users';
  end if;
end $$;

set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';

-- Somebody else's ask is not yours to answer.
do $$
declare
  the_ask uuid;
begin
  select id into the_ask from public.project_asks
  where asked_of = '22222222-2222-2222-2222-222222222222' limit 1;
  begin
    perform public.answer_ask(the_ask, true);
    raise exception 'a stranger answered an ask aimed at somebody else';
  exception when insufficient_privilege then null;
  end;
end $$;


-- Who is in this band (0062).
--
-- Membership could only ever grow. These are the two ways out and the one
-- thing neither of them may do.
do $$
begin
  -- The owner is not removable, by anybody, including themselves. A catalog
  -- with no owner is one nobody can invite to, rename or delete: the rows are
  -- still there and nobody can reach them.
  begin
    perform public.remove_room_member(
      '33333333-3333-3333-3333-333333333333',
      '11111111-1111-1111-1111-111111111111');
    raise exception 'the owner was removed from their own catalog';
  exception when sqlstate '22023' then null;
  end;
end $$;

-- A member with a per-song role, so removal can be checked to take both.
insert into public.project_members (project_id, user_id, display_name, role)
values ('44444444-4444-4444-4444-444444444444',
        '22222222-2222-2222-2222-222222222222', 'Bandmate', 'editor')
on conflict (project_id, user_id) do nothing;

select public.remove_room_member(
  '33333333-3333-3333-3333-333333333333',
  '22222222-2222-2222-2222-222222222222');

do $$
begin
  if exists (
    select 1 from public.room_members
    where room_id = '33333333-3333-3333-3333-333333333333'
      and user_id = '22222222-2222-2222-2222-222222222222'
  ) then
    raise exception 'removing a member did not remove them';
  end if;

  -- The half that is easy to forget: somebody taken out of a catalog who
  -- keeps an editor row on four of its songs has not been removed, they have
  -- been removed from the list that displays them.
  if exists (
    select 1 from public.project_members pm
    join public.projects p on p.id = pm.project_id
    where p.room_id = '33333333-3333-3333-3333-333333333333'
      and pm.user_id = '22222222-2222-2222-2222-222222222222'
  ) then
    raise exception 'removal left the per-song memberships behind';
  end if;
end $$;

-- Inviting somebody by profile rather than by email, and the consent rule:
-- sending grants nothing.
select public.invite_musician_to_room(
  '33333333-3333-3333-3333-333333333333',
  '22222222-2222-2222-2222-222222222222',
  'Come back, we miss the bass.');

do $$
begin
  if exists (
    select 1 from public.room_members
    where room_id = '33333333-3333-3333-3333-333333333333'
      and user_id = '22222222-2222-2222-2222-222222222222'
  ) then
    raise exception 'inviting somebody put them in the catalog before they agreed';
  end if;

  -- Twice is refused rather than queued, same cap as an ask.
  begin
    perform public.invite_musician_to_room(
      '33333333-3333-3333-3333-333333333333',
      '22222222-2222-2222-2222-222222222222', '');
    raise exception 'a second open invitation to the same person was accepted';
  exception when unique_violation then null;
  end;
end $$;

set local request.jwt.claims = '{"sub": "22222222-2222-2222-2222-222222222222"}';

do $$
declare
  mine record;
begin
  select * into mine from public.room_invites_for_me() limit 1;
  if mine.id is null then
    raise exception 'the invited person was shown nothing';
  end if;

  perform public.answer_room_invite(mine.id, true);

  if not exists (
    select 1 from public.room_members
    where room_id = '33333333-3333-3333-3333-333333333333'
      and user_id = '22222222-2222-2222-2222-222222222222'
  ) then
    raise exception 'accepting did not put them back in the catalog';
  end if;

  -- 0047's colour trigger ran on the way back in. A rejoin that reused a
  -- colour already taken is the shape of the bug a real tester hit.
  if (select count(distinct color_value)
      from public.room_members
      where room_id = '33333333-3333-3333-3333-333333333333')
     <> (select count(*) from public.room_members
         where room_id = '33333333-3333-3333-3333-333333333333') then
    raise exception 'two members of one catalog ended up the same colour';
  end if;

  -- And leaving is theirs to do, without asking anybody.
  perform public.leave_room('33333333-3333-3333-3333-333333333333');
  if exists (
    select 1 from public.room_members
    where room_id = '33333333-3333-3333-3333-333333333333'
      and user_id = '22222222-2222-2222-2222-222222222222'
  ) then
    raise exception 'leaving did not work';
  end if;
end $$;

set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';


-- Blocking and reporting (0063).
--
-- The property worth testing is that a block *does* something. A block that
-- only removes a row from one list is theatre: the person is still in search,
-- can still open the profile, can still send an ask. Every surface a stranger
-- reaches somebody through is checked here.

-- Both are discoverable first, so "gone" means gone rather than never there.
update public.profiles
set discoverable = true, location_visibility = 'public', city = 'Glasgow'
where id in ('11111111-1111-1111-1111-111111111111',
             '22222222-2222-2222-2222-222222222222');

do $$
begin
  if not exists (
    select 1 from public.find_musicians(null::text[], null, 50)
    where id = '22222222-2222-2222-2222-222222222222'
  ) then
    raise exception 'the bandmate was not findable before the block';
  end if;
end $$;

select public.block_user('22222222-2222-2222-2222-222222222222');

do $$
begin
  -- Gone from search.
  if exists (
    select 1 from public.find_musicians(null::text[], null, 50)
    where id = '22222222-2222-2222-2222-222222222222'
  ) then
    raise exception 'a blocked person is still in find_musicians';
  end if;

  -- No page.
  if exists (
    select 1 from public.musician_profile(
      '22222222-2222-2222-2222-222222222222')
  ) then
    raise exception 'a blocked person still has a profile page';
  end if;

  -- No showcase either, which is the surface that read the table directly
  -- and would have been the one thing to survive.
  if exists (
    select 1 from public.showcase_for(
      '22222222-2222-2222-2222-222222222222')
  ) then
    raise exception 'a blocked person still shows their links';
  end if;

  -- Cannot be asked.
  begin
    perform public.ask_musician(
      'aaaaaaaa-0000-0000-0000-00000000000a',
      '22222222-2222-2222-2222-222222222222', 'keys', '');
    raise exception 'a blocked person could still be asked';
  exception when sqlstate '22023' then null;
  end;

  -- Cannot be invited.
  begin
    perform public.invite_musician_to_room(
      '33333333-3333-3333-3333-333333333333',
      '22222222-2222-2222-2222-222222222222', '');
    raise exception 'a blocked person could still be invited';
  exception when sqlstate '22023' then null;
  end;
end $$;

-- Symmetric: from the other side it looks the same, and nothing says why.
set local request.jwt.claims = '{"sub": "22222222-2222-2222-2222-222222222222"}';

do $$
begin
  if exists (
    select 1 from public.find_musicians(null::text[], null, 50)
    where id = '11111111-1111-1111-1111-111111111111'
  ) then
    raise exception 'the block was one-directional, so the blocked person can still watch';
  end if;

  -- And they cannot read who blocked them. people_i_blocked answers only
  -- about the caller, which is what keeps a block quiet.
  if exists (select 1 from public.people_i_blocked()) then
    raise exception 'the blocked person can see a block they did not make';
  end if;
end $$;

-- Reporting, from the side that would actually do it.
select public.report_content(
  'profile', 'harassment', 'Kept messaging after I asked them to stop.',
  '11111111-1111-1111-1111-111111111111');

do $$
begin
  if not exists (
    select 1 from public.content_reports
    where reporter_id = '22222222-2222-2222-2222-222222222222'
      and kind = 'profile' and reason = 'harassment' and status = 'open'
  ) then
    raise exception 'the report was not filed';
  end if;

  -- Exactly one target, enforced by the table rather than by the client.
  begin
    insert into public.content_reports (kind, reason, target_profile, target_project)
    values ('profile', 'spam',
            '11111111-1111-1111-1111-111111111111',
            '44444444-4444-4444-4444-444444444444');
    raise exception 'a report pointing at two things was accepted';
  exception when check_violation then null;
  end;
end $$;

set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';

-- Undoing it puts everything back.
select public.unblock_user('22222222-2222-2222-2222-222222222222');

do $$
begin
  if not exists (
    select 1 from public.find_musicians(null::text[], null, 50)
    where id = '22222222-2222-2222-2222-222222222222'
  ) then
    raise exception 'unblocking did not restore them';
  end if;
end $$;


-- Closing a report (0064).
--
-- The queue has to drain, and what happened has to survive — the repeat
-- infringer policy on the website counts actioned copyright reports, and it
-- can only count them if resolving one records rather than erases.
do $$
declare
  the_report uuid;
  strikes bigint;
begin
  select id into the_report from public.content_reports
  where reason = 'harassment' limit 1;

  perform public.resolve_report(the_report, 'dismissed', 'No evidence of it.');

  if (select status from public.content_reports where id = the_report)
     <> 'dismissed' then
    raise exception 'resolving did not change the status';
  end if;

  -- The note is appended, not substituted: what the reporter said is still
  -- there underneath what was decided.
  if (select detail from public.content_reports where id = the_report)
     not like '%asked them to stop%' then
    raise exception 'resolving overwrote what the reporter wrote';
  end if;
  if (select detail from public.content_reports where id = the_report)
     not like '%dismissed%' then
    raise exception 'the decision was not recorded';
  end if;

  -- Only 'actioned' and 'dismissed' are answers.
  begin
    perform public.resolve_report(the_report, 'maybe', '');
    raise exception 'an invented status was accepted';
  exception when sqlstate '22023' then null;
  end;

  -- A dismissed report is not a strike. This is the check that stops
  -- somebody losing an account over a complaint nobody upheld.
  strikes := public.copyright_strikes(
    '11111111-1111-1111-1111-111111111111');
  if strikes <> 0 then
    raise exception 'a dismissed harassment report counted as a copyright strike (got %)',
      strikes;
  end if;

  -- An actioned copyright one is.
  insert into public.content_reports
    (reporter_id, kind, reason, detail, target_profile, status)
  values ('22222222-2222-2222-2222-222222222222', 'profile', 'copyright',
          'That is our record.', '11111111-1111-1111-1111-111111111111',
          'actioned');

  if public.copyright_strikes('11111111-1111-1111-1111-111111111111') <> 1 then
    raise exception 'an actioned copyright report did not count';
  end if;
end $$;


-- Account deletion (0065).
--
-- Last, because it removes an account and everything under it. The bug it
-- fixes: anybody who recorded a take on somebody else's song could not delete
-- their account at all — song_layers.recorded_by referenced profiles with NO
-- ACTION, so the final delete raised a foreign key violation and the person
-- got a Postgres error after tapping "Delete Permanently".
--
-- The bandmate is in exactly that position here: they answered an ask and
-- joined one of the writer's songs.
insert into public.song_layers
  (project_id, recorded_by, storage_path, label, part, duration_ms, shared_at)
values
  ('aaaaaaaa-0000-0000-0000-00000000000a',
   '22222222-2222-2222-2222-222222222222',
   'aaaaaaaa/layers/heard.m4a', 'Bass', 'bass', 30000, now()),
  ('aaaaaaaa-0000-0000-0000-00000000000a',
   '22222222-2222-2222-2222-222222222222',
   'aaaaaaaa/layers/never-heard.m4a', 'Scratch', 'bass', 12000, null);

-- 0093: the delivery, which is the only event here that is not somebody
-- talking about doing something. A shared take on a song that is not yours.
-- The unshared one beside it must produce nothing: a private take is
-- somebody working, and the whole app rests on those two being different.
do $$
begin
  if (select count(*) from private.collaboration_events
      where kind = 'delivered'
        and by_user = '22222222-2222-2222-2222-222222222222'
        and project_id = 'aaaaaaaa-0000-0000-0000-00000000000a') <> 1 then
    raise exception 'a shared take on somebody else''s song was not written '
      'down exactly once (got %)',
      (select count(*) from private.collaboration_events
       where kind = 'delivered'
         and by_user = '22222222-2222-2222-2222-222222222222'
         and project_id = 'aaaaaaaa-0000-0000-0000-00000000000a');
  end if;
end $$;

set local request.jwt.claims = '{"sub": "22222222-2222-2222-2222-222222222222"}';

do $$
begin
  -- The delete itself. Before 0065 this line raised
  -- foreign_key_violation and the whole feature was broken.
  perform public.delete_my_account();

  if exists (select 1 from auth.users
             where id = '22222222-2222-2222-2222-222222222222') then
    raise exception 'the account was not deleted';
  end if;

  -- The take the room heard is still in the song, because the band cannot
  -- re-record it — but nothing says who played it.
  if not exists (
    select 1 from public.song_layers
    where storage_path = 'aaaaaaaa/layers/heard.m4a'
  ) then
    raise exception 'a shared take was destroyed with its recorder';
  end if;
  if exists (
    select 1 from public.song_layers
    where storage_path = 'aaaaaaaa/layers/heard.m4a'
      and (recorded_by is not null or performer is not null)
  ) then
    raise exception 'a deleted account is still named on a take';
  end if;

  -- The one nobody ever heard is gone, because it was only ever theirs.
  if exists (
    select 1 from public.song_layers
    where storage_path = 'aaaaaaaa/layers/never-heard.m4a'
  ) then
    raise exception 'an unshared private take survived the account that made it';
  end if;

  -- And the matching ledger goes with them (0093). The take stays because
  -- the band cannot re-record it; the record of who somebody worked with is
  -- about the person, not the song, so leaving it behind would be keeping a
  -- social graph of an account that asked to be gone.
  if exists (
    select 1 from private.collaboration_events
    where by_user = '22222222-2222-2222-2222-222222222222'
       or with_user = '22222222-2222-2222-2222-222222222222'
  ) then
    raise exception 'a deleted account is still in the collaboration ledger';
  end if;
end $$;

set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';


-- A song on the Open Mic (0067).
--
-- **This block runs as `authenticated`, and it is the first one that does.**
--
-- Everything above runs as the superuser the migrations are replayed by,
-- which bypasses row level security entirely. That is fine for the rest of
-- this file — every other assertion is about a security-definer function's
-- own WHERE clause — but it means the policies in this repo have never once
-- been executed by the harness that exists to execute things. The first
-- version of this block asserted a stranger saw one take, was told they saw
-- three, and was right to complain: it was counting rows with RLS switched
-- off.
--
-- 0067 is three policies that have to agree, so it is worth the role switch.
insert into public.song_layers
  (project_id, recorded_by, storage_path, label, part, duration_ms, shared_at)
values
  ('aaaaaaaa-0000-0000-0000-00000000000a', :'writer',
   :'room' || '/aaaaaaaa-0000-0000-0000-00000000000a/layers/heard.m4a',
   'Guitar', 'rhythm', 40000, now()),
  ('aaaaaaaa-0000-0000-0000-00000000000a', :'writer',
   :'room' || '/aaaaaaaa-0000-0000-0000-00000000000a/layers/secret.m4a',
   'Scratch', 'rhythm', 9000, null);

select public.put_on_open_mic('aaaaaaaa-0000-0000-0000-00000000000a');

-- A stranger: joiner one is in another catalog entirely.
set local request.jwt.claims = '{"sub": "88888888-8888-8888-8888-888888888888", "email": "joiner.one@smoke.test"}';
set local role authenticated;

do $$
declare
  song record;
  unshared int;
begin
  select * into song
  from public.open_mic_song('aaaaaaaa-0000-0000-0000-00000000000a');
  if song.id is null then
    raise exception 'a song on the Open Mic was invisible to a stranger';
  end if;
  if song.owner_name is null then
    raise exception 'the Open Mic song did not say who made it';
  end if;

  -- The heart of it, and now actually enforced. A published song does not
  -- publish somebody's unheard draft.
  select count(*) into unshared from public.song_layers
  where project_id = 'aaaaaaaa-0000-0000-0000-00000000000a'
    and shared_at is null;

  if unshared <> 0 then
    raise exception 'a stranger could see % private take(s)', unshared;
  end if;

  if not exists (
    select 1 from public.song_layers
    where project_id = 'aaaaaaaa-0000-0000-0000-00000000000a'
      and shared_at is not null
  ) then
    raise exception 'a stranger could see none of the shared takes';
  end if;

  -- And it is not theirs to take down.
  --
  -- This is the assertion that found the null trap in 0068: room_role_for is
  -- null for a stranger, `null <> 'owner'` is null, and `if null then` does
  -- not fire — so every owner-only guard in the app was open to exactly the
  -- person it existed to stop. Nine of them, since migration 0001.
  begin
    perform public.take_off_open_mic('aaaaaaaa-0000-0000-0000-00000000000a');
    raise exception 'a stranger took somebody else''s song off the Open Mic';
  exception when insufficient_privilege then null;
  end;

  -- The same trap, on the two that could empty somebody's band.
  begin
    perform public.remove_room_member(
      '33333333-3333-3333-3333-333333333333',
      '11111111-1111-1111-1111-111111111111');
    raise exception 'a stranger removed a member from somebody else''s catalog';
  exception when insufficient_privilege then null;
  end;

  begin
    perform public.invite_musician_to_room(
      '33333333-3333-3333-3333-333333333333',
      '99999999-9999-9999-9999-999999999999', '');
    raise exception 'a stranger invited somebody to a catalog they are not in';
  exception when insufficient_privilege then null;
  end;
end $$;

reset role;
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';
select public.take_off_open_mic('aaaaaaaa-0000-0000-0000-00000000000a');

set local request.jwt.claims = '{"sub": "88888888-8888-8888-8888-888888888888", "email": "joiner.one@smoke.test"}';
set local role authenticated;

do $$
begin
  if exists (
    select 1 from public.open_mic_song('aaaaaaaa-0000-0000-0000-00000000000a')
  ) then
    raise exception 'taking a song off the Open Mic did not hide it again';
  end if;
  -- The takes go with it, or the audio outlives the page.
  if exists (
    select 1 from public.song_layers
    where project_id = 'aaaaaaaa-0000-0000-0000-00000000000a'
  ) then
    raise exception 'a stranger could still see takes after the song came down';
  end if;
end $$;

reset role;
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';

-- Songs you can hear on a profile (0069).
--
-- The rule worth proving is "owned or played on". An owner-only definition
-- would leave a session player's profile permanently empty while they played
-- on twenty records — and they are exactly who Open Mic is for.
select public.put_on_open_mic('aaaaaaaa-0000-0000-0000-00000000000a');

set local role authenticated;

do $$
declare
  mine record;
begin
  select * into mine
  from public.songs_by('11111111-1111-1111-1111-111111111111');

  if mine.id is null then
    raise exception 'the owner of a song on the Open Mic had nothing on their profile';
  end if;

  -- Theirs, so no part is named. Naming one would be odd; claiming somebody
  -- else's song by not naming one would be worse, which is the next check.
  if array_length(mine.their_parts, 1) is not null
     and mine.owner_id = '11111111-1111-1111-1111-111111111111'
     and mine.their_parts <> array['rhythm'] then
    raise exception 'their own song reported the wrong parts: %', mine.their_parts;
  end if;
end $$;

reset role;

-- A song of somebody else's that this person played on, and had heard.
--
-- Built from scratch rather than reusing The Other Band: that room's owner
-- had their account deleted a few blocks up, which is the sort of thing a
-- scenario this long stops being able to hold in its head.
insert into public.rooms (id, account_id, name)
values ('cccccccc-cccc-cccc-cccc-cccccccccccc',
        '88888888-8888-8888-8888-888888888888', 'Somebody Else''s Band')
on conflict (id) do nothing;

insert into public.room_members (room_id, user_id, display_name, role) values
  ('cccccccc-cccc-cccc-cccc-cccccccccccc',
   '88888888-8888-8888-8888-888888888888', 'Joiner One', 'owner'),
  ('cccccccc-cccc-cccc-cccc-cccccccccccc', :'writer', 'The Writer', 'editor')
on conflict (room_id, user_id) do nothing;

insert into public.projects (id, room_id, account_id, title, created_by)
values ('bbbbbbbb-0000-0000-0000-00000000000b',
        'cccccccc-cccc-cccc-cccc-cccccccccccc',
        '88888888-8888-8888-8888-888888888888',
        'Somebody Else''s Song', '88888888-8888-8888-8888-888888888888')
on conflict (id) do nothing;

insert into public.song_layers
  (project_id, recorded_by, storage_path, label, part, duration_ms, shared_at)
values ('bbbbbbbb-0000-0000-0000-00000000000b', :'writer',
        'cccccccc-cccc-cccc-cccc-cccccccccccc/bbbbbbbb-0000-0000-0000-00000000000b/layers/bass.m4a',
        'Bass', 'bass', 30000, now());

update public.projects set open_mic_at = now()
where id = 'bbbbbbbb-0000-0000-0000-00000000000b';

set local role authenticated;

do $$
declare
  found int;
  played record;
begin
  select count(*) into found
  from public.songs_by('11111111-1111-1111-1111-111111111111');
  if found < 2 then
    raise exception 'a song they played on did not appear on their profile (got %)', found;
  end if;

  select * into played
  from public.songs_by('11111111-1111-1111-1111-111111111111')
  where id = 'bbbbbbbb-0000-0000-0000-00000000000b';

  -- Which part, or the profile is claiming the song rather than the work.
  if played.their_parts <> array['bass'] then
    raise exception 'their part on somebody else''s song was % rather than bass',
      played.their_parts;
  end if;
  if played.owner_id = '11111111-1111-1111-1111-111111111111' then
    raise exception 'somebody else''s song was attributed to the wrong owner';
  end if;
end $$;

reset role;


-- A page of the feed (0071).
--
-- The rule worth proving is the inclusive one: a song carried by a phone take
-- alone still reaches the feed. Requiring a reference recording would quietly
-- exclude somebody who opened the app, sang into it, and shared that — which
-- is the person this whole surface is supposed to be for.
insert into public.projects (id, room_id, account_id, title, created_by)
values ('dddddddd-0000-0000-0000-00000000000d', :'room', :'writer',
        'Sung Into A Phone', :'writer')
on conflict (id) do nothing;

insert into public.song_layers
  (project_id, recorded_by, storage_path, label, part, duration_ms, shared_at)
values
  ('dddddddd-0000-0000-0000-00000000000d', :'writer',
   :'room' || '/dddddddd-0000-0000-0000-00000000000d/layers/phone.m4a',
   'Voice', 'vocal', 21000, now()),
  ('dddddddd-0000-0000-0000-00000000000d', :'writer',
   :'room' || '/dddddddd-0000-0000-0000-00000000000d/layers/private.m4a',
   'Scratch', 'vocal', 8000, null);

select public.put_on_open_mic('dddddddd-0000-0000-0000-00000000000d');

-- Read as somebody else, because that is who a feed is for.
--
-- It used to be read as the writer who owns the song, which passed only
-- while the feed still returned your own work back to you. 0074 stopped
-- doing that — your own songs are not somebody to meet, you know how they
-- sound — so the assertion has to stand where a stranger stands.
set local request.jwt.claims = '{"sub": "88888888-8888-8888-8888-888888888888", "email": "joiner.one@smoke.test"}';

do $$
declare
  track record;
begin
  select * into track from public.open_mic_feed(20, null::text)
  where id = 'dddddddd-0000-0000-0000-00000000000d';

  if track.id is null then
    raise exception 'a song with only a shared take never reached the feed';
  end if;
  if track.storage_path not like '%phone.m4a' then
    raise exception 'the feed picked % rather than the shared take',
      track.storage_path;
  end if;
  -- Never the private one, whatever else changes.
  if track.storage_path like '%private.m4a' then
    raise exception 'the feed was about to play an unshared take';
  end if;
  if track.duration_ms <> 21000 then
    raise exception 'the feed carried the wrong length: %', track.duration_ms;
  end if;

  -- Every row has something to play, or the feed has silent cards in it.
  if exists (
    select 1 from public.open_mic_feed(40, null::text)
    where storage_path is null
  ) then
    raise exception 'the feed returned a row with nothing to play';
  end if;
end $$;

-- The three lists can play too (0073).
--
-- Each of these returned a title, an owner and what a song wants, and never
-- where the audio lives — so no client could have played them. The rule for
-- which recording is private.song_audio's, and these prove all three ask it.
do $$
declare
  listed record;
begin
  select * into listed
  from public.open_mic_songs(null::text, 40, true)
  where id = 'dddddddd-0000-0000-0000-00000000000d';
  if listed.storage_path not like '%phone.m4a' then
    raise exception 'the Open Mic list could not play the song: %',
      coalesce(listed.storage_path, '<null>');
  end if;

  select * into listed
  from public.open_mic_song('dddddddd-0000-0000-0000-00000000000d');
  if listed.storage_path not like '%phone.m4a' then
    raise exception 'the public song page could not play the song: %',
      coalesce(listed.storage_path, '<null>');
  end if;

  select * into listed
  from public.songs_by('11111111-1111-1111-1111-111111111111')
  where id = 'dddddddd-0000-0000-0000-00000000000d';
  if listed.storage_path not like '%phone.m4a' then
    raise exception 'the profile could not play the song: %',
      coalesce(listed.storage_path, '<null>');
  end if;

  -- And none of them hand out the take nobody has shared.
  if exists (
    select 1 from public.open_mic_songs(null::text, 40, true)
    where storage_path like '%private.m4a'
  ) then
    raise exception 'a list offered an unshared take';
  end if;
end $$;

-- Your own songs are not somebody to meet (0074).
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';

do $$
begin
  if exists (
    select 1 from public.open_mic_feed(40, null::text)
    where id = 'dddddddd-0000-0000-0000-00000000000d'
  ) then
    raise exception 'the feed offered somebody their own song';
  end if;
end $$;

-- Who can hear this (0075).
--
-- The dial has one way to fail that matters: under-reporting. Telling
-- somebody their song is private while strangers are listening to it is
-- worse than having no indicator at all, which is what the app had.
do $$
declare
  heard record;
begin
  select * into heard
  from public.song_audience('dddddddd-0000-0000-0000-00000000000d');

  -- It is on the Open Mic at this point in the file, so nothing narrower
  -- may be reported, whatever the room memberships happen to say.
  if heard.reach <> 'anyone' then
    raise exception 'a song on the Open Mic reported reach %', heard.reach;
  end if;
  if not heard.on_open_mic then
    raise exception 'a song on the Open Mic said it was not';
  end if;

  -- Named, not counted: "who" is the question people actually ask.
  if jsonb_typeof(heard.listeners) <> 'array' then
    raise exception 'listeners came back as % rather than an array',
      jsonb_typeof(heard.listeners);
  end if;
end $$;

select public.take_off_open_mic('dddddddd-0000-0000-0000-00000000000d');


-- And taking it down narrows the answer again, rather than leaving a song
-- that says "anyone" because it once did.
do $$
declare
  heard record;
begin
  select * into heard
  from public.song_audience('dddddddd-0000-0000-0000-00000000000d');
  if heard.reach = 'anyone' or heard.on_open_mic then
    raise exception 'a song taken off the Open Mic still reported %',
      heard.reach;
  end if;
end $$;

-- Somebody outside the room is told nothing at all. The membership of a
-- room you are not in is not yours to enumerate, so this returns no row
-- rather than a row with an empty list.
set local request.jwt.claims = '{"sub": "99999999-9999-9999-9999-999999999999", "email": "joiner.two@smoke.test"}';
set local role authenticated;

do $$
begin
  if exists (
    select 1 from public.song_audience('dddddddd-0000-0000-0000-00000000000d')
  ) then
    raise exception 'a stranger could read who can hear somebody else''s song';
  end if;
end $$;

reset role;
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';

-- What you sound like (0076).
--
-- The property that has to hold: taste orders a list sideways and never up.
-- Somebody who has recorded nothing but makes the same music as you must
-- come before a session player who makes something else, and neither
-- position may be earned by output.
select public.set_open_mic_presence(
  true, null, null, null, array['Folk', 'folk', '  Americana  ']
);

do $$
declare
  mine text[];
begin
  select sounds_like into mine from public.profiles
  where id = '11111111-1111-1111-1111-111111111111';

  -- Lower-cased, trimmed and deduplicated, or a tag picked from the list and
  -- the same word typed by hand would never match each other.
  if mine <> array['folk', 'americana'] then
    raise exception 'sounds_like was tidied to % rather than folk/americana',
      mine;
  end if;
end $$;

-- Five, and no more. A profile listing everything has said nothing.
select public.set_open_mic_presence(
  true, null, null, null,
  array['a', 'b', 'c', 'd', 'e', 'f', 'g']
);

do $$
declare
  n int;
begin
  select coalesce(array_length(sounds_like, 1), 0) into n
  from public.profiles where id = '11111111-1111-1111-1111-111111111111';
  if n <> 5 then
    raise exception 'sounds_like kept % tags rather than five', n;
  end if;
end $$;

-- One word for one sound (0135). The tour offered "hip-hop" and settings
-- "hip hop"; spellings of one sound are one tag, and count once.
select public.set_open_mic_presence(
  true, null, null, null, array['Hip Hop', 'hip-hop', 'LoFi', 'R & B', 'drum and  bass']
);

do $$
declare
  mine text[];
begin
  select sounds_like into mine from public.profiles
  where id = '11111111-1111-1111-1111-111111111111';
  if mine <> array['hip-hop', 'lo-fi', 'r&b', 'drum and bass'] then
    raise exception 'sounds_like folded to % rather than hip-hop/lo-fi/r&b/drum and bass', mine;
  end if;
end $$;

-- Put it back to something the rest of the file can read.
select public.set_open_mic_presence(
  true, null, null, null, array['folk', 'americana']
);

-- A takedown that removes (0077).
--
-- The property that has to hold: after a takedown, the image is gone from
-- the column the app reads AND unreachable through storage. Either one
-- alone is a takedown that did not take anything down.
--
-- Run without `set local role authenticated`, deliberately. The setup writes
-- a storage.objects row, which nobody holding a phone may do, and
-- take_down_image is service-key by design — the same as resolve_report.
-- What is being proved here is the function's behaviour, and the claims are
-- what report_content actually reads.
do $$
declare
  filed uuid;
  result record;
  still_there text;
begin
  -- Give the writer a picture to remove, and an object behind it.
  update public.profiles
  set avatar_path = '11111111-1111-1111-1111-111111111111/avatar-smoke.png'
  where id = '11111111-1111-1111-1111-111111111111';

  insert into storage.objects (bucket_id, name, owner)
  values ('avatars',
          '11111111-1111-1111-1111-111111111111/avatar-smoke.png',
          '11111111-1111-1111-1111-111111111111')
  on conflict do nothing;

  -- Somebody else files it.
  perform set_config(
    'request.jwt.claims',
    '{"sub": "88888888-8888-8888-8888-888888888888"}', true);
  select public.report_content(
    'profile', 'sexual', 'Not a face.',
    '11111111-1111-1111-1111-111111111111'
  ) into filed;

  perform set_config(
    'request.jwt.claims',
    '{"sub": "11111111-1111-1111-1111-111111111111"}', true);

  select * into result from public.take_down_image(filed, 'Smoke test.');

  -- The path and the bucket, because SQL may not delete the object and the
  -- caller has to. A takedown that did not say where the bytes are is one
  -- that cannot be finished.
  if result.cleared_path <> '11111111-1111-1111-1111-111111111111/avatar-smoke.png' then
    raise exception 'the takedown reported the wrong path: %',
      result.cleared_path;
  end if;
  if result.bucket <> 'avatars' then
    raise exception 'the takedown reported the wrong bucket: %', result.bucket;
  end if;

  -- Gone from the profile.
  select avatar_path into still_there from public.profiles
  where id = '11111111-1111-1111-1111-111111111111';
  if still_there is not null then
    raise exception 'the picture is still on the profile: %', still_there;
  end if;

  -- The object itself is deliberately still here: storage refuses a delete
  -- from SQL, so removing it is tools/take_down.py's job through the API.
  -- What must be true is that nothing points at it any more.

  -- The queue must not still say open, or nobody knows it was handled.
  if (select status from public.content_reports where id = filed) <> 'actioned' then
    raise exception 'the report was left open after a takedown';
  end if;
end $$;

-- Both new kinds are accepted, or the two images nobody could report still
-- cannot be reported.
do $$
begin
  perform public.report_content(
    'room_logo', 'abuse', 'test', null, null, null, null,
    (select id from public.rooms limit 1)
  );
  perform public.report_content(
    'song_cover', 'abuse', 'test', null,
    'dddddddd-0000-0000-0000-00000000000d'
  );
end $$;

-- And a takedown refuses a kind it cannot act on, rather than silently
-- closing the report having changed nothing.
do $$
declare
  filed uuid;
begin
  select public.report_content(
    'message', 'spam', 'test', '11111111-1111-1111-1111-111111111111'
  ) into filed;
  begin
    perform public.take_down_image(filed);
    raise exception 'take_down_image accepted a kind it cannot remove';
  exception when sqlstate '22023' then
    null;  -- expected
  end;
end $$;

-- A crowd to test with, and getting rid of it again (0078).
--
-- The purge is the half that matters. Seed data that cannot be fully removed
-- stops being seed data and becomes the data — in every count, every
-- screenshot, and every judgement about how the app is doing. So this seeds
-- a small crowd, then asserts that nothing of it survives: not the songs,
-- not the takes, not the storage rows, and not the accounts.
insert into auth.users (id, email, raw_user_meta_data) values
  ('dede0001-0000-0000-0000-000000000001', 'demo.one@smoke.test',
   '{"display_name": "Demo One"}'),
  ('dede0002-0000-0000-0000-000000000002', 'demo.two@smoke.test',
   '{"display_name": "Demo Two"}');

update public.profiles set is_demo = true, discoverable = true
where id in ('dede0001-0000-0000-0000-000000000001',
             'dede0002-0000-0000-0000-000000000002');

insert into public.rooms (id, account_id, name, icon) values
  ('dede0011-0000-0000-0000-000000000011',
   'dede0001-0000-0000-0000-000000000001', 'Demo One Room', '🎸');

insert into public.room_members (room_id, user_id, display_name, role) values
  ('dede0011-0000-0000-0000-000000000011',
   'dede0001-0000-0000-0000-000000000001', 'Demo One', 'owner');

insert into public.projects (id, room_id, account_id, created_by, title) values
  ('dede0021-0000-0000-0000-000000000021',
   'dede0011-0000-0000-0000-000000000011',
   'dede0001-0000-0000-0000-000000000001',
   'dede0001-0000-0000-0000-000000000001', 'A Seeded Song');

insert into public.song_layers
  (project_id, recorded_by, storage_path, label, part, duration_ms, shared_at)
values
  ('dede0021-0000-0000-0000-000000000021',
   'dede0001-0000-0000-0000-000000000001',
   'dede0011-0000-0000-0000-000000000011/dede0021-0000-0000-0000-000000000021/layers/seed.m4a',
   'Take 1', 'vocal', 12000, now());

insert into storage.objects (bucket_id, name, owner) values
  ('room-files',
   'dede0011-0000-0000-0000-000000000011/dede0021-0000-0000-0000-000000000021/layers/seed.m4a',
   'dede0001-0000-0000-0000-000000000001')
on conflict do nothing;

-- A real account's work sitting alongside it, which the purge must not touch.
do $$
declare
  real_songs bigint;
  after_songs bigint;
begin
  select count(*) into real_songs from public.projects p
  where p.room_id <> 'dede0011-0000-0000-0000-000000000011';

  -- Read the paths first, exactly as the tool must: after the purge the
  -- rooms are gone and nothing names the objects any more.
  if not exists (
    select 1 from public.purge_demo_paths()
    where prefix = 'dede0011-0000-0000-0000-000000000011/'
  ) then
    raise exception 'purge_demo_paths did not name the seeded room';
  end if;

  perform public.purge_demo();

  if exists (select 1 from public.profiles where is_demo) then
    raise exception 'a seeded profile survived the purge';
  end if;
  if exists (
    select 1 from auth.users
    where id in ('dede0001-0000-0000-0000-000000000001',
                 'dede0002-0000-0000-0000-000000000002')
  ) then
    raise exception 'a seeded account survived the purge';
  end if;
  if exists (
    select 1 from public.projects
    where id = 'dede0021-0000-0000-0000-000000000021'
  ) then
    raise exception 'a seeded song survived the purge';
  end if;
  if exists (
    select 1 from public.song_layers
    where project_id = 'dede0021-0000-0000-0000-000000000021'
  ) then
    raise exception 'a seeded take survived the purge';
  end if;
  -- And nothing is left naming the files, which is the reason the tool has
  -- to sweep them *before* calling this rather than after.
  if exists (
    select 1 from public.purge_demo_paths()
    where prefix = 'dede0011-0000-0000-0000-000000000011/'
  ) then
    raise exception 'the seeded room survived the purge';
  end if;

  -- And nothing real went with it.
  select count(*) into after_songs from public.projects p
  where p.room_id <> 'dede0011-0000-0000-0000-000000000011';
  if after_songs <> real_songs then
    raise exception 'the purge took % real songs with it',
      real_songs - after_songs;
  end if;
end $$;

-- Safe to run when there is nothing to remove, or nobody will run it twice.
do $$
declare
  said record;
begin
  select * into said from public.purge_demo() limit 1;
  if said.what <> 'nothing was seeded' then
    raise exception 'a second purge reported % rather than saying it was empty',
      said.what;
  end if;
end $$;

-- The record button leaves litter (0081).
--
-- UUIDs spelled out rather than :'room' and :'writer': psql variables are
-- substituted by psql, and the inside of a `do $$ … $$` block is a string
-- literal it never looks into.
--
-- The dangerous half of this is not that it fails to delete. It is that it
-- deletes somebody's work, so the assertions that matter are the ones about
-- what it must refuse.
set local role authenticated;

do $$
declare
  empty_one uuid := 'ecec0001-0000-0000-0000-000000000001';
  written uuid := 'ecec0002-0000-0000-0000-000000000002';
begin
  insert into public.projects (id, room_id, account_id, created_by, title)
  values
    (empty_one, '33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111', 'Bumped The Button'),
    (written, '33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111', 'Has Words In It');

  insert into public.contributions (project_id, author_id, body)
  values (written, '11111111-1111-1111-1111-111111111111', 'the first line of something');

  -- Nothing in it: gone.
  if not public.discard_if_untouched(empty_one) then
    raise exception 'an empty song was not discarded';
  end if;
  if exists (select 1 from public.projects where id = empty_one) then
    raise exception 'discard said yes and the song is still there';
  end if;

  -- One line typed: kept. This is the assertion that stops this function
  -- ever eating somebody's song.
  if public.discard_if_untouched(written) then
    raise exception 'a song with words in it was discarded';
  end if;
  if not exists (select 1 from public.projects where id = written) then
    raise exception 'a song with words in it is gone';
  end if;
end $$;

-- A song with a take in it is kept, even with no words.
do $$
declare
  recorded uuid := 'ecec0003-0000-0000-0000-000000000003';
begin
  insert into public.projects (id, room_id, account_id, created_by, title)
  values (recorded, '33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111', 'Only A Take');

  insert into public.song_layers
    (project_id, recorded_by, storage_path, label, part, duration_ms)
  values
    (recorded, '11111111-1111-1111-1111-111111111111',
     '33333333-3333-3333-3333-333333333333' || '/' || recorded::text || '/layers/x.m4a',
     'Take 1', 'vocal', 9000);

  if public.discard_if_untouched(recorded) then
    raise exception 'a song with a take in it was discarded';
  end if;
end $$;

-- And somebody else's empty song is not theirs to discard.
set local request.jwt.claims = '{"sub": "88888888-8888-8888-8888-888888888888", "email": "joiner.one@smoke.test"}';

do $$
declare
  mine uuid := 'ecec0004-0000-0000-0000-000000000004';
begin
  if public.discard_if_untouched('ecec0003-0000-0000-0000-000000000003') then
    raise exception 'somebody discarded a song that was not theirs';
  end if;
end $$;

reset role;
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';

-- The app noticed (0082).
--
-- The point is that it only offers what it can count. A part somebody has
-- actually recorded is a fact; anything about their taste or ability would be
-- a guess, and there is nothing here that supports guessing either.
--
-- Sets up its own evidence rather than leaning on an earlier fixture. The
-- first version assumed the writer had recorded bass and not claimed it —
-- they had claimed it two hundred lines earlier, so the suggestion was
-- correctly absent and the test was wrong about the app rather than the other
-- way round.
insert into public.song_layers
  (project_id, recorded_by, storage_path, label, part, duration_ms, shared_at)
values
  ('aaaaaaaa-0000-0000-0000-00000000000a',
   '11111111-1111-1111-1111-111111111111',
   'aaaaaaaa/layers/noticed-drums.m4a', 'Drums', 'drums', 20000, now());

set local role authenticated;

do $$
declare
  found record;
  -- Read into a variable rather than compared with `= any((select ...))`.
  -- That form is the *subquery* ANY, which compares a text to a whole row
  -- and fails with "malformed array literal" — the same trap 0074 hit.
  claimed text[];
begin
  -- Recorded, never claimed: offered.
  select * into found from public.things_we_noticed()
  where kind = 'plays' and subject = 'drums';
  if found.kind is null then
    raise exception 'a recorded part was not noticed';
  end if;
  if found.amount < 1 then
    raise exception 'the count came back as %', found.amount;
  end if;

  -- Already claimed: never offered. The writer has bass in `plays` from
  -- earlier in this file and has recorded it.
  if exists (
    select 1 from public.things_we_noticed()
    where kind = 'plays' and subject = 'bass'
  ) then
    raise exception 'a part already on the profile was offered again';
  end if;

  -- One tap writes it down.
  perform public.claim_part('drums');
  select plays into claimed from public.profiles
  where id = '11111111-1111-1111-1111-111111111111';
  if not ('drums' = any(claimed)) then
    raise exception 'claim_part did not add the part';
  end if;

  -- And it stops being offered, or the card never empties.
  if exists (
    select 1 from public.things_we_noticed()
    where kind = 'plays' and subject = 'drums'
  ) then
    raise exception 'a claimed part is still being offered';
  end if;

  -- Twice is not two entries.
  perform public.claim_part('drums');
  select plays into claimed from public.profiles
  where id = '11111111-1111-1111-1111-111111111111';
  if (select count(*) from unnest(claimed) t where t = 'drums') <> 1 then
    raise exception 'claiming twice added the part twice';
  end if;
end $$;

reset role;

-- What you get (0087).
--
-- The property that matters: the client and the server must agree about what
-- an account may do, because a paywall the client believes in and the server
-- does not is not a paywall.
set local role authenticated;

do $$
declare
  mine record;
begin
  select * into mine from public.my_plan();

  if mine.plan is null then
    raise exception 'my_plan said nothing about this account';
  end if;

  -- Everybody starts free. A default of anything else would quietly hand
  -- out the expensive pipeline.
  if mine.plan <> 'free' then
    raise exception 'a new account was on the % plan', mine.plan;
  end if;
  if mine.can_separate then
    raise exception 'a free account was allowed the separated pipeline';
  end if;
  if mine.sheets_allowed is null then
    raise exception 'a free account had no ceiling at all';
  end if;
end $$;

reset role;

-- A member has no ceiling and gets the expensive one.
update public.profiles set plan = 'member'
where id = '11111111-1111-1111-1111-111111111111';

set local role authenticated;

do $$
declare
  mine record;
begin
  select * into mine from public.my_plan();
  if not mine.can_separate then
    raise exception 'a member was refused the separated pipeline';
  end if;
  if mine.sheets_allowed is not null then
    raise exception 'a member had a ceiling of %', mine.sheets_allowed;
  end if;
end $$;

reset role;

-- account_limits still wins, which is what that table has always been for:
-- one account that needs something other than the default.
insert into public.account_limits (account_id, monthly_analyses, note)
values ('11111111-1111-1111-1111-111111111111', 3, 'smoke test')
on conflict (account_id) do update set monthly_analyses = 3;

set local role authenticated;

do $$
declare
  mine record;
begin
  select * into mine from public.my_plan();
  if mine.sheets_allowed <> 3 then
    raise exception 'account_limits did not override the plan (got %)',
      mine.sheets_allowed;
  end if;
end $$;

reset role;

delete from public.account_limits
where account_id = '11111111-1111-1111-1111-111111111111';
update public.profiles set plan = 'free'
where id = '11111111-1111-1111-1111-111111111111';

-- An answer you can read (0090, 0091).
--
-- 0080 gave people somewhere to ask and gave nobody a way to answer them.
-- The question went into a table and the only reply route was already
-- knowing their email.
set local role authenticated;

do $$
declare
  filed uuid;
begin
  select public.ask_for_help(
    'how do I put a beat on somebody else''s song', null, 'Open Mic'
  ) into filed;

  if filed is null then
    raise exception 'the question was not recorded';
  end if;

  -- Yours, and only yours. A help question routinely contains something
  -- somebody would not say twice.
  if not exists (
    select 1 from public.my_help_requests() where id = filed
  ) then
    raise exception 'somebody cannot read their own question';
  end if;
end $$;

reset role;

-- Answering reaches them.
do $$
declare
  filed uuid;
  told bigint;
begin
  select id into filed from public.help_requests
  where asked_by = '11111111-1111-1111-1111-111111111111'
  order by created_at desc limit 1;

  perform public.answer_help(filed, 'Ask them for a beat from their profile.');

  if (select status from public.help_requests where id = filed) <> 'answered'
  then
    raise exception 'the question was not marked answered';
  end if;

  -- The half that was missing. An answer nobody is told about is a note in
  -- a table.
  select count(*) into told from public.notifications
  where user_id = '11111111-1111-1111-1111-111111111111'
    and type = 'help_answered';
  if told < 1 then
    raise exception 'the person who asked was never told';
  end if;
end $$;

set local role authenticated;

do $$
declare
  mine record;
begin
  select * into mine from public.my_help_requests() limit 1;
  if mine.notes not like '%Ask them for a beat%' then
    raise exception 'the answer is not readable by the person who asked';
  end if;
end $$;

reset role;

-- The dial knows about the showcase (0089).
--
-- The control whose entire job is answering "who can hear this" gave the
-- wrong answer for the newest way to be heard. A song on the showcase
-- reported whatever its room membership said — "Only you" for a solo writer
-- who had just published finished work to everybody.
--
-- Understating reach is the one direction this must never err in.
do $$
declare
  heard record;
begin
  perform public.show_song('aaaaaaaa-0000-0000-0000-00000000000a');

  select * into heard
  from public.song_audience('aaaaaaaa-0000-0000-0000-00000000000a');

  if heard.reach <> 'anyone' then
    raise exception 'a song on the showcase reported reach %', heard.reach;
  end if;
  if not heard.on_showcase then
    raise exception 'a song on the showcase said it was not';
  end if;

  -- And off again, because a one-way door is a door nobody walks through.
  perform public.unshow_song('aaaaaaaa-0000-0000-0000-00000000000a');
  select * into heard
  from public.song_audience('aaaaaaaa-0000-0000-0000-00000000000a');
  if heard.on_showcase then
    raise exception 'a song taken off the showcase still said it was on it';
  end if;

  -- Unpublishing is not un-finishing. Somebody who wanted it out of public
  -- view must not also lose the record that they finished it.
  if (select finished_at from public.projects
      where id = 'aaaaaaaa-0000-0000-0000-00000000000a') is null then
    raise exception 'taking it off the showcase un-finished it';
  end if;
end $$;

-- Who has been listening (0086).
--
-- The property that matters is what this refuses to record. A song's owner
-- gets a number and can never be given an identity, and the shape of the
-- table is what guarantees it rather than a promise in a policy.
--
-- Uses aaaaaaaa, which is on the Open Mic at this point, and dddddddd,
-- which was taken off five hundred lines earlier — so the negative case
-- is a real song that is genuinely not up rather than an id that does not
-- exist and would pass without testing anything.
set local request.jwt.claims = '{"sub": "99999999-9999-9999-9999-999999999999"}';

do $$
declare
  heard bigint;
begin
  -- Somebody else's song, on the Open Mic.
  perform public.record_play('aaaaaaaa-0000-0000-0000-00000000000a');
  perform public.record_play('aaaaaaaa-0000-0000-0000-00000000000a');
  perform public.record_play('aaaaaaaa-0000-0000-0000-00000000000a');

  -- Three plays, one person, one day: one row. Counting plays would make
  -- the number flattering and useless.
  select count(*) into heard from public.song_plays
  where project_id = 'aaaaaaaa-0000-0000-0000-00000000000a';
  if heard <> 1 then
    raise exception 'three plays by one person counted as %', heard;
  end if;
end $$;

-- Your own song is not an audience.
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';

do $$
declare
  heard bigint;
begin
  perform public.record_play('aaaaaaaa-0000-0000-0000-00000000000a');
  select count(*) into heard from public.song_plays
  where project_id = 'aaaaaaaa-0000-0000-0000-00000000000a';
  if heard <> 1 then
    raise exception 'an owner listening to their own song was counted';
  end if;
end $$;

-- And the owner is told the number.
do $$
declare
  mine record;
begin
  select * into mine from public.my_open_mic()
  where id = 'aaaaaaaa-0000-0000-0000-00000000000a';

  if mine.id is null then
    raise exception 'my_open_mic did not return a song that is up';
  end if;
  if mine.listeners <> 1 then
    raise exception 'the owner was told % listeners rather than one',
      mine.listeners;
  end if;
end $$;

-- Nothing accumulates against a song that is not up.
do $$
declare
  before_count bigint;
  after_count bigint;
begin
  select count(*) into before_count from public.song_plays;
  perform public.record_play('dddddddd-0000-0000-0000-00000000000d');
  select count(*) into after_count from public.song_plays;
  if after_count <> before_count then
    raise exception 'a song that is not on the Open Mic was counted';
  end if;
end $$;

-- Hear them, and start something (0085).
--
-- Two properties. A card must be able to play something of theirs, and
-- starting something must invite rather than add — every other door in this
-- app waits for a yes and this one is not an exception.
--
-- Joiner Two, not the bandmate: this file deletes the bandmate's account
-- eight hundred lines earlier to prove account deletion works, and a test
-- that starts something with a deleted person tests the error path.
do $$
declare
  -- Plain variables rather than a record. `made.room_id` beside an
  -- unqualified `room_id` column makes plpgsql call the reference ambiguous,
  -- and every table here has a column by that name.
  new_room uuid;
  new_project uuid;
  members bigint;
  invited bigint;
  songs bigint;
begin
  select s.made_room, s.made_song into new_room, new_project
  from public.start_something_with('99999999-9999-9999-9999-999999999999') s;

  if new_room is null or new_project is null then
    raise exception 'start_something_with returned nothing to open';
  end if;

  -- A song to land in, or the room is an empty container somebody has to
  -- fill before anything can happen.
  select count(*) into songs from public.projects p
  where p.room_id = new_room;
  if songs <> 1 then
    raise exception 'the new room has % songs rather than one', songs;
  end if;

  -- Only you in it. They are invited, not added.
  select count(*) into members from public.room_members m
  where m.room_id = new_room;
  if members <> 1 then
    raise exception 'somebody was put in a room without agreeing (% members)',
      members;
  end if;

  select count(*) into invited from public.room_invites i
  where i.room_id = new_room
    and i.invited_profile = '99999999-9999-9999-9999-999999999999'
    -- 'open', not 'pending': room_invites has used that word since 0062.
    and i.status = 'open';
  if invited <> 1 then
    raise exception 'no invitation was sent';
  end if;
end $$;

-- Twice with the same person is the good case, not a constraint error.
do $$
declare
  again uuid;
begin
  select s.made_room into again
  from public.start_something_with('99999999-9999-9999-9999-999999999999') s;
  if again is null then
    raise exception 'starting something twice failed on the name';
  end if;
end $$;

-- And never with yourself.
do $$
begin
  begin
    perform public.start_something_with(
      '11111111-1111-1111-1111-111111111111');
    raise exception 'started something with myself';
  exception when sqlstate '22023' then
    null;  -- expected
  end;
end $$;

-- Old apps still ask for one part (0084).
--
-- 0083 dropped the single-part signature in the same migration that added
-- the list one, and a phone running a build from an hour earlier lost the
-- whole People half of the Open Mic. A migration cannot assume the app
-- matching it is installed: the two ship by completely separate paths.
do $$
declare
  n bigint;
begin
  -- The shape an older build sends.
  select count(*) into n from public.find_musicians('bass', null, 50);
  if n = 0 then
    raise exception 'the single-part form returned nobody';
  end if;

  -- And it agrees with the list form, or the shim is its own bug.
  if n <> (select count(*) from public.find_musicians(array['bass'], null, 50))
  then
    raise exception 'the single-part shim disagrees with the list version';
  end if;
end $$;

-- More than one thing (0083).
--
-- The rule that matters: asking for three things must not empty the room.
-- Requiring all of them is what an obvious implementation does and it is
-- wrong at this size — nobody has recorded singing and guitar and lyrics, so
-- three ticked boxes would return nothing and read as a broken app.
set local role authenticated;

do $$
declare
  everyone bigint;
  asked bigint;
  top record;
begin
  select count(*) into everyone
  from public.find_musicians(null::text[], null, 100);

  -- Three things nobody does all of.
  select count(*) into asked
  from public.find_musicians(array['vocal', 'lead', 'percussion'], null, 100);

  if asked = 0 then
    raise exception 'asking for three things emptied the room';
  end if;

  -- And the person doing most of them is first, which is the whole reason
  -- to rank rather than narrow.
  select * into top
  from public.find_musicians(array['vocal', 'lead', 'percussion'], null, 100)
  limit 1;

  if coalesce(array_length(top.matched_parts, 1), 0) = 0 then
    raise exception 'the first result matched none of what was asked for';
  end if;

  -- Nobody who does none of it is included, or the filter means nothing.
  if exists (
    select 1
    from public.find_musicians(array['vocal', 'lead', 'percussion'], null, 100)
    where coalesce(array_length(matched_parts, 1), 0) = 0
  ) then
    raise exception 'somebody who does none of it was returned';
  end if;

  -- Asking for nothing still returns everybody.
  if asked > everyone then
    raise exception 'asking narrowed to more people than exist';
  end if;
end $$;

reset role;

-- Nobody is ranked (0072).
--
-- The check is that somebody who has recorded nothing still turns up. Before
-- this, the sort put every beginner last — every search, every time, until
-- they built a record they could not build without first being found.
-- Through auth.users, because on_auth_user_created is what makes a profile —
-- inserting one directly is not a thing the app can do and not a thing this
-- file should pretend to.
insert into auth.users (id, email, raw_user_meta_data)
values ('eeeeeeee-0000-0000-0000-00000000000e', 'newcomer@smoke.test',
        '{"display_name": "Never Recorded Anything"}')
on conflict (id) do nothing;

update public.profiles
set discoverable = true, plays = array['bass'], location_visibility = 'nobody'
where id = 'eeeeeeee-0000-0000-0000-00000000000e';

update public.profiles
set discoverable = true, plays = array['bass']
where id = '11111111-1111-1111-1111-111111111111';

do $$
declare
  found int;
begin
  select count(*) into found from public.find_musicians(array['bass'], null, 50)
  where id = 'eeeeeeee-0000-0000-0000-00000000000e';

  if found <> 1 then
    raise exception 'somebody who plays bass but has recorded nothing was not findable';
  end if;

  -- And the order is not the record. Both are in the list; which comes first
  -- is a rotation, not a ladder.
  if not exists (
    select 1 from public.find_musicians(array['bass'], null, 50)
    where id = '11111111-1111-1111-1111-111111111111'
  ) then
    raise exception 'somebody who has recorded bass fell out of the list';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Something to say back (0110).
--
-- A bass player who is still around at the end of this file (the bandmate's
-- account was deleted above, on purpose) answers the open ask on 'A Song That Asks' with a sentence
-- rather than a take. The trigger's whole job is to tell the people already
-- in the conversation and nobody else: first the asker, and once the asker
-- has answered back, the bass player as a previous replier. Neither is ever
-- told about their own words, and the room is not told again.
-- ---------------------------------------------------------------------

insert into public.ask_replies (ask_id, author_id, body)
select a.id, 'eeeeeeee-0000-0000-0000-00000000000e',
       'I hear pedal steel on the chorus.'
from public.project_asks a
where a.project_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
  and a.part is null
  and a.status = 'open';

do $$
declare
  told integer;
begin
  select count(*) into told from public.notifications
  where type = 'song_ask'
    and user_id = '11111111-1111-1111-1111-111111111111'
    and title like '%replied about%';
  if told <> 1 then
    raise exception 'the asker was not told about the reply (got %)', told;
  end if;

  if exists (
    select 1 from public.notifications
    where type = 'song_ask'
      and user_id = 'eeeeeeee-0000-0000-0000-00000000000e'
      and title like '%replied about%'
  ) then
    raise exception 'the person replying was told about their own reply';
  end if;
end $$;

insert into public.ask_replies (ask_id, author_id, body)
select a.id, '11111111-1111-1111-1111-111111111111',
       'Yes. Could you do Thursday?'
from public.project_asks a
where a.project_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
  and a.part is null
  and a.status = 'open';

do $$
declare
  bassist_told integer;
  writer_told integer;
begin
  select count(*) into bassist_told from public.notifications
  where type = 'song_ask'
    and user_id = 'eeeeeeee-0000-0000-0000-00000000000e'
    and title like '%replied about%';
  if bassist_told <> 1 then
    raise exception 'a previous replier was not told about the answer (got %)',
      bassist_told;
  end if;

  select count(*) into writer_told from public.notifications
  where type = 'song_ask'
    and user_id = '11111111-1111-1111-1111-111111111111'
    and title like '%replied about%';
  if writer_told <> 1 then
    raise exception 'the asker was told about their own answer (got %)',
      writer_told;
  end if;

  -- What was said is readable back in order, with the reply body intact.
  if (select count(*) from public.ask_replies r
      join public.project_asks a on a.id = r.ask_id
      where a.project_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb') <> 2 then
    raise exception 'the thread does not hold both replies';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Between the two of you (0112).
--
-- The writer says something to the bass player. The trigger's whole job is
-- to tell the one other person, under the sender's name, and never the
-- sender.
-- ---------------------------------------------------------------------

insert into public.direct_messages (pair_low, pair_high, author_id, body)
values ('11111111-1111-1111-1111-111111111111',
        'eeeeeeee-0000-0000-0000-00000000000e',
        '11111111-1111-1111-1111-111111111111',
        'Are you around this week?');

do $$
declare
  told integer;
  titled text;
begin
  select count(*) into told from public.notifications
  where type = 'direct_message'
    and user_id = 'eeeeeeee-0000-0000-0000-00000000000e';
  if told <> 1 then
    raise exception 'the other person was not told about the message (got %)', told;
  end if;

  if exists (
    select 1 from public.notifications
    where type = 'direct_message'
      and user_id = '11111111-1111-1111-1111-111111111111'
  ) then
    raise exception 'the sender was told about their own message';
  end if;

  select title into titled from public.notifications
  where type = 'direct_message'
    and user_id = 'eeeeeeee-0000-0000-0000-00000000000e';
  if titled is distinct from (
    select display_name from public.profiles
    where id = '11111111-1111-1111-1111-111111111111'
  ) then
    raise exception 'the message is not under the sender''s name (got %)', titled;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Heard it, from the Open Mic (0113).
--
-- The bass player is not in Smoke Room. Saying they heard 'A Song That
-- Asks', with a line, reaches the person who put it up as a project update
-- under the listener's name; the writer's own nod on their own song tells
-- nobody. The bandmate's nod earlier in this file said nothing, because a
-- bandmate's nod is already on the song.
-- ---------------------------------------------------------------------

-- The writer silenced project updates near the top of this file, to prove
-- the switch. A nod arrives as one, so the switch goes back on first --
-- which is also the assertion that a nod respects it.
update public.notification_preferences
set project_updates = true
where user_id = '11111111-1111-1111-1111-111111111111';

insert into public.project_nods (project_id, profile_id, note)
values ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
        'eeeeeeee-0000-0000-0000-00000000000e',
        'That chorus stayed with me.');

insert into public.project_nods (project_id, profile_id)
values ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
        '11111111-1111-1111-1111-111111111111');

do $$
declare
  told integer;
begin
  select count(*) into told from public.notifications
  where type = 'project_update'
    and user_id = '11111111-1111-1111-1111-111111111111'
    and title like '% heard %';
  if told <> 1 then
    raise exception 'the owner was not told somebody heard it (got %)', told;
  end if;

  if (select body from public.notifications
      where type = 'project_update'
        and user_id = '11111111-1111-1111-1111-111111111111'
        and title like '% heard %') <> 'That chorus stayed with me.' then
    raise exception 'the line did not reach the owner';
  end if;
end $$;

-- Saving the same nod again with the same line is not news.
update public.project_nods
set note = 'That chorus stayed with me.'
where project_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
  and profile_id = 'eeeeeeee-0000-0000-0000-00000000000e';

do $$
begin
  if (select count(*) from public.notifications
      where type = 'project_update'
        and user_id = '11111111-1111-1111-1111-111111111111'
        and title like '% heard %') <> 1 then
    raise exception 're-saving a nod told the owner again';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- A note that finds you later (0115).
--
-- The writer leaves a note that they would like to meet a bass player. The
-- bass player above is already findable, so the note meets them the next
-- time their listing changes -- and only once, however many times it
-- changes after that.
-- ---------------------------------------------------------------------

select public.leave_want('bass', 'a bass player', 'for the Thursday thing');

do $$
begin
  if (select count(*) from public.my_wants()) <> 1 then
    raise exception 'the note was not kept (got %)', (select count(*) from public.my_wants());
  end if;
end $$;

update public.profiles set discoverable = false
where id = 'eeeeeeee-0000-0000-0000-00000000000e';
update public.profiles set discoverable = true
where id = 'eeeeeeee-0000-0000-0000-00000000000e';

do $$
declare
  told integer;
begin
  select count(*) into told from public.notifications
  where type = 'want_matched'
    and user_id = '11111111-1111-1111-1111-111111111111';
  if told <> 1 then
    raise exception 'the person who left the note was not told (got %)', told;
  end if;

  if (select body from public.notifications
      where type = 'want_matched'
        and user_id = '11111111-1111-1111-1111-111111111111')
     not like '%a bass player%' then
    raise exception 'the note did not say what it was about';
  end if;

  if (select matched from public.my_wants() limit 1) <> 1 then
    raise exception 'the note does not know it found somebody';
  end if;
end $$;

update public.profiles set discoverable = false
where id = 'eeeeeeee-0000-0000-0000-00000000000e';
update public.profiles set discoverable = true
where id = 'eeeeeeee-0000-0000-0000-00000000000e';

do $$
begin
  if (select count(*) from public.notifications
      where type = 'want_matched'
        and user_id = '11111111-1111-1111-1111-111111111111') <> 1 then
    raise exception 'the same person was introduced twice';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Did it reach the phone (0117).
--
-- The writer's phone says the newest notification arrived with the app
-- closed; the week's report counts it. A second receipt for the same
-- row changes nothing, and a tap always records itself.
-- ---------------------------------------------------------------------

select public.push_arrived(id, 'closed') from public.notifications
where user_id = '11111111-1111-1111-1111-111111111111'
order by created_at desc limit 1;

do $$
declare
  confirmed integer;
  latest uuid;
begin
  select count(*) into confirmed from public.notifications
  where user_id = '11111111-1111-1111-1111-111111111111'
    and arrived_how = 'closed' and arrived_at is not null;
  if confirmed <> 1 then
    raise exception 'the phone''s receipt was not kept (got %)', confirmed;
  end if;

  if (select sent from public.push_delivery_report()) < 1
     or (select arrived_closed from public.push_delivery_report()) <> 1 then
    raise exception 'the week''s report does not count the receipt';
  end if;

  select id into latest from public.notifications
  where user_id = '11111111-1111-1111-1111-111111111111'
  order by created_at desc limit 1;
  perform public.push_arrived(latest, 'open');
  if (select arrived_how from public.notifications where id = latest) <> 'closed' then
    raise exception 'a later receipt overwrote the first';
  end if;
  perform public.push_arrived(latest, 'tapped');
  if (select arrived_how from public.notifications where id = latest) <> 'tapped' then
    raise exception 'a tap did not record itself';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- One place to talk (0118).
--
-- The bass player joins the Smoke Room; the writer says something in it.
-- The room tells the bass player and not the writer, under the writer's
-- name with the room on the notification. The bass player's inbox lists
-- the room with one unread line and the person thread from 0112;
-- looking at the room clears its count.
-- ---------------------------------------------------------------------

insert into public.room_members (room_id, user_id, display_name, role, color_value)
values ('33333333-3333-3333-3333-333333333333',
        'eeeeeeee-0000-0000-0000-00000000000e',
        'Never Recorded Anything', 'editor', 4278255360);

set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';

insert into public.room_messages (room_id, author_id, body)
values ('33333333-3333-3333-3333-333333333333',
        '11111111-1111-1111-1111-111111111111',
        'Rehearsal is Thursday at eight.');

do $$
declare
  told integer;
begin
  select count(*) into told from public.notifications
  where type = 'direct_message'
    and room_id = '33333333-3333-3333-3333-333333333333'
    and user_id = 'eeeeeeee-0000-0000-0000-00000000000e';
  if told <> 1 then
    raise exception 'the room did not tell the other member (got %)', told;
  end if;

  if exists (
    select 1 from public.notifications
    where type = 'direct_message'
      and room_id = '33333333-3333-3333-3333-333333333333'
      and user_id = '11111111-1111-1111-1111-111111111111'
  ) then
    raise exception 'the room told the person who spoke';
  end if;

  -- The room was renamed near the top of this file, so the title is read
  -- from the tables rather than typed here.
  if (select title from public.notifications
      where type = 'direct_message'
        and room_id = '33333333-3333-3333-3333-333333333333'
        and user_id = 'eeeeeeee-0000-0000-0000-00000000000e')
     is distinct from (
       (select display_name from public.profiles
        where id = '11111111-1111-1111-1111-111111111111')
       || ' · ' ||
       (select name from public.rooms
        where id = '33333333-3333-3333-3333-333333333333')) then
    raise exception 'the room message is not under the speaker''s name and the room''s (got %)',
      (select title from public.notifications
       where type = 'direct_message'
         and room_id = '33333333-3333-3333-3333-333333333333'
         and user_id = 'eeeeeeee-0000-0000-0000-00000000000e');
  end if;
end $$;

set local request.jwt.claims = '{"sub": "eeeeeeee-0000-0000-0000-00000000000e"}';

do $$
declare
  room_unread integer;
  people integer;
begin
  select unread into room_unread from public.my_threads()
  where kind = 'room' and target = '33333333-3333-3333-3333-333333333333';
  if room_unread is distinct from 1 then
    raise exception 'the room thread does not show the unread line (got %)', room_unread;
  end if;

  if (select last_body from public.my_threads()
      where kind = 'room' and target = '33333333-3333-3333-3333-333333333333')
     <> 'Rehearsal is Thursday at eight.' then
    raise exception 'the room thread does not show what was last said';
  end if;

  select count(*) into people from public.my_threads()
  where kind = 'person' and target = '11111111-1111-1111-1111-111111111111';
  if people <> 1 then
    raise exception 'the person thread from 0112 is not listed (got %)', people;
  end if;

  perform public.mark_thread_read('room', '33333333-3333-3333-3333-333333333333');

  select unread into room_unread from public.my_threads()
  where kind = 'room' and target = '33333333-3333-3333-3333-333333333333';
  if room_unread is distinct from 0 then
    raise exception 'looking at the room did not clear its count (got %)', room_unread;
  end if;
end $$;

set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';

-- ---------------------------------------------------------------------
-- Everybody you know (0119).
--
-- Joiner one shares The Invite Room with the writer and is not connected
-- to them, so the writer is somebody they might add -- named with the
-- room, and writable to, because a room-mate is somebody may_tell allows.
-- ---------------------------------------------------------------------

set local request.jwt.claims = '{"sub": "88888888-8888-8888-8888-888888888888"}';

do $$
declare
  found record;
begin
  select * into found from public.people_you_might_add()
  where person_id = '11111111-1111-1111-1111-111111111111';
  if found is null then
    raise exception 'the room-mate is not somebody you might add';
  end if;
  if found.because not like 'In %The Invite Room% with you' then
    raise exception 'the reason does not name the room (got %)', found.because;
  end if;
  if not found.can_message then
    raise exception 'a room-mate should be writable to';
  end if;
end $$;

set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';

-- ---------------------------------------------------------------------
-- Where they came from (0120).
--
-- A visitor with a flier code opens the tool and gets chords; the writer
-- signs in from the same link and claims the code once. The report
-- then answers which board worked. A second claim, with another code,
-- changes nothing.
-- ---------------------------------------------------------------------

select public.note_public_tool_step('opened', 'ORL-WP');
select public.note_public_tool_step('analyzed_ok', 'orl-wp');
select public.note_public_tool_step('opened', 'not a code');

do $$
declare
  claimed boolean;
  rep record;
begin
  select public.claim_arrival('orl-wp') into claimed;
  if not claimed then
    raise exception 'the first claim was refused';
  end if;
  select public.claim_arrival('other') into claimed;
  if claimed then
    raise exception 'a second claim overwrote the first';
  end if;
  if (select arrived_via from public.profiles
      where id = '11111111-1111-1111-1111-111111111111') <> 'orl-wp' then
    raise exception 'the profile does not remember its door';
  end if;

  select * into rep from public.arrival_report(7) where code = 'orl-wp';
  if rep is null or rep.opened <> 1 or rep.analyzed <> 1 or rep.signed_up <> 1 or rep.people <> 1 then
    raise exception 'the arrival report does not add up (got %)', rep;
  end if;
  if exists (select 1 from public.arrivals where code not in ('orl-wp')) then
    raise exception 'a malformed code was counted';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Tonight (0121).
--
-- The writer asks twice on the same day and gets the same prompt; the
-- song with a key and chords is theirs; the website's row exists; a
-- release written the way the workflow writes it comes back as notes.
-- ---------------------------------------------------------------------

set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';

insert into public.releases (sha, title, body)
values ('abc1234', 'The band talks in the room', 'Every room is a thread now.');

do $$
declare
  first_id integer;
  second_id integer;
  song uuid;
begin
  select prompt_id, song_id into first_id, song from public.tonight();
  if first_id is null then
    raise exception 'no prompt for tonight';
  end if;
  select prompt_id into second_id from public.tonight();
  if second_id is distinct from first_id then
    raise exception 'the prompt changed within the day (% then %)', first_id, second_id;
  end if;
  if (select count(*) from public.tonight_seen
      where user_id = '11111111-1111-1111-1111-111111111111') <> 1 then
    raise exception 'the day was recorded more than once';
  end if;
  if (select count(*) from public.tonight_for_everyone()) <> 1 then
    raise exception 'the website has no prompt today';
  end if;
  if (select count(*) from public.release_notes()) <> 1 then
    raise exception 'the release did not come back as a note';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- What to watch (0123).
--
-- The report runs and adds up. The writer signed up in this scenario and
-- the bass player delivered a take to one of their songs, so there is a
-- pairing to count and at least one room with a band in it.
-- ---------------------------------------------------------------------

do $$
declare
  signups bigint;
  bands bigint;
begin
  select value into signups from public.growth_report(3650) where metric = 'signups';
  if signups < 1 then
    raise exception 'the report counted no signups at all (got %)', signups;
  end if;

  select value into bands from public.growth_report(3650)
  where metric = 'rooms with a band in them';
  if bands < 1 then
    raise exception 'the report sees no room with two people in it (got %)', bands;
  end if;

  if (select count(*) from public.growth_report(7)) < 8 then
    raise exception 'the report is missing rows';
  end if;

  -- Nothing ranked, ever.
  if exists (
    select 1 from public.growth_report(3650)
    where metric ilike '%play%' or metric ilike '%like%' or metric ilike '%top%'
  ) then
    raise exception 'the report counts something it promised not to';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- What a crash actually is (0124).
--
-- One session with a push token that would not register is an error and
-- is not a crash; one whose library never loaded is both. The two rates
-- have to disagree about exactly that, or the split is decoration.
-- ---------------------------------------------------------------------

insert into public.app_sessions (id, user_id, app_version, platform)
values ('health-quiet', '11111111-1111-1111-1111-111111111111', '9.9.9', 'android'),
       ('health-noisy', '11111111-1111-1111-1111-111111111111', '9.9.9', 'android'),
       ('health-broken', '11111111-1111-1111-1111-111111111111', '9.9.9', 'android');

insert into public.analysis_errors
  (session_id, severity, stage, message, service, signature)
values ('health-noisy', 'error', 'push.register_token', 'no token', 'app', 'smoke-noisy'),
       ('health-broken', 'error', 'load', 'Gateway Timeout', 'app', 'smoke-broken');

do $$
declare
  health record;
begin
  select * into health from public.app_health(1) where app_version = '9.9.9';
  if health.sessions <> 3 then
    raise exception 'the three sessions were not counted (got %)', health.sessions;
  end if;
  if health.sessions_with_an_error <> 2 then
    raise exception 'both errors should count as errors (got %)', health.sessions_with_an_error;
  end if;
  if health.sessions_that_could_not_work <> 1 then
    raise exception 'only the failed load could not work (got %)', health.sessions_that_could_not_work;
  end if;
  if health.crash_free_percent <= health.error_free_percent then
    raise exception 'the two rates should disagree here (% vs %)',
      health.crash_free_percent, health.error_free_percent;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- The receipt outlives the inbox (0127).
--
-- 0117 put the receipt on the notification, and the notification is the
-- inbox: there is a Clear-read button on that screen. On 15 September a
-- push was accepted by FCM for two of Taylor's devices and the evidence
-- was gone by the time anybody looked, because the row had been cleared.
--
-- So: a registered phone, a notification, a receipt, then the
-- notification deleted out from under it. The receipt has to still be
-- there afterwards, and the week's report has to still count it. If a
-- foreign key is ever added to push_arrivals.notification_id, this
-- section is what fails.
-- ---------------------------------------------------------------------

set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';

select public.register_device_token('smoke-device-token-ABCDEF', 'android');

do $$
declare
  seen record;
  found integer;
begin
  select count(*) into found from public.my_devices();
  if found <> 1 then
    raise exception 'the registered phone is not listed (got %)', found;
  end if;

  select * into seen from public.my_devices() limit 1;
  if seen.token_tail <> 'ABCDEF' then
    raise exception 'the device is not identifiable by its tail (got %)', seen.token_tail;
  end if;
  if seen.platform <> 'android' then
    raise exception 'the platform was not kept (got %)', seen.platform;
  end if;
  if seen.first_seen_at is null or seen.last_seen_at is null then
    raise exception 'a device with no timestamps cannot be told from another';
  end if;
end $$;

-- A notification for the writer, from somebody else, with a phone now on
-- the account: the trigger should write down that a push was queued.
insert into public.notifications (user_id, type, title, body, actor_id)
values ('11111111-1111-1111-1111-111111111111', 'project_update',
        'A receipt that outlives its row', 'body',
        'eeeeeeee-0000-0000-0000-00000000000e');

do $$
declare
  target uuid;
  queued record;
  before_sent integer;
  after_sent integer;
  kept record;
begin
  select id into target from public.notifications
  where user_id = '11111111-1111-1111-1111-111111111111'
    and title = 'A receipt that outlives its row';
  if target is null then
    raise exception 'the notification under test was not written';
  end if;

  select * into queued from public.push_arrivals where notification_id = target;
  if queued.notification_id is null then
    raise exception 'the queued push was not written down';
  end if;
  if queued.arrived_at is not null then
    raise exception 'a push nobody has confirmed must not read as arrived';
  end if;
  if queued.user_id <> '11111111-1111-1111-1111-111111111111' then
    raise exception 'the receipt is filed under the wrong account';
  end if;

  -- The phone says it got it with the app closed.
  perform public.push_arrived(target, 'closed');
  select sent into before_sent from public.push_delivery_report();

  -- And now the inbox is cleared, which is what actually happened.
  delete from public.notifications where id = target;
  if exists (select 1 from public.notifications where id = target) then
    raise exception 'the notification did not delete';
  end if;

  select * into kept from public.push_arrivals where notification_id = target;
  if kept.notification_id is null then
    raise exception 'clearing the inbox destroyed the receipt again';
  end if;
  if kept.arrived_how <> 'closed' then
    raise exception 'the receipt survived without what it said (got %)', kept.arrived_how;
  end if;

  select sent into after_sent from public.push_delivery_report();
  if after_sent <> before_sent then
    raise exception 'the week''s report changed when the inbox was cleared (% then %)',
      before_sent, after_sent;
  end if;
  if (select arrived from public.push_delivery_report()) < 1 then
    raise exception 'the report counts no arrival for a phone that confirmed one';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- What the lesson left (0128).
--
-- The writer followed somebody on their own song and kept what was worked
-- on. Keeping it again under the same name updates the one row and keeps
-- the note; a stranger can neither keep a mark on that song nor read the
-- writer's; and a part that is not a part is refused.
-- ---------------------------------------------------------------------

reset role;
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';
set local role authenticated;

select public.keep_practice_mark(
  'cccccccc-0128-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-00000000000a',
  'eeeeeeee-0000-0000-0000-00000000000e',
  'The Teacher',
  'Keep it slow until the change is clean',
  '[{"start": 3000, "end": 6000, "label": "Chorus 1", "rate": 0.75, "seconds": 95}]'::jsonb
);

-- The student took over, followed again, and the phone saved the same mark
-- with more in it and no note this time.
select public.keep_practice_mark(
  'cccccccc-0128-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-00000000000a',
  'eeeeeeee-0000-0000-0000-00000000000e',
  'The Teacher',
  null,
  '[{"start": 3000, "end": 6000, "label": "Chorus 1", "rate": 0.75, "seconds": 140},
    {"start": null, "end": null, "label": "The whole song", "rate": 1, "seconds": 30}]'::jsonb
);

do $$
declare
  kept record;
begin
  if (select count(*) from public.my_practice_marks()) <> 1 then
    raise exception 'a second save of the same session made a second mark (got %)',
      (select count(*) from public.my_practice_marks());
  end if;
  select * into kept from public.my_practice_marks() limit 1;
  if kept.note is distinct from 'Keep it slow until the change is clean' then
    raise exception 'a later save without a note took the note away (got %)', kept.note;
  end if;
  if jsonb_array_length(kept.parts) <> 2 then
    raise exception 'the later save did not replace the parts';
  end if;
  if kept.led_by is distinct from 'eeeeeeee-0000-0000-0000-00000000000e'::uuid then
    raise exception 'who led was not kept';
  end if;
end $$;

-- A leader id that is nobody is kept as a name without a person.
select public.keep_practice_mark(
  'cccccccc-0128-0000-0000-000000000002',
  'aaaaaaaa-0000-0000-0000-00000000000a',
  'dddddddd-dead-dead-dead-dddddddddddd',
  'Nobody Real',
  null,
  '[]'::jsonb
);

do $$
begin
  if (select led_by from public.practice_marks
      where id = 'cccccccc-0128-0000-0000-000000000002') is not null then
    raise exception 'an unknown leader id was stored as a person';
  end if;

  begin
    perform public.keep_practice_mark(
      'cccccccc-0128-0000-0000-000000000003',
      'aaaaaaaa-0000-0000-0000-00000000000a',
      null, 'Somebody', null,
      '[{"label": "Chorus", "rate": "fast", "seconds": 10}]'::jsonb);
    raise exception 'a part with no real speed was kept';
  exception when invalid_parameter_value or invalid_text_representation then null;
  end;

  begin
    insert into public.practice_marks (id, profile_id, project_id, led_by_name)
    values ('cccccccc-0128-0000-0000-000000000004',
            '11111111-1111-1111-1111-111111111111',
            'aaaaaaaa-0000-0000-0000-00000000000a', 'Around the function');
    raise exception 'a mark was written without going through keep_practice_mark';
  exception when insufficient_privilege then null;
  end;
end $$;

-- Practising on your own (Every Musician, Same Song, 17 September 2026).
--
-- A solo session on Perform keeps the same kind of mark with the person as
-- their own leader, which is how the card knows to say "Your practice"
-- rather than a name. No migration was needed for it: keep_practice_mark
-- asks who led, not whether it was somebody else. This is what says so.
select public.keep_practice_mark(
  'cccccccc-0128-0000-0000-000000000006',
  'aaaaaaaa-0000-0000-0000-00000000000a',
  '11111111-1111-1111-1111-111111111111',
  'You',
  null,
  '[{"start": 3000, "end": 6000, "label": "Chorus 2", "rate": 0.75, "seconds": 95}]'::jsonb
);

do $$
declare
  leader uuid;
begin
  select led_by into leader from public.practice_marks
  where id = 'cccccccc-0128-0000-0000-000000000006';
  if leader is distinct from '11111111-1111-1111-1111-111111111111'::uuid then
    raise exception 'practising on your own did not keep you as its leader (got %)', leader;
  end if;
  if not exists (
    select 1 from public.my_practice_marks()
    where id = 'cccccccc-0128-0000-0000-000000000006'
  ) then
    raise exception 'your own practice was not handed back to you';
  end if;
end $$;

-- And the next evening on the same song goes on the same mark. Practising
-- alone is meant to be a habit, and a row a session would fill the fortnight
-- with one song -- Home reads back the twenty newest -- and push every other
-- song's card, a teacher's words with them. The phone hands back the name it
-- used last time; this is the server keeping its side of that.
select public.keep_practice_mark(
  'cccccccc-0128-0000-0000-000000000006',
  'aaaaaaaa-0000-0000-0000-00000000000a',
  '11111111-1111-1111-1111-111111111111',
  'You',
  null,
  '[{"start": 0, "end": 3000, "label": "Verse 1", "rate": 0.5, "seconds": 210}]'::jsonb
);

do $$
declare
  mine record;
begin
  if (select count(*) from public.practice_marks
      where project_id = 'aaaaaaaa-0000-0000-0000-00000000000a'
        and profile_id = '11111111-1111-1111-1111-111111111111'
        and led_by = '11111111-1111-1111-1111-111111111111') <> 1 then
    raise exception 'practising the same song again made a second mark of your own (got %)',
      (select count(*) from public.practice_marks
       where project_id = 'aaaaaaaa-0000-0000-0000-00000000000a'
         and profile_id = '11111111-1111-1111-1111-111111111111'
         and led_by = '11111111-1111-1111-1111-111111111111');
  end if;
  select * into mine from public.my_practice_marks()
  where id = 'cccccccc-0128-0000-0000-000000000006';
  if mine.parts -> 0 ->> 'label' is distinct from 'Verse 1' then
    raise exception 'the next evening did not replace what was worked on (got %)', mine.parts;
  end if;
end $$;

-- A stranger: not in the room, and the song was not shared with them.
set local request.jwt.claims = '{"sub": "88888888-8888-8888-8888-888888888888", "email": "joiner.one@smoke.test"}';

do $$
begin
  if exists (select 1 from public.practice_marks) then
    raise exception 'a stranger could read somebody''s practice marks';
  end if;
  if exists (select 1 from public.my_practice_marks()) then
    raise exception 'my_practice_marks handed a stranger somebody else''s marks';
  end if;

  begin
    perform public.keep_practice_mark(
      'cccccccc-0128-0000-0000-000000000005',
      'aaaaaaaa-0000-0000-0000-00000000000a',
      null, 'Somebody', null, '[]'::jsonb);
    raise exception 'a stranger kept a practice mark on a song that is not theirs';
  exception when insufficient_privilege then null;
  end;

  -- Nor take over the writer's mark by using its name.
  begin
    perform public.keep_practice_mark(
      'cccccccc-0128-0000-0000-000000000001',
      '44444444-4444-4444-4444-444444444444',
      null, 'Somebody', 'mine now', '[]'::jsonb);
    raise exception 'a stranger overwrote somebody else''s practice mark';
  exception when insufficient_privilege or invalid_parameter_value then null;
  end;
end $$;

reset role;
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';

-- ---------------------------------------------------------------------
-- A link for lessons (0129).
--
-- The writer makes two lesson links, each with its own code and name -- one
-- open at a time was 0129's rule, and 0148 dropped it. A student opens the
-- second and gets a room of their own with the writer, told to the writer;
-- opening it again (typed with dashes, in capitals) gives the same room.
-- The teacher cannot join their own link, a stranger cannot see anybody's
-- lesson rooms, and a link turned off opens nothing.
-- ---------------------------------------------------------------------

reset role;

-- Both ends of a lesson link are adults since 0139, and both accounts here
-- are needed as they are by "Calls for adults (0134)" further down -- the
-- writer has never been asked for a birth month there, and Joiner One
-- answers as a 15-year-old. So they are adults for the length of this block
-- and cleared at the end of it, the way the connection rows above are. The
-- age rule itself is checked in its own block, with the cast this scenario
-- has by then.
insert into private.birth_months (person_id, born) values
  ('11111111-1111-1111-1111-111111111111', date '1990-05-01'),
  ('88888888-8888-8888-8888-888888888888', date '1992-08-01');

set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';
set local role authenticated;

select public.open_lesson_link('Guitar lessons') as lesson_code_first \gset
select public.open_lesson_link('Guitar and voice') as lesson_code \gset
select set_config('smoke.lesson_code_first', :'lesson_code_first', true);
select set_config('smoke.lesson_code', :'lesson_code', true);

do $$
begin
  if current_setting('smoke.lesson_code_first') = current_setting('smoke.lesson_code') then
    raise exception 'two lesson links were given one code';
  end if;
  if (select count(*) from public.my_lesson_links()) <> 2 then
    raise exception 'the teacher does not have both lesson links open';
  end if;
  if (select l.title from public.my_lesson_links() l
      where l.code = current_setting('smoke.lesson_code')) <> 'Guitar and voice' then
    raise exception 'a lesson link is not called what the teacher called it';
  end if;
  -- Neither is a class until the teacher says so.
  if exists (select 1 from public.my_lesson_links() l where l.class_room_id is not null) then
    raise exception 'a plain lesson link opens into a class room';
  end if;

  begin
    perform public.join_lesson_link(current_setting('smoke.lesson_code'));
    raise exception 'a teacher joined their own lesson link';
  exception when invalid_parameter_value then null;
  end;
end $$;

-- A student opens it.
set local request.jwt.claims = '{"sub": "88888888-8888-8888-8888-888888888888", "email": "joiner.one@smoke.test"}';

select public.join_lesson_link(:'lesson_code') as lesson_room \gset
select public.join_lesson_link(
  upper(substr(:'lesson_code', 1, 4) || '-' || substr(:'lesson_code', 5, 4) || '-' || substr(:'lesson_code', 9, 4))
) as lesson_room_again \gset
select set_config('smoke.lesson_room', :'lesson_room', true);
select set_config('smoke.lesson_room_again', :'lesson_room_again', true);

do $$
begin
  if current_setting('smoke.lesson_room') <> current_setting('smoke.lesson_room_again') then
    raise exception 'opening a lesson link twice made a second room';
  end if;
  if (select count(*) from public.lesson_rooms) <> 1 then
    raise exception 'the student cannot see their own lesson room';
  end if;
  if exists (select 1 from public.lesson_links) then
    raise exception 'a student can read the teacher''s lesson link';
  end if;
end $$;

reset role;

do $$
declare
  lesson uuid := current_setting('smoke.lesson_room')::uuid;
begin
  if (select account_id from public.rooms where id = lesson)
     is distinct from '11111111-1111-1111-1111-111111111111'::uuid then
    raise exception 'the lesson room does not belong to the teacher';
  end if;
  if (select name from public.rooms where id = lesson) not like 'Guitar and voice · %' then
    raise exception 'the lesson room is not named for the lessons and the student (got %)',
      (select name from public.rooms where id = lesson);
  end if;
  if (select count(*) from public.room_members where room_id = lesson) <> 2 then
    raise exception 'a lesson room holds somebody besides the teacher and the student';
  end if;
  if (select role from public.room_members
      where room_id = lesson and user_id = '11111111-1111-1111-1111-111111111111')
     is distinct from 'owner' then
    raise exception 'the teacher does not own the lesson room';
  end if;
  if (select role from public.room_members
      where room_id = lesson and user_id = '88888888-8888-8888-8888-888888888888')
     is distinct from 'editor' then
    raise exception 'the student cannot work in their own lesson room';
  end if;
  if private.wants_invite_responses('11111111-1111-1111-1111-111111111111')
     and not exists (
       select 1 from public.notifications
       where user_id = '11111111-1111-1111-1111-111111111111'
         and type = 'invite_accepted'
         and room_id = lesson
     ) then
    raise exception 'the teacher was not told a student joined';
  end if;
end $$;

-- Somebody else entirely sees none of it.
set local request.jwt.claims = '{"sub": "99999999-9999-9999-9999-999999999999", "email": "joiner.two@smoke.test"}';
set local role authenticated;

do $$
begin
  if exists (select 1 from public.lesson_rooms) or exists (select 1 from public.lesson_links) then
    raise exception 'a stranger can see somebody''s lessons';
  end if;
end $$;

-- The teacher turns the link off; the room made through it stays.
reset role;
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';
set local role authenticated;
select public.close_lesson_link();

set local request.jwt.claims = '{"sub": "99999999-9999-9999-9999-999999999999", "email": "joiner.two@smoke.test"}';

do $$
begin
  begin
    perform public.join_lesson_link(current_setting('smoke.lesson_code'));
    raise exception 'a lesson link that was turned off still made a room';
  exception when invalid_parameter_value then
    -- Said for the right reason: Joiner Two has not been asked for a birth
    -- month yet, and since 0139 that refusal shares this error code. A link
    -- that was turned off is off for everybody, whatever their age.
    if sqlerrm not like '%turned off%' then
      raise exception 'a lesson link that was turned off was refused for the wrong reason (%)', sqlerrm;
    end if;
  end;
end $$;

reset role;

do $$
begin
  if not exists (select 1 from public.rooms where id = current_setting('smoke.lesson_room')::uuid) then
    raise exception 'turning the link off removed a lesson room';
  end if;
end $$;

-- The two accounts go back to what the blocks below need them to be.
delete from private.birth_months
where person_id in ('11111111-1111-1111-1111-111111111111',
                    '88888888-8888-8888-8888-888888888888');

set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';

-- ---------------------------------------------------------------------
-- A code for meeting in person (0130).
--
-- The writer's code is made once and kept; a changed code opens nobody.
-- Somebody who opens it sees whose it is and is added to nothing. Once
-- each has asked from the other's code the two are connected, with no
-- third step. Nobody reads anybody else's code, and a block shuts the
-- door from either side with the same words.
-- ---------------------------------------------------------------------

reset role;
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';
set local role authenticated;

select public.my_meeting_code() as first_code \gset
select public.my_meeting_code() as first_code_again \gset
select set_config('smoke.first_code_again', :'first_code_again', true);
select public.change_my_meeting_code() as writer_code \gset
select set_config('smoke.first_code', :'first_code', true);
select set_config('smoke.writer_code', :'writer_code', true);

do $$
begin
  if current_setting('smoke.first_code') !~ '^[0-9a-hjkmnp-tv-z]{8}$' then
    raise exception 'a meeting code has the wrong shape (got %)', current_setting('smoke.first_code');
  end if;
  if current_setting('smoke.first_code_again') <> current_setting('smoke.first_code') then
    raise exception 'asking for your code again made a new one';
  end if;
  if current_setting('smoke.first_code') = current_setting('smoke.writer_code') then
    raise exception 'changing a meeting code kept the same code';
  end if;
  if public.my_meeting_code() <> current_setting('smoke.writer_code') then
    raise exception 'the changed code is not the one kept';
  end if;
  begin
    perform public.person_with_meeting_code(current_setting('smoke.writer_code'));
    raise exception 'somebody opened their own meeting code';
  exception when invalid_parameter_value then null;
  end;
end $$;

-- Somebody else opens it: typed with a dash, in capitals, an O for the 0.
set local request.jwt.claims = '{"sub": "88888888-8888-8888-8888-888888888888", "email": "joiner.one@smoke.test"}';

select public.my_meeting_code() as joiner_code \gset
select set_config('smoke.joiner_code', :'joiner_code', true);

do $$
declare
  typed text := upper(substr(current_setting('smoke.writer_code'), 1, 4) || '-'
                      || substr(current_setting('smoke.writer_code'), 5, 4));
  card record;
begin
  typed := replace(typed, '0', 'O');
  select * into card from public.person_with_meeting_code(typed);
  if card.person_id is distinct from '11111111-1111-1111-1111-111111111111'::uuid then
    raise exception 'a typed meeting code did not open its person';
  end if;
  if card.state <> 'none' or card.direction is not null then
    raise exception 'opening a meeting code did more than show whose it is (state %)', card.state;
  end if;
  if exists (select 1 from public.my_connections()) then
    raise exception 'opening a meeting code added somebody';
  end if;
  if (select count(*) from public.meeting_codes) <> 1 then
    raise exception 'somebody can read a meeting code that is not theirs';
  end if;
  begin
    perform public.person_with_meeting_code(current_setting('smoke.first_code'));
    raise exception 'a meeting code that was changed still opens its person';
  exception when invalid_parameter_value then null;
  end;

  if public.request_connection('11111111-1111-1111-1111-111111111111') <> 'pending' then
    raise exception 'adding from a meeting code was not a request';
  end if;
  select * into card from public.person_with_meeting_code(current_setting('smoke.writer_code'));
  if card.state <> 'pending' or card.direction <> 'outgoing' then
    raise exception 'the card does not say the request is waiting (% %)', card.state, card.direction;
  end if;
end $$;

-- The writer scans back, and the two are connected on the spot.
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';

do $$
declare
  card record;
begin
  select * into card from public.person_with_meeting_code(current_setting('smoke.joiner_code'));
  if card.state <> 'pending' or card.direction <> 'incoming' then
    raise exception 'the card does not say they already asked (% %)', card.state, card.direction;
  end if;
  if public.request_connection(card.person_id) <> 'accepted' then
    raise exception 'scanning each other''s codes did not connect the two';
  end if;
end $$;

-- A block closes the door from either side, in the words request_connection uses.
reset role;
insert into public.user_blocks (blocker_id, blocked_id)
values ('99999999-9999-9999-9999-999999999999', '11111111-1111-1111-1111-111111111111');

set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';
set local role authenticated;

set local request.jwt.claims = '{"sub": "99999999-9999-9999-9999-999999999999", "email": "joiner.two@smoke.test"}';

do $$
begin
  begin
    perform public.person_with_meeting_code(current_setting('smoke.writer_code'));
    raise exception 'somebody who blocked a person can still open their code';
  exception when insufficient_privilege then
    if sqlerrm <> 'That person cannot be added.' then
      raise exception 'a blocked meeting code says something else: %', sqlerrm;
    end if;
  end;
end $$;

reset role;
delete from public.user_blocks
where blocker_id = '99999999-9999-9999-9999-999999999999'
  and blocked_id = '11111111-1111-1111-1111-111111111111';
delete from public.connections
where '11111111-1111-1111-1111-111111111111' in (requester_id, addressee_id);

set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';

-- ---------------------------------------------------------------------
-- Somebody wants to add you (0132).
--
-- A request tells the person asked; a yes clears that card and tells the
-- person who asked. Asking again within a day tells nobody again, and a
-- request withdrawn takes its card with it.
-- ---------------------------------------------------------------------

reset role;
set local request.jwt.claims = '{"sub": "99999999-9999-9999-9999-999999999999", "email": "joiner.two@smoke.test"}';
set local role authenticated;
select public.request_connection('88888888-8888-8888-8888-888888888888') as asked_state \gset

reset role;
do $$
begin
  if private.wants_invites('88888888-8888-8888-8888-888888888888')
     and (select count(*) from public.notifications
          where user_id = '88888888-8888-8888-8888-888888888888'
            and actor_id = '99999999-9999-9999-9999-999999999999'
            and type = 'connection_request') <> 1 then
    raise exception 'the person asked to connect was not told';
  end if;
end $$;

-- The yes.
set local request.jwt.claims = '{"sub": "88888888-8888-8888-8888-888888888888", "email": "joiner.one@smoke.test"}';
set local role authenticated;
select public.respond_to_connection('99999999-9999-9999-9999-999999999999', true) as answer \gset

reset role;
do $$
begin
  if exists (select 1 from public.notifications
             where user_id = '88888888-8888-8888-8888-888888888888'
               and actor_id = '99999999-9999-9999-9999-999999999999'
               and type = 'connection_request') then
    raise exception 'a request that was answered left its card in the inbox';
  end if;
  if private.wants_invite_responses('99999999-9999-9999-9999-999999999999')
     and not exists (select 1 from public.notifications
                     where user_id = '99999999-9999-9999-9999-999999999999'
                       and actor_id = '88888888-8888-8888-8888-888888888888'
                       and type = 'connection_accepted') then
    raise exception 'the person who asked was not told about the yes';
  end if;
end $$;

-- Removed, and asked again the same day: no second card, no second push.
set local request.jwt.claims = '{"sub": "99999999-9999-9999-9999-999999999999", "email": "joiner.two@smoke.test"}';
set local role authenticated;
select public.remove_connection('88888888-8888-8888-8888-888888888888');
select public.request_connection('88888888-8888-8888-8888-888888888888') as asked_again \gset

reset role;
do $$
begin
  if exists (select 1 from public.notifications
             where user_id = '88888888-8888-8888-8888-888888888888'
               and actor_id = '99999999-9999-9999-9999-999999999999'
               and type = 'connection_request') then
    raise exception 'asking again within a day told them again';
  end if;
end $$;

-- A request withdrawn takes its card with it.
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';
set local role authenticated;
select public.request_connection('99999999-9999-9999-9999-999999999999') as writer_asked \gset

reset role;
do $$
begin
  if private.wants_invites('99999999-9999-9999-9999-999999999999')
     and not exists (select 1 from public.notifications
                     where user_id = '99999999-9999-9999-9999-999999999999'
                       and actor_id = '11111111-1111-1111-1111-111111111111'
                       and type = 'connection_request') then
    raise exception 'the second request was not told';
  end if;
end $$;

set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';
set local role authenticated;
select public.remove_connection('99999999-9999-9999-9999-999999999999');

reset role;
do $$
begin
  if exists (select 1 from public.notifications
             where user_id = '99999999-9999-9999-9999-999999999999'
               and actor_id = '11111111-1111-1111-1111-111111111111'
               and type = 'connection_request') then
    raise exception 'a withdrawn request left its card in the inbox';
  end if;
end $$;

delete from public.connections
where '99999999-9999-9999-9999-999999999999' in (requester_id, addressee_id);

set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';

-- ---------------------------------------------------------------------
-- Calls for adults (0134).
--
-- A birth month is said once and never by an under-13. In room aaaa the
-- writer and Joiner Two are adults and Joiner One is 15: the writer's call
-- tells Joiner Two once and never tells Joiner One, who cannot be in it.
-- Somebody outside the room cannot join, and a block hides the caller.
-- ---------------------------------------------------------------------

reset role;
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';
set local role authenticated;

do $$
begin
  if public.my_call_standing() <> 'unknown' then
    raise exception 'somebody never asked has a call standing (%)', public.my_call_standing();
  end if;
  if public.may_join_call('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') <> 'birth_month_needed' then
    raise exception 'a call did not ask for a birth month first';
  end if;
  if public.set_my_birth_month(1990, 5) <> 'adult' then
    raise exception 'somebody born in 1990 is not an adult';
  end if;
  begin
    perform public.set_my_birth_month(2012, 1);
    raise exception 'a birth month was changed from the app';
  exception when invalid_parameter_value then null;
  end;
  if public.may_join_call('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') <> 'ok' then
    raise exception 'an adult member cannot join their room''s call';
  end if;
end $$;

set local request.jwt.claims = '{"sub": "88888888-8888-8888-8888-888888888888", "email": "joiner.one@smoke.test"}';

do $$
begin
  if public.set_my_birth_month(extract(year from current_date)::int - 15, 1) <> 'minor' then
    raise exception 'a 15-year-old is not a minor';
  end if;
  if public.may_join_call('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') = 'ok' then
    raise exception 'a minor may join a call in stage A';
  end if;
  begin
    perform public.hear_me_in_call('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'phone-j1');
    raise exception 'a minor was put in a call';
  exception when insufficient_privilege then null;
  end;
end $$;

-- An under-13 answer is no longer an error, and is remembered: see "An age
-- answer stays (0138)" below, which uses an account of its own so the
-- bandmate here stays somebody never asked.

set local request.jwt.claims = '{"sub": "99999999-9999-9999-9999-999999999999", "email": "joiner.two@smoke.test"}';
select public.set_my_birth_month(1985, 3) as joiner_two_standing \gset

do $$
begin
  -- An adult, but not in the writer's first room.
  if public.may_join_call('33333333-3333-3333-3333-333333333333') <> 'Calls are for people in this room.' then
    raise exception 'somebody outside the room may join its call';
  end if;
end $$;

-- The writer starts a call, twice (a dropped connection and a rejoin).
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';
select public.hear_me_in_call('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'phone-w');
select public.hear_me_in_call('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'phone-w');

reset role;
do $$
begin
  if (select count(*) from public.notifications
      where user_id = '99999999-9999-9999-9999-999999999999'
        and type = 'call_started'
        and room_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') <> 1 then
    raise exception 'an adult in the room was not told exactly once that a call started (%)',
      (select count(*) from public.notifications
       where user_id = '99999999-9999-9999-9999-999999999999' and type = 'call_started');
  end if;
  if exists (select 1 from public.notifications
             where user_id = '88888888-8888-8888-8888-888888888888' and type = 'call_started') then
    raise exception 'a minor was told about a call they cannot join';
  end if;
end $$;

set local request.jwt.claims = '{"sub": "99999999-9999-9999-9999-999999999999", "email": "joiner.two@smoke.test"}';
set local role authenticated;

do $$
begin
  if not exists (select 1 from public.room_call('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
                 where user_id = '11111111-1111-1111-1111-111111111111') then
    raise exception 'the room does not show who is in its call';
  end if;
  -- Refused outright or read as empty: either way nobody reads it directly.
  begin
    if exists (select 1 from public.call_presence) then
      raise exception 'call presence is readable directly';
    end if;
  exception when insufficient_privilege then null;
  end;
  if public.blocked_with_any(array['11111111-1111-1111-1111-111111111111'::uuid]) then
    raise exception 'a block is reported where there is none';
  end if;
end $$;

reset role;
insert into public.user_blocks (blocker_id, blocked_id)
values ('99999999-9999-9999-9999-999999999999', '11111111-1111-1111-1111-111111111111');

set local request.jwt.claims = '{"sub": "99999999-9999-9999-9999-999999999999", "email": "joiner.two@smoke.test"}';
set local role authenticated;

do $$
begin
  if exists (select 1 from public.room_call('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')) then
    raise exception 'somebody blocked still shows in the call';
  end if;
  if not public.blocked_with_any(array['11111111-1111-1111-1111-111111111111'::uuid]) then
    raise exception 'call-token would let somebody into a call with a person they blocked';
  end if;
end $$;

reset role;
delete from public.user_blocks
where blocker_id = '99999999-9999-9999-9999-999999999999'
  and blocked_id = '11111111-1111-1111-1111-111111111111';

set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';
set local role authenticated;
select public.leave_call('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'phone-w');

set local request.jwt.claims = '{"sub": "99999999-9999-9999-9999-999999999999", "email": "joiner.two@smoke.test"}';

do $$
begin
  if exists (select 1 from public.room_call('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')) then
    raise exception 'somebody who left still shows in the call';
  end if;
end $$;

reset role;
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';

-- Your people have pages (0137).
--
-- Somebody met at a gig: not listed in Open Mic, no room together. Before
-- they ask, their page is closed; once either of you asks, it opens; a block
-- closes it again.
insert into auth.users (id, email, raw_user_meta_data) values
  ('c0ec7000-0000-0000-0000-000000000137', 'metatagig@smoke.test', '{"display_name": "Met At A Gig"}');

do $$
begin
  if exists (
    select 1 from public.musician_profile('c0ec7000-0000-0000-0000-000000000137')
  ) then
    raise exception 'a stranger''s unlisted page opened before anybody asked';
  end if;

  insert into public.connections (requester_id, addressee_id)
  values ('c0ec7000-0000-0000-0000-000000000137', '11111111-1111-1111-1111-111111111111');

  if not exists (
    select 1 from public.musician_profile('c0ec7000-0000-0000-0000-000000000137')
  ) then
    raise exception 'somebody asking to add you had no page to decide from';
  end if;

  update public.connections set state = 'accepted', responded_at = now()
  where requester_id = 'c0ec7000-0000-0000-0000-000000000137'
    and addressee_id = '11111111-1111-1111-1111-111111111111';

  if not exists (
    select 1 from public.musician_profile('c0ec7000-0000-0000-0000-000000000137')
      where discoverable is null and location_visibility is null
  ) then
    raise exception 'a connection''s page did not open, or showed their settings';
  end if;

  insert into public.user_blocks (blocker_id, blocked_id)
  values ('11111111-1111-1111-1111-111111111111', 'c0ec7000-0000-0000-0000-000000000137');

  if exists (
    select 1 from public.musician_profile('c0ec7000-0000-0000-0000-000000000137')
  ) then
    raise exception 'a blocked connection''s page still opened';
  end if;

  delete from public.user_blocks
  where blocker_id = '11111111-1111-1111-1111-111111111111'
    and blocked_id = 'c0ec7000-0000-0000-0000-000000000137';
  delete from public.connections
  where requester_id = 'c0ec7000-0000-0000-0000-000000000137';
end $$;

-- ---------------------------------------------------------------------
-- An age answer stays (0138).
--
-- The audit of 17 September 2026 (CO1): an under-13 answer left the picker
-- open for an older year. Now the answer is remembered without the month, a
-- second answer as an adult is refused, the standing reads 'refused', calls
-- stay closed, and a call in their room does not tell them. In a room of its
-- own with the writer and Joiner Two, so the call below is the room's first.
-- ---------------------------------------------------------------------

reset role;
insert into auth.users (id, email, raw_user_meta_data) values
  ('a9e00013-0000-0000-0000-000000000138', 'said.under.thirteen@smoke.test',
   '{"display_name": "Said Under Thirteen"}');

insert into public.rooms (id, account_id, name)
values ('a9e00013-0000-0000-0000-00000000013a', '11111111-1111-1111-1111-111111111111', 'The Age Room');

insert into public.room_members (room_id, user_id, display_name, role) values
  ('a9e00013-0000-0000-0000-00000000013a', '11111111-1111-1111-1111-111111111111', 'The Writer', 'owner'),
  ('a9e00013-0000-0000-0000-00000000013a', '99999999-9999-9999-9999-999999999999', 'Joiner Two', 'editor'),
  ('a9e00013-0000-0000-0000-00000000013a', 'a9e00013-0000-0000-0000-000000000138', 'Said Under Thirteen', 'editor');

set local request.jwt.claims = '{"sub": "a9e00013-0000-0000-0000-000000000138", "email": "said.under.thirteen@smoke.test"}';
set local role authenticated;

do $$
begin
  if public.my_call_standing() is distinct from 'unknown' then
    raise exception 'somebody never asked has a call standing (%)', public.my_call_standing();
  end if;
  if public.set_my_birth_month(extract(year from current_date)::int - 9, 1) is distinct from 'refused' then
    raise exception 'an under-13 answer was not refused';
  end if;
  if public.my_call_standing() is distinct from 'refused' then
    raise exception 'an under-13 answer was not remembered (%)', public.my_call_standing();
  end if;

  -- The second try the audit found: an older year.
  begin
    perform public.set_my_birth_month(1990, 5);
    raise exception 'an adult answer was taken after an under-13 one';
  exception when invalid_parameter_value then null;
  end;
  if public.my_call_standing() is distinct from 'refused' then
    raise exception 'a second answer changed a refused standing (%)', public.my_call_standing();
  end if;

  if public.may_join_call('a9e00013-0000-0000-0000-00000000013a')
     is distinct from 'Calls are not available on this account.' then
    raise exception 'a refused account was let in, or asked for a birth month again (%)',
      public.may_join_call('a9e00013-0000-0000-0000-00000000013a');
  end if;
  begin
    perform public.hear_me_in_call('a9e00013-0000-0000-0000-00000000013a', 'phone-u13');
    raise exception 'a refused account was put in a call';
  exception when insufficient_privilege then null;
  end;

  -- Refused outright or read as empty: either way the app cannot read it.
  begin
    if exists (select 1 from private.age_refusals) then
      raise exception 'the record of an under-13 answer is readable from the app';
    end if;
  exception when insufficient_privilege then null;
  end;
end $$;

reset role;
do $$
begin
  if exists (select 1 from private.birth_months
             where person_id = 'a9e00013-0000-0000-0000-000000000138') then
    raise exception 'an under-13 birth month was kept';
  end if;
  if not exists (select 1 from private.age_refusals
                 where person_id = 'a9e00013-0000-0000-0000-000000000138') then
    raise exception 'an under-13 answer left nothing to remember it by';
  end if;
  -- Nowhere to keep a month even by mistake.
  if exists (select 1 from information_schema.columns
             where table_schema = 'private' and table_name = 'age_refusals'
               and column_name not in ('person_id', 'refused_at')) then
    raise exception 'the record of an under-13 answer has room for more than when';
  end if;
end $$;

-- The writer calls the room. Joiner Two is told; the refused account is not.
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';
set local role authenticated;
select public.hear_me_in_call('a9e00013-0000-0000-0000-00000000013a', 'phone-w-age');
select public.leave_call('a9e00013-0000-0000-0000-00000000013a', 'phone-w-age');

reset role;
do $$
begin
  if not exists (select 1 from public.notifications
                 where user_id = '99999999-9999-9999-9999-999999999999'
                   and type = 'call_started'
                   and room_id = 'a9e00013-0000-0000-0000-00000000013a') then
    raise exception 'an adult in the room was not told a call started';
  end if;
  if exists (select 1 from public.notifications
             where user_id = 'a9e00013-0000-0000-0000-000000000138'
               and type = 'call_started') then
    raise exception 'somebody calls are closed to was told about a call';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Lesson links are for adults, for now (0139).
--
-- Every Musician, Same Song, 17 September 2026: adult students first, and
-- lesson links for people 18 and over until there is a guardian step. By
-- here this scenario has exactly the cast that needs: the writer and Joiner
-- Two are adults, Joiner One answered as a 15-year-old, Met At A Gig has
-- never been asked, and Said Under Thirteen is closed to all of it.
--
-- The adult joins; the other three are turned away, each in the words meant
-- for them. The one the app acts on rather than shows -- ask for a birth
-- month -- is checked by its hint, because that is what the app reads.
-- ---------------------------------------------------------------------

reset role;
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';
set local role authenticated;

select public.open_lesson_link('Lessons for grown-ups') as adult_lesson_code \gset
select set_config('smoke.adult_lesson_code', :'adult_lesson_code', true);

-- An adult opens it and gets their room.
set local request.jwt.claims = '{"sub": "99999999-9999-9999-9999-999999999999", "email": "joiner.two@smoke.test"}';

do $$
begin
  if public.join_lesson_link(current_setting('smoke.adult_lesson_code')) is null then
    raise exception 'an adult could not join a lesson link';
  end if;
end $$;

-- A 15-year-old is told plainly, and cannot hang one on a wall either.
set local request.jwt.claims = '{"sub": "88888888-8888-8888-8888-888888888888", "email": "joiner.one@smoke.test"}';

do $$
begin
  begin
    perform public.join_lesson_link(current_setting('smoke.adult_lesson_code'));
    raise exception 'a 15-year-old joined a lesson link';
  exception when invalid_parameter_value then
    if sqlerrm <> 'Lesson links are for people 18 and over for now.' then
      raise exception 'a 15-year-old was turned away for another reason (%)', sqlerrm;
    end if;
  end;

  begin
    perform public.open_lesson_link('Lessons from a 15-year-old');
    raise exception 'a 15-year-old made a lesson link';
  exception when invalid_parameter_value then
    if sqlerrm <> 'Lesson links are for people 18 and over for now.' then
      raise exception 'a 15-year-old was refused a link of their own for another reason (%)', sqlerrm;
    end if;
  end;
end $$;

-- Nobody has asked Met At A Gig anything. The hint is what the app reads, so
-- it is what this checks: a reworded sentence must not stop the question
-- being asked.
set local request.jwt.claims = '{"sub": "c0ec7000-0000-0000-0000-000000000137", "email": "metatagig@smoke.test"}';

do $$
declare
  said text;
begin
  begin
    perform public.join_lesson_link(current_setting('smoke.adult_lesson_code'));
    raise exception 'an account with no birth month joined a lesson link';
  exception when invalid_parameter_value then
    get stacked diagnostics said = pg_exception_hint;
    if said is distinct from 'lesson_birth_month' then
      raise exception 'the app was not told to ask for a birth month (hint %, said %)', said, sqlerrm;
    end if;
  end;

  begin
    perform public.open_lesson_link('Lessons from somebody unasked');
    raise exception 'an account with no birth month made a lesson link';
  exception when invalid_parameter_value then
    get stacked diagnostics said = pg_exception_hint;
    if said is distinct from 'lesson_birth_month' then
      raise exception 'a teacher was not asked for a birth month (hint %, said %)', said, sqlerrm;
    end if;
  end;
end $$;

-- And the account that answered under 13, in 0138's words: one sentence,
-- with no age in it for a second try to be aimed at.
set local request.jwt.claims = '{"sub": "a9e00013-0000-0000-0000-000000000138", "email": "said.under.thirteen@smoke.test"}';

do $$
begin
  begin
    perform public.join_lesson_link(current_setting('smoke.adult_lesson_code'));
    raise exception 'an account that answered under 13 joined a lesson link';
  exception when invalid_parameter_value then
    if sqlerrm <> 'Lesson links are not available on this account.' then
      raise exception 'a refused account was told something else (%)', sqlerrm;
    end if;
  end;
end $$;

reset role;

do $$
begin
  if (select count(*) from public.lesson_rooms r
      join public.lesson_links l on l.id = r.link_id
      where l.code = current_setting('smoke.adult_lesson_code')) <> 1 then
    raise exception 'a lesson link for adults made a room for somebody it turned away';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Notes at a moment (0141).
--
-- Every Musician, Same Song, 17 September 2026. A note is readable and
-- writable by exactly the people who can hear the recording it is pinned to,
-- which under 0057 means an unshared take is a room of one: nobody else can
-- pin on it and nobody else can read what its recorder pinned on it. The
-- recording's player is told, once, and never about their own note.
--
-- In a room of its own, with its own two-person membership, because the
-- bandmate has left room 3333 by this point in the file.
-- ---------------------------------------------------------------------

reset role;
insert into auth.users (id, email, raw_user_meta_data) values
  ('5011e500-0000-0000-0000-000000000141', 'the.student@smoke.test',
   '{"display_name": "The Student"}');

insert into public.rooms (id, account_id, name)
values ('5011e500-0000-0000-0000-00000000014a', :'writer', 'The Lesson Room');

insert into public.room_members (room_id, user_id, display_name, role) values
  ('5011e500-0000-0000-0000-00000000014a', :'writer', 'The Writer', 'owner'),
  ('5011e500-0000-0000-0000-00000000014a', '5011e500-0000-0000-0000-000000000141',
   'The Student', 'editor');

insert into public.projects (id, room_id, account_id, title, created_by)
values ('5011e500-0000-0000-0000-00000000014b', '5011e500-0000-0000-0000-00000000014a',
        :'writer', 'Caro mio ben', :'writer');

-- One take sent, one still the student's own.
insert into public.song_layers
  (id, project_id, recorded_by, storage_path, label, part, duration_ms, shared_at)
values
  ('5011e500-0000-0000-0000-00000000014c', '5011e500-0000-0000-0000-00000000014b',
   '5011e500-0000-0000-0000-000000000141',
   '5011e500-0000-0000-0000-00000000014a/5011e500-0000-0000-0000-00000000014b/layers/sent.m4a',
   'Sent', 'vocal', 132000, now()),
  ('5011e500-0000-0000-0000-00000000014d', '5011e500-0000-0000-0000-00000000014b',
   '5011e500-0000-0000-0000-000000000141',
   '5011e500-0000-0000-0000-00000000014a/5011e500-0000-0000-0000-00000000014b/layers/draft.m4a',
   'Draft', 'vocal', 9000, null);

-- The student pins one on their own draft, which is the row nobody else may
-- ever read, and one on the song's own recording, which the writer made.
set local request.jwt.claims = '{"sub": "5011e500-0000-0000-0000-000000000141", "email": "the.student@smoke.test"}';
set local role authenticated;

do $$
begin
  insert into public.moment_notes (project_id, layer_id, at_ms, body)
  values ('5011e500-0000-0000-0000-00000000014b',
          '5011e500-0000-0000-0000-00000000014d', 4000,
          'the bridge fell apart here');
  -- A null layer is the song's own recording, which the room can hear.
  insert into public.moment_notes (project_id, layer_id, at_ms, end_ms, body)
  values ('5011e500-0000-0000-0000-00000000014b', null, 21000, 27000,
          'is this the piano or me');
end $$;

-- The teacher pins at 1:48 on the take that was sent to them.
reset role;
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';
set local role authenticated;

do $$
declare
  pinned uuid;
begin
  insert into public.moment_notes (project_id, layer_id, at_ms, body)
  values ('5011e500-0000-0000-0000-00000000014b',
          '5011e500-0000-0000-0000-00000000014c', 108000,
          'breathe before mio')
  returning id into pinned;

  if not exists (select 1 from public.moment_notes where id = pinned) then
    raise exception 'a note pinned on a shared take was not readable by its author';
  end if;

  -- The heart of it. A draft is heard by one person, so it is written on and
  -- read by one person -- even by the owner of the room it is in.
  begin
    insert into public.moment_notes (project_id, layer_id, at_ms, body)
    values ('5011e500-0000-0000-0000-00000000014b',
            '5011e500-0000-0000-0000-00000000014d', 1000, 'not mine to say');
    raise exception 'a note was pinned on somebody else''s unshared take';
  exception when insufficient_privilege then null;
  end;

  if exists (
    select 1 from public.moment_notes
    where layer_id = '5011e500-0000-0000-0000-00000000014d'
  ) then
    raise exception 'a note on somebody else''s unshared take was readable';
  end if;

  -- The note on the song's own recording is the room's to read.
  if not exists (
    select 1 from public.moment_notes
    where project_id = '5011e500-0000-0000-0000-00000000014b' and layer_id is null
  ) then
    raise exception 'a note on the song''s own recording was not readable by the room';
  end if;

  -- A note cannot be filed against a song its recording is not on.
  begin
    insert into public.moment_notes (project_id, layer_id, at_ms, body)
    values ('44444444-4444-4444-4444-444444444444',
            '5011e500-0000-0000-0000-00000000014c', 1000, 'wrong song');
    raise exception 'a note was filed against a song its take is not on';
  exception when insufficient_privilege then null;
  end;
end $$;

-- Somebody who is in neither the room nor the song.
reset role;
set local request.jwt.claims = '{"sub": "88888888-8888-8888-8888-888888888888", "email": "joiner.one@smoke.test"}';
set local role authenticated;

do $$
begin
  if exists (
    select 1 from public.moment_notes
    where project_id = '5011e500-0000-0000-0000-00000000014b'
  ) then
    raise exception 'a non-member could read the notes on a song';
  end if;

  begin
    insert into public.moment_notes (project_id, layer_id, at_ms, body)
    values ('5011e500-0000-0000-0000-00000000014b',
            '5011e500-0000-0000-0000-00000000014c', 1000, 'who asked me');
    raise exception 'a non-member pinned a note on a song';
  exception when insufficient_privilege then null;
  end;
end $$;

-- Who was told.
reset role;
do $$
begin
  if not exists (
    select 1 from public.notifications
    where user_id = '5011e500-0000-0000-0000-000000000141'
      and type = 'moment_note'
      and title = 'The Writer left a note at 1:48'
      and project_id = '5011e500-0000-0000-0000-00000000014b'
  ) then
    raise exception 'the person who played the take was not told about the note';
  end if;

  -- The song's own recording belongs to whoever started the song.
  if not exists (
    select 1 from public.notifications
    where user_id = '11111111-1111-1111-1111-111111111111'
      and type = 'moment_note'
      and title = 'The Student left a note at 0:21'
  ) then
    raise exception 'a note on the song''s own recording told nobody';
  end if;

  -- Nobody is told about their own note, including the one the student left
  -- on their own draft.
  if exists (
    select 1 from public.notifications
    where user_id = '5011e500-0000-0000-0000-000000000141'
      and type = 'moment_note'
      and actor_id = '5011e500-0000-0000-0000-000000000141'
  ) then
    raise exception 'somebody was told about their own note';
  end if;
end $$;

-- The author takes their words back, and nobody else can.
set local request.jwt.claims = '{"sub": "5011e500-0000-0000-0000-000000000141", "email": "the.student@smoke.test"}';
set local role authenticated;

do $$
begin
  perform public.delete_moment_note(
    (select id from public.moment_notes
     where layer_id = '5011e500-0000-0000-0000-00000000014c'));
end $$;

reset role;
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';
set local role authenticated;

do $$
declare
  mine uuid;
begin
  select id into mine from public.moment_notes
  where layer_id = '5011e500-0000-0000-0000-00000000014c';
  if mine is null then
    raise exception 'somebody else deleted a note that was not theirs';
  end if;

  perform public.delete_moment_note(mine);
  if exists (select 1 from public.moment_notes where id = mine) then
    raise exception 'an author could not take their own note back';
  end if;
end $$;

reset role;
do $$
begin
  if not exists (
    select 1 from public.moment_notes
    where layer_id = '5011e500-0000-0000-0000-00000000014c'
      and deleted_at is not null
  ) then
    raise exception 'deleting a note did not leave a soft-deleted row';
  end if;
end $$;

-- Sharing a take does not share what its recorder said to themselves.
--
-- The student pinned 'the bridge fell apart here' on their own draft while
-- nobody else could hear it. They are happy with the take now and send it.
-- The take becomes the room's; the note does not.
set local request.jwt.claims = '{"sub": "5011e500-0000-0000-0000-000000000141", "email": "the.student@smoke.test"}';
set local role authenticated;

do $$
begin
  perform public.share_layer('5011e500-0000-0000-0000-00000000014d');

  if not exists (
    select 1 from public.moment_notes
    where layer_id = '5011e500-0000-0000-0000-00000000014d'
      and on_shared_take is false
  ) then
    raise exception 'a note pinned on a draft was not frozen as the author''s own';
  end if;
end $$;

reset role;
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';
set local role authenticated;

do $$
declare
  after_sharing uuid;
begin
  if not exists (
    select 1 from public.song_layers
    where id = '5011e500-0000-0000-0000-00000000014d' and shared_at is not null
  ) then
    raise exception 'the draft was not shared, so this proves nothing';
  end if;

  -- The heart of the fix: the take is audible now, the note still is not.
  if exists (
    select 1 from public.moment_notes
    where layer_id = '5011e500-0000-0000-0000-00000000014d'
  ) then
    raise exception 'sharing a take published the notes its recorder left on it';
  end if;

  -- What is written after the share is the room's, the way a note on any
  -- shared take is -- otherwise the take would be one nobody could discuss.
  insert into public.moment_notes (project_id, layer_id, at_ms, body)
  values ('5011e500-0000-0000-0000-00000000014b',
          '5011e500-0000-0000-0000-00000000014d', 3000, 'much better')
  returning id into after_sharing;

  if not exists (
    select 1 from public.moment_notes
    where id = after_sharing and on_shared_take is true
  ) then
    raise exception 'a note pinned on a shared take was frozen as private';
  end if;
end $$;

reset role;
set local request.jwt.claims = '{"sub": "5011e500-0000-0000-0000-000000000141", "email": "the.student@smoke.test"}';
set local role authenticated;

do $$
begin
  if not exists (
    select 1 from public.moment_notes
    where layer_id = '5011e500-0000-0000-0000-00000000014d'
      and body = 'much better'
  ) then
    raise exception 'the recorder could not read a note left on their shared take';
  end if;

  -- And their own words are still theirs to read.
  if not exists (
    select 1 from public.moment_notes
    where layer_id = '5011e500-0000-0000-0000-00000000014d'
      and body = 'the bridge fell apart here'
  ) then
    raise exception 'an author lost sight of their own note';
  end if;
end $$;

reset role;
-- Whose song is this? (0142).
--
-- One of the two gates in Every Musician, Same Song, 17 September 2026: a
-- song the room did not write never goes in front of people the room never
-- chose, whichever way somebody tries to put it there. Both public surfaces
-- are covered — the Open Mic (0067) and the showcase (0088), which
-- `public_songs` (0096) serves to anon. The functions refuse it, a plain
-- update refuses it, answering late takes a song that is already up back
-- down from either one, somebody who can only look cannot answer for the
-- room, and neither can somebody who is not in it at all.

reset role;
-- Every actor here is made fresh rather than borrowed from earlier in the
-- file. The obvious second account, 22222222-…, calls delete_my_account in
-- the block above, so by this point it is gone from profiles and a
-- room_members row pointing at it cannot be written at all.
insert into auth.users (id, email, raw_user_meta_data) values
  ('50a6e142-0000-0000-0000-000000000146', 'bandmate@smoke.test',
   '{"display_name": "Bandmate"}'),
  ('50a6e142-0000-0000-0000-000000000147', 'onlylooking@smoke.test',
   '{"display_name": "Only Looking"}'),
  -- Never inserted into room_members anywhere. `room_role_for` returns null
  -- for this account, which is the case the `is distinct from` pair in
  -- set_song_origin exists for and the one a `not in` would wave through.
  ('50a6e142-0000-0000-0000-000000000148', 'astranger@smoke.test',
   '{"display_name": "A Stranger"}');

insert into public.rooms (id, account_id, name)
values ('50a6e142-0000-0000-0000-000000000142',
        '11111111-1111-1111-1111-111111111111', 'The Covers Room');

-- Distinct colours, the same as every other room in this file: a room's
-- members are uniquely coloured (room_members_room_color_unique, 0006).
insert into public.room_members (room_id, user_id, display_name, role, color_value) values
  ('50a6e142-0000-0000-0000-000000000142', '11111111-1111-1111-1111-111111111111',
   'The Writer', 'owner', 4294937165),
  ('50a6e142-0000-0000-0000-000000000142', '50a6e142-0000-0000-0000-000000000146',
   'Bandmate', 'editor', 4283215697),
  ('50a6e142-0000-0000-0000-000000000142', '50a6e142-0000-0000-0000-000000000147',
   'Only Looking', 'viewer', 4284000000);

insert into public.projects (id, room_id, account_id, title, created_by) values
  ('50a6e142-0000-0000-0000-00000000014a', '50a6e142-0000-0000-0000-000000000142',
   '11111111-1111-1111-1111-111111111111', 'Somebody Elses',
   '11111111-1111-1111-1111-111111111111'),
  ('50a6e142-0000-0000-0000-00000000014b', '50a6e142-0000-0000-0000-000000000142',
   '11111111-1111-1111-1111-111111111111', 'Ours',
   '11111111-1111-1111-1111-111111111111'),
  ('50a6e142-0000-0000-0000-00000000014c', '50a6e142-0000-0000-0000-000000000142',
   '11111111-1111-1111-1111-111111111111', 'Up Already',
   '11111111-1111-1111-1111-111111111111'),
  ('50a6e142-0000-0000-0000-00000000014d', '50a6e142-0000-0000-0000-000000000142',
   '11111111-1111-1111-1111-111111111111', 'Old Enough',
   '11111111-1111-1111-1111-111111111111'),
  ('50a6e142-0000-0000-0000-00000000014e', '50a6e142-0000-0000-0000-000000000142',
   '11111111-1111-1111-1111-111111111111', 'Shown Already',
   '11111111-1111-1111-1111-111111111111');

set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';
set local role authenticated;

do $$
begin
  -- Null is the fourth state, and it is not the same as 'ours'. A song
  -- arriving with an answer nobody gave would be the app making a claim on
  -- somebody's behalf.
  if (select song_origin from public.projects
        where id = '50a6e142-0000-0000-0000-00000000014a') is not null then
    raise exception 'a new song arrived with an answer nobody gave';
  end if;

  -- Somebody else's song. Refused by the function, with a sentence.
  perform public.set_song_origin('50a6e142-0000-0000-0000-00000000014a', 'cover');
  begin
    perform public.put_on_open_mic('50a6e142-0000-0000-0000-00000000014a');
    raise exception 'a cover was put on the Open Mic';
  exception when insufficient_privilege then null;
  end;

  -- And refused at the table, which is the one that matters: 0005 lets an
  -- owner update this row directly, so a check that lived only in the
  -- function would be one request away from nothing.
  begin
    update public.projects set open_mic_at = now()
    where id = '50a6e142-0000-0000-0000-00000000014a';
    raise exception 'a cover reached the Open Mic through a plain update';
  exception when insufficient_privilege then null;
  end;

  if (select open_mic_at from public.projects
        where id = '50a6e142-0000-0000-0000-00000000014a') is not null then
    raise exception 'a cover is on the Open Mic';
  end if;

  -- And refused the showcase, which is the surface that reaches furthest:
  -- public_songs (0096) is granted to anon, so a showcased song is a page
  -- anybody can open. show_song (0088) also admits anybody in the room,
  -- where put_on_open_mic is the owner only, so this is the looser door.
  begin
    perform public.show_song('50a6e142-0000-0000-0000-00000000014a');
    raise exception 'a cover was put on the showcase';
  exception when insufficient_privilege then null;
  end;

  begin
    update public.projects set showcased_at = now()
    where id = '50a6e142-0000-0000-0000-00000000014a';
    raise exception 'a cover reached the showcase through a plain update';
  exception when insufficient_privilege then null;
  end;

  if (select showcased_at from public.projects
        where id = '50a6e142-0000-0000-0000-00000000014a') is not null then
    raise exception 'a cover is on the showcase';
  end if;

  -- Our own song goes up, which is the whole point of asking.
  perform public.set_song_origin('50a6e142-0000-0000-0000-00000000014b', 'ours');
  perform public.put_on_open_mic('50a6e142-0000-0000-0000-00000000014b');
  if (select open_mic_at from public.projects
        where id = '50a6e142-0000-0000-0000-00000000014b') is null then
    raise exception 'our own song was kept off the Open Mic';
  end if;

  perform public.show_song('50a6e142-0000-0000-0000-00000000014b');
  if (select showcased_at from public.projects
        where id = '50a6e142-0000-0000-0000-00000000014b') is null then
    raise exception 'our own finished song was kept off the showcase';
  end if;

  -- A song that is already up, answered late, comes down with the answer.
  -- The order inside set_song_origin is load-bearing: clearing it in a
  -- second statement would be refused by the trigger.
  perform public.put_on_open_mic('50a6e142-0000-0000-0000-00000000014c');
  perform public.set_song_origin('50a6e142-0000-0000-0000-00000000014c', 'cover');
  if (select open_mic_at from public.projects
        where id = '50a6e142-0000-0000-0000-00000000014c') is not null then
    raise exception 'marking a live song as somebody else''s left it up';
  end if;

  -- The same for a song that is already on the showcase, which is the case
  -- that most needs it: that one is a public page, not a listing inside the
  -- app, and nothing in the app would have said it was still up.
  perform public.show_song('50a6e142-0000-0000-0000-00000000014e');
  perform public.set_song_origin('50a6e142-0000-0000-0000-00000000014e', 'cover');
  if (select showcased_at from public.projects
        where id = '50a6e142-0000-0000-0000-00000000014e') is not null then
    raise exception 'answering late left a cover on the showcase';
  end if;

  -- Finishing is private and survives the answer. A cover a band finished
  -- is still finished; only the two consents are withdrawn.
  if (select finished_at from public.projects
        where id = '50a6e142-0000-0000-0000-00000000014e') is null then
    raise exception 'the answer un-finished a finished song';
  end if;

  -- Three answers, and nothing else.
  begin
    perform public.set_song_origin('50a6e142-0000-0000-0000-00000000014b', 'maybe');
    raise exception 'a fourth answer was accepted';
  exception when invalid_parameter_value then null;
  end;
end $$;

-- An editor can answer. The person who starts a cover in somebody else's
-- catalog is usually the editor, and a question only the owner can answer is
-- one that stays unanswered.
reset role;
set local request.jwt.claims = '{"sub": "50a6e142-0000-0000-0000-000000000146"}';
set local role authenticated;

do $$
begin
  perform public.set_song_origin('50a6e142-0000-0000-0000-00000000014d', 'public_domain');
  if (select song_origin from public.projects
        where id = '50a6e142-0000-0000-0000-00000000014d')
     is distinct from 'public_domain' then
    raise exception 'an editor could not say where a song came from';
  end if;
end $$;

-- Somebody who can only look cannot answer for the room.
reset role;
set local request.jwt.claims = '{"sub": "50a6e142-0000-0000-0000-000000000147"}';
set local role authenticated;

do $$
begin
  begin
    perform public.set_song_origin('50a6e142-0000-0000-0000-00000000014b', 'cover');
    raise exception 'somebody who can only look answered for the room';
  exception when insufficient_privilege then null;
  end;
end $$;

-- And somebody who is not in the room at all, which is the case the
-- null-safety in set_song_origin is actually for. The viewer above has a
-- role, so `not in ('owner', 'editor')` would still refuse them — this
-- account has no role, `null not in (...)` is null, and the plain form would
-- let a stranger with any valid token flip a room's answer and unlock the
-- Open Mic on a song they have never seen.
reset role;
set local request.jwt.claims = '{"sub": "50a6e142-0000-0000-0000-000000000148"}';
set local role authenticated;

do $$
begin
  begin
    perform public.set_song_origin('50a6e142-0000-0000-0000-00000000014c', 'ours');
    raise exception 'somebody outside the room answered for it';
  exception when insufficient_privilege then null;
  end;
end $$;

reset role;
do $$
begin
  if (select song_origin from public.projects
        where id = '50a6e142-0000-0000-0000-00000000014b') is distinct from 'ours' then
    raise exception 'a viewer changed whose song it is';
  end if;
  if (select open_mic_at from public.projects
        where id = '50a6e142-0000-0000-0000-00000000014b') is null then
    raise exception 'a viewer took our own song off the Open Mic';
  end if;
  -- The stranger's attempt left the cover a cover, and off the Open Mic.
  if (select song_origin from public.projects
        where id = '50a6e142-0000-0000-0000-00000000014c') is distinct from 'cover' then
    raise exception 'somebody outside the room changed whose song it is';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- An ask says whether answering means playing or writing (0145).
--
-- Every Musician, Same Song, 17 September 2026: co-writing fights are two
-- honest memories of a session nobody wrote down. The terms are chosen when
-- the ask is sent, they travel with the brief to the person deciding, and
-- nothing afterwards can change them — which is the whole of their value.
--
-- In a room of its own, with a musician nobody else in this file has met, so
-- the one-open-ask-per-person index and the blocks earlier in the file are
-- both out of the way.
-- ---------------------------------------------------------------------

reset role;
insert into auth.users (id, email, raw_user_meta_data) values
  ('7e1a5000-0000-0000-0000-000000000145', 'the.co.writer@smoke.test',
   '{"display_name": "The Co-writer"}');

insert into public.rooms (id, account_id, name)
values ('7e1a5000-0000-0000-0000-00000000014a', :'writer', 'The Writing Room');

insert into public.room_members (room_id, user_id, display_name, role) values
  ('7e1a5000-0000-0000-0000-00000000014a', :'writer', 'The Writer', 'owner');

insert into public.projects (id, room_id, account_id, title, created_by) values
  ('7e1a5000-0000-0000-0000-00000000014b', '7e1a5000-0000-0000-0000-00000000014a',
   :'writer', 'Two Memories', :'writer'),
  ('7e1a5000-0000-0000-0000-00000000014c', '7e1a5000-0000-0000-0000-00000000014a',
   :'writer', 'A Favour', :'writer');

set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';
set local role authenticated;

-- The asks themselves, sent the way the app sends them: through the RPC, as
-- the person asking. Only the function is called here. Reading the table back
-- belongs below, because the shim (00_shim.sql) stands `authenticated` up as
-- a bare role and grants it nothing on public tables, so a direct select here
-- would fail for want of a grant long before any policy was consulted.
do $$
begin
  perform public.ask_musician(
    '7e1a5000-0000-0000-0000-00000000014b',
    '7e1a5000-0000-0000-0000-000000000145',
    'topline', 'Second verse is yours if you want it.', 'write');

  -- Four arguments is what every client sent before this migration, and what
  -- the room's own ask bar still means: playing.
  perform public.ask_musician(
    '7e1a5000-0000-0000-0000-00000000014c',
    '7e1a5000-0000-0000-0000-000000000145',
    'bass', '');

  -- Two words, and no third one.
  begin
    perform public.ask_musician(
      '7e1a5000-0000-0000-0000-00000000014b',
      '7e1a5000-0000-0000-0000-000000000145',
      'keys', '', 'produce');
    raise exception 'a third kind of terms was accepted';
  exception when invalid_parameter_value then null;
  end;
end $$;

-- What was written down, and what nothing can change.
--
-- As the table's owner rather than as the asker. The rule lives on the table,
-- so the owner is the strongest case there is: if the role that owns
-- project_asks cannot rewrite what an ask meant, nobody arriving through
-- PostgREST can either. Running this as `authenticated` would look more like
-- the asker and prove less -- the shim would refuse the update for a missing
-- grant, and the block would pass without the trigger ever firing.
reset role;
do $$
declare
  written uuid;
  played uuid;
begin
  select id into written from public.project_asks
  where project_id = '7e1a5000-0000-0000-0000-00000000014b'
    and part = 'topline';
  select id into played from public.project_asks
  where project_id = '7e1a5000-0000-0000-0000-00000000014c'
    and part = 'bass';

  if written is null or played is null then
    raise exception 'the asks were not written';
  end if;

  if (select terms from public.project_asks where id = written)
     is distinct from 'write' then
    raise exception 'the ask did not carry the terms it was sent with (got %)',
      (select terms from public.project_asks where id = written);
  end if;

  if (select terms from public.project_asks where id = played)
     is distinct from 'play' then
    raise exception 'an ask made without terms was not a playing ask (got %)',
      (select terms from public.project_asks where id = played);
  end if;

  -- Settled when it was sent.
  begin
    update public.project_asks set terms = 'play' where id = written;
    raise exception 'the terms of an ask were rewritten afterwards';
  exception when insufficient_privilege then null;
  end;

  if (select terms from public.project_asks where id = written)
     is distinct from 'write' then
    raise exception 'the terms of an ask changed under an update that failed';
  end if;

  -- Closing one still works, which is the update this trigger sees most: it
  -- names status and closed_at and never mentions terms.
  update public.project_asks
  set status = 'closed', closed_at = now()
  where id = played;

  if (select status from public.project_asks where id = played)
     is distinct from 'closed' then
    raise exception 'the terms trigger refused an ordinary close';
  end if;
end $$;

-- The person asked reads it with the rest of the brief, before answering and
-- before recording anything.
reset role;
set local request.jwt.claims = '{"sub": "7e1a5000-0000-0000-0000-000000000145"}';
set local role authenticated;

do $$
declare
  mine record;
begin
  select * into mine from public.asks_for_me()
  where project_id = '7e1a5000-0000-0000-0000-00000000014b';

  if mine.id is null then
    raise exception 'the co-writer was shown nothing';
  end if;
  if mine.terms is distinct from 'write' then
    raise exception 'the brief did not say what answering means (got %)',
      mine.terms;
  end if;

  -- The person asked cannot change it either, and for two reasons at once:
  -- no update policy admits them, and the trigger refuses the column to
  -- everybody including the role that owns the table. The owner is checked
  -- above and is the stronger case, so there is nothing left to run as them
  -- here that the shim would not refuse for a missing grant first.
end $$;

reset role;
do $$
begin
  if (select terms from public.project_asks
        where project_id = '7e1a5000-0000-0000-0000-00000000014b'
          and part = 'topline') is distinct from 'write' then
    raise exception 'what answering meant did not survive being read';
  end if;

  -- What the ask says first. This row is the push on the phone and the line
  -- drawn in the inbox's Activity list under the ask's own card, and it is
  -- the one surface the sentence cannot be scrolled into view on. A write ask
  -- that announced itself as playing would be the contradiction arriving
  -- first and loudest.
  if not exists (
    select 1 from public.notifications
    where type = 'song_ask'
      and user_id = '7e1a5000-0000-0000-0000-000000000145'
      and project_id = '7e1a5000-0000-0000-0000-00000000014b'
      and title = 'The Writer asked you to write on topline'
  ) then
    raise exception 'a write ask announced itself as something else (got %)',
      (select title from public.notifications
       where type = 'song_ask'
         and project_id = '7e1a5000-0000-0000-0000-00000000014b');
  end if;

  -- And playing still says exactly what it said before this migration.
  if not exists (
    select 1 from public.notifications
    where type = 'song_ask'
      and user_id = '7e1a5000-0000-0000-0000-000000000145'
      and project_id = '7e1a5000-0000-0000-0000-00000000014c'
      and title = 'The Writer asked you to play bass'
  ) then
    raise exception 'a playing ask stopped saying what it always said (got %)',
      (select title from public.notifications
       where type = 'song_ask'
         and project_id = '7e1a5000-0000-0000-0000-00000000014c');
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Leave it for the student (0143).
--
-- A teacher leaves practice on a song in their own lesson room without a
-- live session. It lands as a mark the student owns and the teacher cannot
-- read back, leaving again replaces it rather than piling up, and everybody
-- else -- a band room's owner, the student themselves, somebody outside --
-- is refused.
-- ---------------------------------------------------------------------

reset role;

-- Made fresh rather than borrowed. The accounts earlier in this file are
-- already teachers, students and blockers of each other by this point, and a
-- refusal that happened for one of those older reasons would look exactly
-- like the refusal this block is checking.
insert into auth.users (id, email, raw_user_meta_data) values
  -- Spelled "guitar" because 0141's block further up this file already has a
  -- the.student@smoke.test, and an address is one account (00_shim.sql).
  ('1ea50143-0000-0000-0000-000000000143', 'the.guitar.teacher@smoke.test',
   '{"display_name": "The Teacher"}'),
  ('1ea50143-0000-0000-0000-000000000144', 'the.guitar.student@smoke.test',
   '{"display_name": "The Student"}'),
  ('1ea50143-0000-0000-0000-000000000145', 'the.band.owner@smoke.test',
   '{"display_name": "The Band Owner"}'),
  -- A real account with a real token and nothing to do with any of this: in
  -- no room here, in no lesson here, and not the student of anybody. The
  -- `is distinct from` null path is not this account -- the lesson_rooms
  -- guard above it refuses them first -- and is reached further down by a
  -- room the teacher is genuinely a teacher of and genuinely not in.
  ('1ea50143-0000-0000-0000-000000000146', 'outside.the.lesson@smoke.test',
   '{"display_name": "Outside The Lesson"}');

insert into public.rooms (id, account_id, name) values
  ('1ea50143-0000-0000-0000-00000000014a',
   '1ea50143-0000-0000-0000-000000000143', 'Guitar lessons · The Student'),
  ('1ea50143-0000-0000-0000-00000000014b',
   '1ea50143-0000-0000-0000-000000000145', 'The Band Room');

-- Distinct colours, as every other room in this file: a room's members are
-- uniquely coloured (room_members_room_color_unique, 0006).
insert into public.room_members (room_id, user_id, display_name, role, color_value) values
  ('1ea50143-0000-0000-0000-00000000014a', '1ea50143-0000-0000-0000-000000000143',
   'The Teacher', 'owner', 4294937166),
  ('1ea50143-0000-0000-0000-00000000014a', '1ea50143-0000-0000-0000-000000000144',
   'The Student', 'editor', 4283215698),
  -- The student is in the band room too, so the refusal below is about the
  -- room not being a lesson rather than about them not being there.
  ('1ea50143-0000-0000-0000-00000000014b', '1ea50143-0000-0000-0000-000000000145',
   'The Band Owner', 'owner', 4294937167),
  ('1ea50143-0000-0000-0000-00000000014b', '1ea50143-0000-0000-0000-000000000144',
   'The Student', 'editor', 4283215699);

insert into public.projects (id, room_id, account_id, title, created_by) values
  ('1ea50143-0000-0000-0000-00000000014c', '1ea50143-0000-0000-0000-00000000014a',
   '1ea50143-0000-0000-0000-000000000143', 'Caro Mio Ben',
   '1ea50143-0000-0000-0000-000000000143'),
  ('1ea50143-0000-0000-0000-00000000014d', '1ea50143-0000-0000-0000-00000000014b',
   '1ea50143-0000-0000-0000-000000000145', 'The Band Song',
   '1ea50143-0000-0000-0000-000000000145');

-- The lesson itself. Written here rather than through join_lesson_link
-- because what is being checked is 0143's guard, not 0129's flow -- and the
-- link is deliberately already closed, to hold the rule that a teacher who
-- took their poster down still teaches the people who scanned it.
insert into public.lesson_links (id, teacher_id, code, title, closed_at) values
  ('1ea50143-0000-0000-0000-00000000014e', '1ea50143-0000-0000-0000-000000000143',
   '0143aaaabbbb', 'Guitar lessons', now());
insert into public.lesson_rooms (link_id, student_id, room_id) values
  ('1ea50143-0000-0000-0000-00000000014e', '1ea50143-0000-0000-0000-000000000144',
   '1ea50143-0000-0000-0000-00000000014a');

set local request.jwt.claims = '{"sub": "1ea50143-0000-0000-0000-000000000143"}';
set local role authenticated;

do $$
declare
  left_mark uuid;
  again uuid;
begin
  left_mark := public.leave_practice_mark(
    '1ea50143-0000-0000-0000-00000000014c',
    '1ea50143-0000-0000-0000-000000000144',
    'Chorus 2', 0.75, 41000, 58000,
    'Keep it slow until the change is clean.');
  if left_mark is null then
    raise exception 'leaving practice left nothing';
  end if;

  -- The half of this that matters most: the teacher wrote it and cannot see
  -- it. Practice is where people are allowed to be bad at things.
  if exists (select 1 from public.practice_marks) then
    raise exception 'a teacher can read the student''s practice marks';
  end if;
  if exists (select 1 from public.my_practice_marks()) then
    raise exception 'a mark left for a student came back to the teacher';
  end if;

  -- Again on the same song is the same mark, brought up to date, and this
  -- one carries no note: the teacher left the words off deliberately.
  again := public.leave_practice_mark(
    '1ea50143-0000-0000-0000-00000000014c',
    '1ea50143-0000-0000-0000-000000000144',
    'Verse 1', 0.5, null, null, null);
  if again is distinct from left_mark then
    raise exception 'leaving practice again made a second mark';
  end if;

  -- Somebody who is not their student, in the room or out of it.
  begin
    perform public.leave_practice_mark(
      '1ea50143-0000-0000-0000-00000000014c',
      '1ea50143-0000-0000-0000-000000000146',
      'Chorus 2', 1, null, null, null);
    raise exception 'a teacher left practice for somebody who is not their student';
  exception when insufficient_privilege then null;
  end;

  -- A song that is not in the lesson.
  begin
    perform public.leave_practice_mark(
      '1ea50143-0000-0000-0000-00000000014d',
      '1ea50143-0000-0000-0000-000000000144',
      'Chorus 2', 1, null, null, null);
    raise exception 'a teacher left practice on a song outside the lesson';
  exception when insufficient_privilege then null;
  end;

  -- Nothing in it at all. `student_id = null` matches no row rather than
  -- every row, and the refusal is said before anything is looked up.
  begin
    perform public.leave_practice_mark(
      '1ea50143-0000-0000-0000-00000000014c', null,
      'Chorus 2', 1, null, null, null);
    raise exception 'a call with nobody in it left practice';
  exception when insufficient_privilege then null;
  end;

  -- And the shapes the app would never send.
  begin
    perform public.leave_practice_mark(
      '1ea50143-0000-0000-0000-00000000014c',
      '1ea50143-0000-0000-0000-000000000144',
      'Chorus 2', 9, null, null, null);
    raise exception 'practice was left at a speed nobody could play';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.leave_practice_mark(
      '1ea50143-0000-0000-0000-00000000014c',
      '1ea50143-0000-0000-0000-000000000144',
      '   ', 1, null, null, null);
    raise exception 'practice was left pointing at nothing';
  exception when invalid_parameter_value then null;
  end;
end $$;

-- A band room's owner is not a teacher, and the same call in a band room
-- would be one member writing on another member's Home.
reset role;
set local request.jwt.claims = '{"sub": "1ea50143-0000-0000-0000-000000000145"}';
set local role authenticated;

do $$
begin
  begin
    perform public.leave_practice_mark(
      '1ea50143-0000-0000-0000-00000000014d',
      '1ea50143-0000-0000-0000-000000000144',
      'Chorus 2', 1, null, null, null);
    raise exception 'a band room owner left practice on one of their members';
  exception when insufficient_privilege then null;
  end;

  -- And on the lesson's song, which they have no role in at all.
  begin
    perform public.leave_practice_mark(
      '1ea50143-0000-0000-0000-00000000014c',
      '1ea50143-0000-0000-0000-000000000144',
      'Chorus 2', 1, null, null, null);
    raise exception 'somebody outside the lesson left practice in it';
  exception when insufficient_privilege then null;
  end;
end $$;

-- The student can read what was left for them, and can leave nothing for
-- anybody: the lesson runs one way.
reset role;
set local request.jwt.claims = '{"sub": "1ea50143-0000-0000-0000-000000000144"}';
set local role authenticated;

do $$
begin
  if (select count(*) from public.my_practice_marks()) <> 1 then
    raise exception 'the student does not have exactly one mark left for them';
  end if;
  if (select led_by from public.practice_marks)
     is distinct from '1ea50143-0000-0000-0000-000000000143'::uuid then
    raise exception 'the mark does not say who left it';
  end if;
  if (select led_by_name from public.practice_marks) <> 'The Teacher' then
    raise exception 'the mark does not carry the teacher''s name';
  end if;
  if (select parts -> 0 ->> 'label' from public.practice_marks) <> 'Verse 1' then
    raise exception 'leaving practice again did not replace what it pointed at';
  end if;
  if (select (parts -> 0 ->> 'rate')::numeric from public.practice_marks) <> 0.5 then
    raise exception 'leaving practice again did not replace the speed';
  end if;
  -- Unlike keep_practice_mark's upsert, which protects a teacher's words
  -- from a student's phone. This is the teacher themselves, and a note they
  -- deliberately left off comes off.
  if (select note from public.practice_marks) is not null then
    raise exception 'a note the teacher took off stayed on';
  end if;

  begin
    perform public.leave_practice_mark(
      '1ea50143-0000-0000-0000-00000000014c',
      '1ea50143-0000-0000-0000-000000000144',
      'Chorus 2', 1, null, null, null);
    raise exception 'a student left practice for themselves';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.leave_practice_mark(
      '1ea50143-0000-0000-0000-00000000014c',
      '1ea50143-0000-0000-0000-000000000143',
      'Chorus 2', 1, null, null, null);
    raise exception 'a student left practice for their teacher';
  exception when insufficient_privilege then null;
  end;
end $$;

-- Somebody with a valid token and nothing to do with any of it.
reset role;
set local request.jwt.claims = '{"sub": "1ea50143-0000-0000-0000-000000000146"}';
set local role authenticated;

do $$
begin
  if exists (select 1 from public.practice_marks) then
    raise exception 'a stranger can read somebody''s practice marks';
  end if;
  begin
    perform public.leave_practice_mark(
      '1ea50143-0000-0000-0000-00000000014c',
      '1ea50143-0000-0000-0000-000000000144',
      'Chorus 2', 1, null, null, null);
    raise exception 'a stranger left practice on somebody''s Home';
  exception when insufficient_privilege then null;
  end;
end $$;

reset role;

do $$
begin
  -- One mark, not three: every refusal above left the table where it was.
  if (select count(*) from public.practice_marks
      where profile_id = '1ea50143-0000-0000-0000-000000000144') <> 1 then
    raise exception 'the refusals left practice marks behind';
  end if;

  -- And the student was told, through the switch that already covers
  -- somebody else doing something to one of their songs.
  if private.wants_project_updates('1ea50143-0000-0000-0000-000000000144')
     and not exists (
       select 1 from public.notifications
       where user_id = '1ea50143-0000-0000-0000-000000000144'
         and type = 'project_update'
         and project_id = '1ea50143-0000-0000-0000-00000000014c'
         and actor_id = '1ea50143-0000-0000-0000-000000000143'
     ) then
    raise exception 'the student was not told their teacher left them something';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- The marks a lesson already left, folded in rather than left beside.
--
-- keep_practice_mark names a mark per followed stretch (0128) and the phone
-- makes a fresh name each time, so a student who followed this teacher on
-- this song is already carrying a row of their own led by them -- with the
-- teacher's parting words on it. Home shows one card a song and prefers
-- whichever mark carries words, so a row like this left behind speaks over
-- the practice just left, and the student practises last week's part.
--
-- Written straight into the table, because keep_practice_mark writes as the
-- student's own phone; the row is the one it would make.
-- ---------------------------------------------------------------------

reset role;

insert into public.practice_marks
  (id, profile_id, project_id, led_by, led_by_name, note, parts, updated_at)
values (
  '1ea50143-0000-0000-0000-00000000014f',
  '1ea50143-0000-0000-0000-000000000144',
  '1ea50143-0000-0000-0000-00000000014c',
  '1ea50143-0000-0000-0000-000000000143',
  'The Teacher',
  'Keep it slow until the change is clean.',
  '[{"start": 41000, "end": 58000, "label": "Chorus 1", "rate": 0.5, "seconds": 900}]'::jsonb,
  -- Older than the one leaving practice will bring up to date, which is the
  -- order that bites: the newest row is the one that gets the new words, and
  -- this one keeps the old ones.
  now() - interval '1 hour');

set local request.jwt.claims = '{"sub": "1ea50143-0000-0000-0000-000000000143"}';
set local role authenticated;

do $$
begin
  perform public.leave_practice_mark(
    '1ea50143-0000-0000-0000-00000000014c',
    '1ea50143-0000-0000-0000-000000000144',
    'Bridge', 1, null, null, null);
end $$;

reset role;

do $$
begin
  if (select count(*) from public.practice_marks
      where profile_id = '1ea50143-0000-0000-0000-000000000144'
        and project_id = '1ea50143-0000-0000-0000-00000000014c'
        and led_by = '1ea50143-0000-0000-0000-000000000143') <> 1 then
    raise exception 'a mark this teacher led was left beside the one they just left';
  end if;
  if (select parts -> 0 ->> 'label' from public.practice_marks
      where profile_id = '1ea50143-0000-0000-0000-000000000144'
        and project_id = '1ea50143-0000-0000-0000-00000000014c') <> 'Bridge' then
    raise exception 'the mark that survived is not the practice just left';
  end if;
  -- The one that went was the one with the words on it, so nothing is left
  -- for Home to prefer over what the teacher actually said this time.
  if (select note from public.practice_marks
      where profile_id = '1ea50143-0000-0000-0000-000000000144'
        and project_id = '1ea50143-0000-0000-0000-00000000014c') is not null then
    raise exception 'an older lesson''s words outlived the practice left after them';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- A lesson of theirs, in a room that is not theirs.
--
-- The one call that gets past the lesson_rooms guard and reaches the role
-- check with nothing to check: the link is this teacher's, the student is
-- this student, and the teacher is not a member of the room the lesson was
-- pointed at. room_role_for answers null, `null <> 'owner'` is null, and an
-- `if` on null does nothing -- so a plain `<>` here would wave this through
-- and let somebody write on a Home in a room they are not in. This is the
-- case `is distinct from` is spelled out for.
-- ---------------------------------------------------------------------

reset role;

insert into public.rooms (id, account_id, name) values
  ('1ea50143-0000-0000-0000-000000000150',
   '1ea50143-0000-0000-0000-000000000145', 'Somebody Else''s Room');

insert into public.room_members (room_id, user_id, display_name, role, color_value) values
  ('1ea50143-0000-0000-0000-000000000150', '1ea50143-0000-0000-0000-000000000145',
   'The Band Owner', 'owner', 4294937168),
  ('1ea50143-0000-0000-0000-000000000150', '1ea50143-0000-0000-0000-000000000144',
   'The Student', 'editor', 4283215700);

insert into public.projects (id, room_id, account_id, title, created_by) values
  ('1ea50143-0000-0000-0000-000000000151', '1ea50143-0000-0000-0000-000000000150',
   '1ea50143-0000-0000-0000-000000000145', 'A Song Elsewhere',
   '1ea50143-0000-0000-0000-000000000145');

-- A second link of the teacher's, also closed, so the one-open-link-per-
-- teacher index (0129) is not the thing being tested here.
insert into public.lesson_links (id, teacher_id, code, title, closed_at) values
  ('1ea50143-0000-0000-0000-000000000152', '1ea50143-0000-0000-0000-000000000143',
   '0143ccccdddd', 'Guitar lessons, elsewhere', now());
insert into public.lesson_rooms (link_id, student_id, room_id) values
  ('1ea50143-0000-0000-0000-000000000152', '1ea50143-0000-0000-0000-000000000144',
   '1ea50143-0000-0000-0000-000000000150');

set local request.jwt.claims = '{"sub": "1ea50143-0000-0000-0000-000000000143"}';
set local role authenticated;

do $$
begin
  begin
    perform public.leave_practice_mark(
      '1ea50143-0000-0000-0000-000000000151',
      '1ea50143-0000-0000-0000-000000000144',
      'Chorus 2', 1, null, null, null);
    raise exception 'a teacher left practice in a room they are not a member of';
  exception when insufficient_privilege then null;
  end;
end $$;

reset role;

do $$
begin
  if exists (select 1 from public.practice_marks
             where project_id = '1ea50143-0000-0000-0000-000000000151') then
    raise exception 'the refused call wrote a mark anyway';
  end if;
end $$;

set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';

-- ---------------------------------------------------------------------
-- This is the 1 (0144).
--
-- Key detection knows major and minor only, so a Mixolydian song or one that
-- opens on its IV gets named by the wrong chord -- and the numbers, the
-- scale and the capo chart are all counted from it. The band can say where
-- the 1 really is. It is a shared fact and not a reading: a person's
-- transpose and capo are theirs, and this one changes what everybody's
-- numbers mean, so an editor can set it, somebody who can only look cannot,
-- and neither can somebody who is not in the room at all.

reset role;
insert into auth.users (id, email, raw_user_meta_data) values
  ('7e401440-0000-0000-0000-000000000146', 'thebassist@smoke.test',
   '{"display_name": "The Bassist"}'),
  ('7e401440-0000-0000-0000-000000000147', 'justlistening@smoke.test',
   '{"display_name": "Just Listening"}'),
  -- Never inserted into room_members anywhere. room_role_for returns null for
  -- this account, which is the case the `is distinct from` pair in
  -- set_song_key exists for and the one a `not in` would wave through.
  ('7e401440-0000-0000-0000-000000000148', 'nobodyshere@smoke.test',
   '{"display_name": "Nobody From Here"}');

insert into public.rooms (id, account_id, name)
values ('7e401440-0000-0000-0000-000000000144',
        '11111111-1111-1111-1111-111111111111', 'The Modal Room');

-- Distinct colours, the same as every other room in this file: a room's
-- members are uniquely coloured (room_members_room_color_unique, 0006).
insert into public.room_members (room_id, user_id, display_name, role, color_value) values
  ('7e401440-0000-0000-0000-000000000144', '11111111-1111-1111-1111-111111111111',
   'The Writer', 'owner', 4294937165),
  ('7e401440-0000-0000-0000-000000000144', '7e401440-0000-0000-0000-000000000146',
   'The Bassist', 'editor', 4283215697),
  ('7e401440-0000-0000-0000-000000000144', '7e401440-0000-0000-0000-000000000147',
   'Just Listening', 'viewer', 4284000000);

insert into public.projects (id, room_id, account_id, title, created_by) values
  ('7e401440-0000-0000-0000-00000000014a', '7e401440-0000-0000-0000-000000000144',
   '11111111-1111-1111-1111-111111111111', 'Mixolydian One',
   '11111111-1111-1111-1111-111111111111'),
  ('7e401440-0000-0000-0000-00000000014b', '7e401440-0000-0000-0000-000000000144',
   '11111111-1111-1111-1111-111111111111', 'Starts On The Four',
   '11111111-1111-1111-1111-111111111111');

set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';
set local role authenticated;

do $$
begin
  -- Null is the honest default: nobody has corrected anything, and the
  -- detected key stands.
  if (select key_override from public.projects
        where id = '7e401440-0000-0000-0000-00000000014a') is not null then
    raise exception 'a new song arrived with a key nobody gave it';
  end if;

  perform public.set_song_key('7e401440-0000-0000-0000-00000000014a', 'A minor');
  if (select key_override from public.projects
        where id = '7e401440-0000-0000-0000-00000000014a')
     is distinct from 'A minor' then
    raise exception 'the owner could not say what key the song is in';
  end if;

  -- A bare root is a key too: that is what a bare letter means on a chart.
  perform public.set_song_key('7e401440-0000-0000-0000-00000000014b', 'Bb');
  if (select key_override from public.projects
        where id = '7e401440-0000-0000-0000-00000000014b')
     is distinct from 'Bb' then
    raise exception 'a bare root was not accepted as a key';
  end if;

  -- Null clears it, which is how "Use the detected key" is spelled. It is a
  -- real answer and not a missing argument, so it is not an error.
  perform public.set_song_key('7e401440-0000-0000-0000-00000000014b', null);
  if (select key_override from public.projects
        where id = '7e401440-0000-0000-0000-00000000014b') is not null then
    raise exception 'the detected key could not be asked for again';
  end if;

  -- And so does whitespace, so the app cannot leave a blank standing in for
  -- a key by sending an empty box.
  perform public.set_song_key('7e401440-0000-0000-0000-00000000014b', '   ');
  if (select key_override from public.projects
        where id = '7e401440-0000-0000-0000-00000000014b') is not null then
    raise exception 'a blank was stored as a key';
  end if;

  -- Keys, and nothing else. A free-text scale or tradition name is a later,
  -- separate piece; storing one here would have the sheet counting numbers
  -- from something that has none.
  begin
    perform public.set_song_key('7e401440-0000-0000-0000-00000000014a',
                                'Raag Yaman');
    raise exception 'something that is not a key was accepted';
  exception when invalid_parameter_value then null;
  end;

  begin
    perform public.set_song_key('7e401440-0000-0000-0000-00000000014a',
                                'H major');
    raise exception 'a note that does not exist was accepted';
  exception when invalid_parameter_value then null;
  end;

  -- The check constraint says the same thing at the table, because 0005 lets
  -- an owner update this row directly and a rule that lives only in a
  -- function is one request away from nothing.
  begin
    update public.projects set key_override = 'Mixolydian'
    where id = '7e401440-0000-0000-0000-00000000014a';
    raise exception 'a plain update stored something that is not a key';
  exception when check_violation then null;
  end;
end $$;

-- An editor can say it. It is usually the player who noticed the numbers
-- were wrong, not the person who owns the catalog.
reset role;
set local request.jwt.claims = '{"sub": "7e401440-0000-0000-0000-000000000146"}';
set local role authenticated;

do $$
begin
  perform public.set_song_key('7e401440-0000-0000-0000-00000000014b', 'G major');
  if (select key_override from public.projects
        where id = '7e401440-0000-0000-0000-00000000014b')
     is distinct from 'G major' then
    raise exception 'an editor could not say what key the song is in';
  end if;
end $$;

-- Somebody who can only look cannot move everybody else's numbers.
reset role;
set local request.jwt.claims = '{"sub": "7e401440-0000-0000-0000-000000000147"}';
set local role authenticated;

do $$
begin
  begin
    perform public.set_song_key('7e401440-0000-0000-0000-00000000014a', 'C major');
    raise exception 'somebody who can only look answered for the room';
  exception when insufficient_privilege then null;
  end;
end $$;

-- And somebody who is not in the room at all, which is the case the
-- null-safety in set_song_key is actually for. The viewer above has a role,
-- so `not in ('owner', 'editor')` would still refuse them -- this account has
-- no role, `null not in (...)` is null, and the plain form would let a
-- stranger with any valid token move a room's song into another key.
reset role;
set local request.jwt.claims = '{"sub": "7e401440-0000-0000-0000-000000000148"}';
set local role authenticated;

do $$
begin
  begin
    perform public.set_song_key('7e401440-0000-0000-0000-00000000014a', 'C major');
    raise exception 'somebody outside the room answered for it';
  exception when insufficient_privilege then null;
  end;
end $$;

reset role;
do $$
begin
  if (select key_override from public.projects
        where id = '7e401440-0000-0000-0000-00000000014a')
     is distinct from 'A minor' then
    raise exception 'somebody who cannot edit changed the song''s key';
  end if;
  if (select key_override from public.projects
        where id = '7e401440-0000-0000-0000-00000000014b')
     is distinct from 'G major' then
    raise exception 'the editor''s answer did not stand';
  end if;
end $$;

-- Tonight names its chord in the key the band said. The card suggests "a
-- chord of the key this song has never reached for", so it has to be the
-- band's key and not the analyser's -- 0144 restates tonight() from 0121 with
-- the override in front. The bassist is in this one room only, and only the
-- first song here has a recording and chords, so it is the song Tonight
-- picks for them.
insert into public.files (id, project_id, uploaded_by, storage_path, display_name, mime_type)
values ('7e401440-0000-0000-0000-0000000001f1', '7e401440-0000-0000-0000-00000000014a',
        '11111111-1111-1111-1111-111111111111',
        'smoke/modal/reference.mp3', 'reference.mp3', 'audio/mpeg');

insert into public.project_audio_references
  (project_id, file_id, uploaded_by, analysis_state, musical_key)
values ('7e401440-0000-0000-0000-00000000014a', '7e401440-0000-0000-0000-0000000001f1',
        '11111111-1111-1111-1111-111111111111', 'ready', 'C major');

insert into public.chord_cues (project_id, start_ms, end_ms, chord)
values ('7e401440-0000-0000-0000-00000000014a', 0, 2000, 'A:min'),
       ('7e401440-0000-0000-0000-00000000014a', 2000, 4000, 'G:maj');

set local request.jwt.claims = '{"sub": "7e401440-0000-0000-0000-000000000146"}';
set local role authenticated;

do $$
declare
  said text;
begin
  select song_key into said from public.tonight() limit 1;
  if said is distinct from 'A minor' then
    raise exception 'Tonight named a chord in the heard key (%), not the band''s', said;
  end if;
end $$;

reset role;

-- ---------------------------------------------------------------------
-- A line you cut goes back to whoever wrote it (0153).
--
-- A line taken out of a song is cut, never deleted: the row stays with
-- deleted_at set, leaves the song for everybody, and only its writer can
-- read it again, through lines_you_cut. The person who cut it keeps
-- nothing. Anybody who can edit the song can cut a line; somebody who can
-- only look cannot, and neither can somebody who is not in the room at all,
-- which is the null-role case the coalesce in cut_line exists for.
-- ---------------------------------------------------------------------

reset role;
insert into auth.users (id, email, raw_user_meta_data) values
  ('cc153000-0000-0000-0000-000000000001', 'thecowriter@smoke.test',
   '{"display_name": "The Co-writer"}'),
  -- Not 'onlylooking@': 0147's block already has that address, and
  -- auth.users keeps emails unique.
  ('cc153000-0000-0000-0000-000000000002', 'only.looking.here@smoke.test',
   '{"display_name": "Only Looking"}'),
  -- Never inserted into room_members anywhere.
  ('cc153000-0000-0000-0000-000000000003', 'notinthisroom@smoke.test',
   '{"display_name": "Not In This Room"}');

insert into public.rooms (id, account_id, name)
values ('cc153000-0000-0000-0000-000000000010',
        '11111111-1111-1111-1111-111111111111', 'The Cutting Room');

insert into public.room_members (room_id, user_id, display_name, role, color_value) values
  ('cc153000-0000-0000-0000-000000000010', '11111111-1111-1111-1111-111111111111',
   'The Writer', 'owner', 4294937166),
  ('cc153000-0000-0000-0000-000000000010', 'cc153000-0000-0000-0000-000000000001',
   'The Co-writer', 'editor', 4283215698),
  ('cc153000-0000-0000-0000-000000000010', 'cc153000-0000-0000-0000-000000000002',
   'Only Looking', 'viewer', 4284000001);

insert into public.projects (id, room_id, account_id, title, created_by) values
  ('cc153000-0000-0000-0000-000000000020', 'cc153000-0000-0000-0000-000000000010',
   '11111111-1111-1111-1111-111111111111', 'Two Writers',
   '11111111-1111-1111-1111-111111111111');

-- Two people's words in one song, written the way the editor writes them.
insert into public.contributions (id, project_id, author_id, author_name, body, position) values
  ('cc153000-0000-0000-0000-000000000031', 'cc153000-0000-0000-0000-000000000020',
   '11111111-1111-1111-1111-111111111111', 'The Writer', 'a line the writer wrote', 1024),
  ('cc153000-0000-0000-0000-000000000032', 'cc153000-0000-0000-0000-000000000020',
   'cc153000-0000-0000-0000-000000000001', 'The Co-writer', 'a line the co-writer wrote', 2048),
  ('cc153000-0000-0000-0000-000000000033', 'cc153000-0000-0000-0000-000000000020',
   '11111111-1111-1111-1111-111111111111', 'The Writer', 'a line that stays', 3072);

-- The co-writer cuts the writer's line. It leaves the song, and the person
-- who cut it cannot read it any more: not through the table, and not
-- through the list, which is the writer's and nobody else's.
set local request.jwt.claims = '{"sub": "cc153000-0000-0000-0000-000000000001"}';
set local role authenticated;

do $$
begin
  perform public.cut_line('cc153000-0000-0000-0000-000000000031');

  if exists (select 1 from public.contributions
             where id = 'cc153000-0000-0000-0000-000000000031') then
    raise exception 'the person who cut a line could still read it';
  end if;
  if exists (select 1 from public.lines_you_cut('cc153000-0000-0000-0000-000000000020')) then
    raise exception 'the person who cut somebody else''s line was handed a copy of it';
  end if;
  if (select count(*) from public.contributions
      where project_id = 'cc153000-0000-0000-0000-000000000020') <> 2 then
    raise exception 'cutting one line did not leave the other two in the song';
  end if;

  -- A second cut of the same line, and a cut of a line that does not exist:
  -- neither is an error, because the save loop that calls this must not
  -- fail over a line that is already out of the song.
  perform public.cut_line('cc153000-0000-0000-0000-000000000031');
  perform public.cut_line('cc153000-0000-0000-0000-000000000099');
end $$;

-- The writer finds it again, and only there: a cut line is not part of the
-- song even for the person who wrote it.
reset role;
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';
set local role authenticated;

do $$
begin
  if exists (select 1 from public.contributions
             where id = 'cc153000-0000-0000-0000-000000000031') then
    raise exception 'a cut line was still in the song for its writer';
  end if;
  if (select string_agg(body, ', ')
      from public.lines_you_cut('cc153000-0000-0000-0000-000000000020'))
     is distinct from 'a line the writer wrote' then
    raise exception 'the writer could not find the line that was cut from them';
  end if;

  -- And the other way round. The writer cuts the co-writer's line; each of
  -- them keeps exactly their own.
  perform public.cut_line('cc153000-0000-0000-0000-000000000032');
  if (select string_agg(body, ', ')
      from public.lines_you_cut('cc153000-0000-0000-0000-000000000020'))
     is distinct from 'a line the writer wrote' then
    raise exception 'cutting somebody else''s line put it in the cutter''s list';
  end if;
end $$;

reset role;
set local request.jwt.claims = '{"sub": "cc153000-0000-0000-0000-000000000001"}';
set local role authenticated;

do $$
begin
  if (select string_agg(body, ', ')
      from public.lines_you_cut('cc153000-0000-0000-0000-000000000020'))
     is distinct from 'a line the co-writer wrote' then
    raise exception 'the co-writer''s cut line was not kept for the co-writer, and only that one';
  end if;

  -- The delete policy is gone. Even an editor cannot take a line out for
  -- good with a plain delete, which is what the app used to do.
  delete from public.contributions where id = 'cc153000-0000-0000-0000-000000000033';
end $$;

-- Somebody who can only look cannot take a line out.
reset role;
set local request.jwt.claims = '{"sub": "cc153000-0000-0000-0000-000000000002"}';
set local role authenticated;

do $$
begin
  begin
    perform public.cut_line('cc153000-0000-0000-0000-000000000033');
    raise exception 'somebody who can only look cut a line';
  exception when insufficient_privilege then null;
  end;
end $$;

-- And somebody who is not in the room at all. The viewer above has a role;
-- this account has none, `null in (...)` is null, and without the coalesce
-- a stranger with any valid token could cut lines out of anybody's song.
reset role;
set local request.jwt.claims = '{"sub": "cc153000-0000-0000-0000-000000000003"}';
set local role authenticated;

do $$
begin
  begin
    perform public.cut_line('cc153000-0000-0000-0000-000000000033');
    raise exception 'somebody outside the room cut a line';
  exception when insufficient_privilege then null;
  end;
end $$;

reset role;

-- The first cut's time stands: a second cut of an already-cut line does not
-- move it. Backdated here because now() does not move inside one transaction,
-- so a cut that did overwrite the time would otherwise be invisible.
update public.contributions
set deleted_at = now() - interval '1 hour'
where id = 'cc153000-0000-0000-0000-000000000031';

set local request.jwt.claims = '{"sub": "cc153000-0000-0000-0000-000000000001"}';
set local role authenticated;
select public.cut_line('cc153000-0000-0000-0000-000000000031');
reset role;

do $$
begin
  if (select deleted_at from public.contributions
      where id = 'cc153000-0000-0000-0000-000000000031')
     is distinct from now() - interval '1 hour' then
    raise exception 'cutting an already-cut line moved the time it was cut';
  end if;
  if (select deleted_at from public.contributions
      where id = 'cc153000-0000-0000-0000-000000000032') is null then
    raise exception 'the writer''s cut of the co-writer''s line did not land';
  end if;
  if (select deleted_at from public.contributions
      where id = 'cc153000-0000-0000-0000-000000000033') is not null then
    raise exception 'a refused cut marked the line anyway';
  end if;
  if not exists (select 1 from public.contributions
                 where id = 'cc153000-0000-0000-0000-000000000033') then
    raise exception 'an editor deleted a line for good with a plain delete';
  end if;
  -- The cut rows are still whole: this is what "kept" means.
  if (select count(*) from public.contributions
      where project_id = 'cc153000-0000-0000-0000-000000000020') <> 3 then
    raise exception 'a cut line was deleted rather than kept';
  end if;
end $$;

set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';

-- ---------------------------------------------------------------------
-- Three ways to answer a song (0154).
--
-- Somebody in the room answers an ask through all three doors. What stayed
-- with them and their question arrive the way replies always have: the
-- asker is told, and everybody who can see the ask can read them. Their
-- opinion is held: it tells nobody, and nobody but its writer can read it
-- -- not the room, not the room's owner, not even the person who asked --
-- until the person who asked says they are ready. The room owner cannot
-- say it for them. Once ready, a later opinion arrives normally, to the
-- asker alone, and the first "I'm ready" stands. A plain line with no door,
-- which is what an older build sends, still reaches everyone.
-- ---------------------------------------------------------------------

reset role;
insert into auth.users (id, email, raw_user_meta_data) values
  ('cc154000-0000-0000-0000-000000000001', 'theoneasking@smoke.test',
   '{"display_name": "The One Asking"}'),
  ('cc154000-0000-0000-0000-000000000002', 'thelistener@smoke.test',
   '{"display_name": "The Listener"}'),
  ('cc154000-0000-0000-0000-000000000003', 'alsointheroom@smoke.test',
   '{"display_name": "Also In The Room"}');

-- The Writer owns the room and is not the one asking, so the owner's
-- update rights (0049) are tested against somebody else's decision.
insert into public.rooms (id, account_id, name)
values ('cc154000-0000-0000-0000-000000000010',
        '11111111-1111-1111-1111-111111111111', 'The Listening Room');

insert into public.room_members (room_id, user_id, display_name, role, color_value) values
  ('cc154000-0000-0000-0000-000000000010', '11111111-1111-1111-1111-111111111111',
   'The Writer', 'owner', 4294937166),
  ('cc154000-0000-0000-0000-000000000010', 'cc154000-0000-0000-0000-000000000001',
   'The One Asking', 'editor', 4283215698),
  ('cc154000-0000-0000-0000-000000000010', 'cc154000-0000-0000-0000-000000000002',
   'The Listener', 'editor', 4284000001),
  ('cc154000-0000-0000-0000-000000000010', 'cc154000-0000-0000-0000-000000000003',
   'Also In The Room', 'viewer', 4284000002);

insert into public.projects (id, room_id, account_id, title, created_by) values
  ('cc154000-0000-0000-0000-000000000020', 'cc154000-0000-0000-0000-000000000010',
   '11111111-1111-1111-1111-111111111111', 'Three Doors',
   'cc154000-0000-0000-0000-000000000001');

insert into public.project_asks (id, project_id, asked_by, part, note, audience)
values ('cc154000-0000-0000-0000-000000000030',
        'cc154000-0000-0000-0000-000000000020',
        'cc154000-0000-0000-0000-000000000001', null,
        'Is the second verse earning its place?', 'room');

-- The listener answers through all three doors, and is refused a fourth.
set local request.jwt.claims = '{"sub": "cc154000-0000-0000-0000-000000000002"}';
set local role authenticated;

do $$
begin
  insert into public.ask_replies (id, ask_id, author_id, body, kind) values
    ('cc154000-0000-0000-0000-000000000041', 'cc154000-0000-0000-0000-000000000030',
     'cc154000-0000-0000-0000-000000000002', 'The line about the kitchen light stayed with me.', 'stayed'),
    ('cc154000-0000-0000-0000-000000000042', 'cc154000-0000-0000-0000-000000000030',
     'cc154000-0000-0000-0000-000000000002', 'Is the second verse sung by the same person?', 'question'),
    ('cc154000-0000-0000-0000-000000000043', 'cc154000-0000-0000-0000-000000000030',
     'cc154000-0000-0000-0000-000000000002', 'The bridge drags.', 'opinion');

  begin
    insert into public.ask_replies (ask_id, author_id, body, kind) values
      ('cc154000-0000-0000-0000-000000000030',
       'cc154000-0000-0000-0000-000000000002', 'Four stars.', 'rating');
    raise exception 'a reply went through a door that does not exist';
  exception when check_violation then null;
  end;

  -- Your own words, all of them, held or not: you cannot take back what
  -- you cannot see.
  if (select count(*) from public.ask_replies
      where ask_id = 'cc154000-0000-0000-0000-000000000030') <> 3 then
    raise exception 'the listener could not read back everything they said';
  end if;
end $$;

-- The held opinion told nobody; the other two told the asker.
reset role;

do $$
begin
  if exists (select 1 from public.notifications
             where body like '%bridge drags%') then
    raise exception 'a held opinion was announced';
  end if;
  if (select count(*) from public.notifications
      where user_id = 'cc154000-0000-0000-0000-000000000001'
        and project_id = 'cc154000-0000-0000-0000-000000000020'
        and title like '%replied about%') <> 2 then
    raise exception 'the asker was not told about what stayed and the question';
  end if;
end $$;

-- Somebody else in the room reads the two open doors and not the third.
set local request.jwt.claims = '{"sub": "cc154000-0000-0000-0000-000000000003"}';
set local role authenticated;

do $$
begin
  if (select string_agg(kind, ',' order by created_at, id) from public.ask_replies
      where ask_id = 'cc154000-0000-0000-0000-000000000030')
     is distinct from 'stayed,question' then
    raise exception 'the room read something other than what stayed and the question';
  end if;
end $$;

-- The room's owner reads the same two, and cannot decide for the asker.
reset role;
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';
set local role authenticated;

do $$
begin
  if exists (select 1 from public.ask_replies
             where id = 'cc154000-0000-0000-0000-000000000043') then
    raise exception 'the room owner read a held opinion';
  end if;

  begin
    update public.project_asks set opinions_opened_at = now()
    where id = 'cc154000-0000-0000-0000-000000000030';
    raise exception 'the room owner opened somebody else''s opinions';
  exception when insufficient_privilege then null;
  end;
end $$;

-- The person who asked: nothing until they are ready, then the opinion.
reset role;
set local request.jwt.claims = '{"sub": "cc154000-0000-0000-0000-000000000001"}';
set local role authenticated;

do $$
begin
  if exists (select 1 from public.ask_replies
             where id = 'cc154000-0000-0000-0000-000000000043') then
    raise exception 'the asker read an opinion before saying they were ready';
  end if;

  update public.project_asks set opinions_opened_at = now()
  where id = 'cc154000-0000-0000-0000-000000000030';

  if (select string_agg(kind, ',' order by created_at, id) from public.ask_replies
      where ask_id = 'cc154000-0000-0000-0000-000000000030')
     is distinct from 'stayed,question,opinion' then
    raise exception 'saying "I''m ready" did not open the opinion to the asker';
  end if;
end $$;

-- Once ready, a later opinion arrives normally: the asker is told, and only
-- the asker. An older build's plain line, through no door, reaches everyone.
reset role;
set local request.jwt.claims = '{"sub": "cc154000-0000-0000-0000-000000000002"}';
set local role authenticated;

insert into public.ask_replies (id, ask_id, author_id, body, kind) values
  ('cc154000-0000-0000-0000-000000000044', 'cc154000-0000-0000-0000-000000000030',
   'cc154000-0000-0000-0000-000000000002', 'The last chorus could go round once more.', 'opinion');
insert into public.ask_replies (id, ask_id, author_id, body) values
  ('cc154000-0000-0000-0000-000000000045', 'cc154000-0000-0000-0000-000000000030',
   'cc154000-0000-0000-0000-000000000002', 'Thursday, if that helps.');

reset role;

do $$
begin
  if (select count(*) from public.notifications
      where body like '%round once more%') <> 1
     or not exists (select 1 from public.notifications
                    where body like '%round once more%'
                      and user_id = 'cc154000-0000-0000-0000-000000000001') then
    raise exception 'an opinion the asker was ready for did not reach the asker alone';
  end if;
end $$;

set local request.jwt.claims = '{"sub": "cc154000-0000-0000-0000-000000000003"}';
set local role authenticated;

do $$
begin
  if (select string_agg(coalesce(kind, 'plain'), ',' order by created_at, id)
      from public.ask_replies
      where ask_id = 'cc154000-0000-0000-0000-000000000030')
     is distinct from 'stayed,question,plain' then
    raise exception 'the room read an opinion, or missed a plain line';
  end if;
end $$;

-- The first "I'm ready" stands. The app sends its own clock rather than
-- now(), so a second tap from a second device arrives as a different time;
-- an hour ahead here, because now() does not move inside one transaction
-- and a second tap that did overwrite the first would otherwise be
-- invisible. Not an error: a decision already made is not a thing to fail
-- over.
reset role;
set local request.jwt.claims = '{"sub": "cc154000-0000-0000-0000-000000000001"}';
set local role authenticated;
update public.project_asks set opinions_opened_at = now() + interval '1 hour'
where id = 'cc154000-0000-0000-0000-000000000030';
reset role;

do $$
begin
  if (select opinions_opened_at from public.project_asks
      where id = 'cc154000-0000-0000-0000-000000000030')
     is distinct from now() then
    raise exception 'a second "I''m ready" moved the first one';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- A room for a class (0148).
--
-- Every Musician, Same Song, 17 September 2026, slice 16. The writer keeps
-- two named links open, one of them a class, and eight is the cap. Two
-- adult students open the class link and each lands in the class room as a
-- viewer and in a lesson room of their own as an editor. A viewer in the
-- class room can listen and talk, and cannot post a take, add a song or
-- touch the words -- refused by the policies, not by an app -- while the
-- same person in their own lesson room still can. One student's lesson
-- room is closed to the other. Turning the class off leaves the room and
-- its people and stops new scans joining it; turning it back on is the same
-- room, and a fresh one is made only once that room is gone. A teacher is
-- still an adult; nobody but the teacher says what a link is.
--
-- Not here: the storage policy the audio arrives through, which 0148 also
-- closes to viewers. The shim grants storage.objects to service_role only,
-- so a write as authenticated would be refused on the grant whatever the
-- policy said, and a check that cannot fail for the right reason proves
-- nothing.
-- ---------------------------------------------------------------------

insert into auth.users (id, email, raw_user_meta_data) values
  ('c1a55148-0000-0000-0000-000000000001', 'alto.one@smoke.test', '{"display_name": "Alto One"}'),
  ('c1a55148-0000-0000-0000-000000000002', 'alto.two@smoke.test', '{"display_name": "Alto Two"}'),
  ('c1a55148-0000-0000-0000-000000000003', 'alto.three@smoke.test', '{"display_name": "Alto Three"}');

insert into private.birth_months (person_id, born) values
  ('c1a55148-0000-0000-0000-000000000001', date '1991-03-01'),
  ('c1a55148-0000-0000-0000-000000000002', date '1993-11-01'),
  ('c1a55148-0000-0000-0000-000000000003', date '1990-07-01');

set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';
set local role authenticated;

select count(*) as links_before from public.my_lesson_links() \gset
select set_config('smoke.links_before', :'links_before', true);

-- Two named links, open at once; the second is a class.
select public.open_lesson_link('Tuesday beginners') as plain_link_code \gset
select public.open_lesson_link('Jazz studio', true) as class_link_code \gset
select set_config('smoke.plain_link_code', :'plain_link_code', true);
select set_config('smoke.class_link_code', :'class_link_code', true);

do $$
declare
  before integer := current_setting('smoke.links_before')::integer;
  class_link record;
  filler integer := 0;
begin
  if (select count(*) from public.my_lesson_links()) <> before + 2 then
    raise exception 'two links opened at once did not both stay open';
  end if;

  select * into class_link from public.my_lesson_links() l
  where l.code = current_setting('smoke.class_link_code');
  if class_link.id is null then
    raise exception 'the class link is not among the teacher''s open links';
  end if;
  if class_link.title <> 'Jazz studio' then
    raise exception 'the class link is not called what the teacher called it';
  end if;
  if class_link.class_room_id is null then
    raise exception 'a link made as a class has no class room';
  end if;
  if class_link.class_room_name <> 'Jazz studio' then
    raise exception 'the class room is not named for the link (got %)', class_link.class_room_name;
  end if;
  if (select l.class_room_id from public.my_lesson_links() l
      where l.code = current_setting('smoke.plain_link_code')) is not null then
    raise exception 'a plain link made beside a class one became a class';
  end if;
  perform set_config('smoke.class_room', class_link.class_room_id::text, true);
  perform set_config('smoke.class_link', class_link.id::text, true);

  -- The cap: eight open, and a ninth is refused in words that say what to
  -- do rather than how many there are.
  while (select count(*) from public.my_lesson_links()) < 8 loop
    filler := filler + 1;
    perform public.open_lesson_link('Filler ' || filler);
  end loop;
  begin
    perform public.open_lesson_link('One too many');
    raise exception 'a ninth lesson link was opened';
  exception when invalid_parameter_value then
    if sqlerrm <> 'Eight lesson links are open. Turn one off to make another.' then
      raise exception 'the ninth link was refused for another reason (%)', sqlerrm;
    end if;
  end;

  -- One at a time: the fillers go and the named links stay.
  perform public.close_lesson_link(l.id)
  from public.my_lesson_links() l
  where l.title like 'Filler %';
  if (select count(*) from public.my_lesson_links()) <> before + 2 then
    raise exception 'turning links off one at a time left the wrong ones (% open)',
      (select count(*) from public.my_lesson_links());
  end if;
end $$;

reset role;

do $$
declare
  class_room uuid := current_setting('smoke.class_room')::uuid;
begin
  if (select account_id from public.rooms where id = class_room)
     is distinct from '11111111-1111-1111-1111-111111111111'::uuid then
    raise exception 'the class room does not belong to the teacher';
  end if;
  if (select role from public.room_members
      where room_id = class_room and user_id = '11111111-1111-1111-1111-111111111111')
     is distinct from 'owner' then
    raise exception 'the teacher does not own the class room';
  end if;
  if (select count(*) from public.room_members where room_id = class_room) <> 1 then
    raise exception 'a new class room holds somebody besides the teacher';
  end if;
end $$;

-- What the class listens to: the teacher's song in the class room, with
-- words on it and a take the whole class can hear.
insert into public.projects (id, room_id, account_id, title, created_by)
values ('c1a55148-0000-0000-0000-00000000014a', current_setting('smoke.class_room')::uuid,
        '11111111-1111-1111-1111-111111111111', 'Autumn Leaves',
        '11111111-1111-1111-1111-111111111111');

insert into public.contributions (id, project_id, author_id, author_name, body)
values ('c1a55148-0000-0000-0000-00000000014c', 'c1a55148-0000-0000-0000-00000000014a',
        '11111111-1111-1111-1111-111111111111', 'The Writer', 'The falling leaves');

insert into public.song_layers
  (id, project_id, recorded_by, storage_path, label, part, duration_ms, shared_at)
values
  ('c1a55148-0000-0000-0000-00000000014d', 'c1a55148-0000-0000-0000-00000000014a',
   '11111111-1111-1111-1111-111111111111',
   current_setting('smoke.class_room') || '/c1a55148-0000-0000-0000-00000000014a/layers/alto.m4a',
   'Alto', 'vocal', 30000, now());

-- The first student opens the class link, twice.
set local request.jwt.claims = '{"sub": "c1a55148-0000-0000-0000-000000000001", "email": "alto.one@smoke.test"}';
set local role authenticated;

select public.join_lesson_link(:'class_link_code') as alto_one_room \gset
select public.join_lesson_link(:'class_link_code') as alto_one_room_again \gset
select set_config('smoke.alto_one_room', :'alto_one_room', true);
select set_config('smoke.alto_one_room_again', :'alto_one_room_again', true);

do $$
declare
  class_room uuid := current_setting('smoke.class_room')::uuid;
  own_room uuid := current_setting('smoke.alto_one_room')::uuid;
begin
  if own_room = class_room then
    raise exception 'opening a class link gave back the class room instead of a lesson room';
  end if;
  if current_setting('smoke.alto_one_room_again') <> current_setting('smoke.alto_one_room') then
    raise exception 'opening a class link twice made a second lesson room';
  end if;
  -- Under their own RLS: both rooms are theirs to see.
  if not exists (select 1 from public.rooms where id = class_room) then
    raise exception 'the student cannot see the class room they joined';
  end if;
  if not exists (select 1 from public.rooms where id = own_room) then
    raise exception 'the student cannot see their own lesson room';
  end if;
  -- Listening: the teacher's shared take and the words are readable.
  if not exists (select 1 from public.song_layers where id = 'c1a55148-0000-0000-0000-00000000014d') then
    raise exception 'a viewer cannot hear the take the class listens to';
  end if;
  if not exists (select 1 from public.contributions where id = 'c1a55148-0000-0000-0000-00000000014c') then
    raise exception 'a viewer cannot read the words the class works on';
  end if;
end $$;

-- Talking is allowed.
insert into public.room_messages (room_id, author_id, body)
values (current_setting('smoke.class_room')::uuid, 'c1a55148-0000-0000-0000-000000000001',
        'Which bar is the pickup?');

-- Posting is not: a take, a song, a line, or a change to a line. The first
-- three are refused outright; an update RLS refuses simply finds no row.
do $$
begin
  begin
    insert into public.song_layers (project_id, recorded_by, storage_path, label, part, duration_ms)
    values ('c1a55148-0000-0000-0000-00000000014a', 'c1a55148-0000-0000-0000-000000000001',
            current_setting('smoke.class_room') || '/c1a55148-0000-0000-0000-00000000014a/layers/in-front-of-everybody.m4a',
            'Mine', 'vocal', 5000);
    raise exception 'a viewer posted a take in the class room';
  exception when insufficient_privilege then null;
  end;

  begin
    insert into public.projects (room_id, account_id, title, created_by)
    values (current_setting('smoke.class_room')::uuid, '11111111-1111-1111-1111-111111111111',
            'A song of my own', 'c1a55148-0000-0000-0000-000000000001');
    raise exception 'a viewer added a song to the class room';
  exception when insufficient_privilege then null;
  end;

  begin
    insert into public.contributions (project_id, author_id, author_name, body)
    values ('c1a55148-0000-0000-0000-00000000014a', 'c1a55148-0000-0000-0000-000000000001',
            'Alto One', 'A line of my own');
    raise exception 'a viewer added words to the class''s song';
  exception when insufficient_privilege then null;
  end;

  update public.contributions set body = 'The falling leaves, rewritten'
  where id = 'c1a55148-0000-0000-0000-00000000014c';
  if found then
    raise exception 'a viewer changed the words of the class''s song';
  end if;
end $$;

-- In their own lesson room the same person is an editor, and a take goes
-- up: the role rule reaches viewers and nobody else.
do $$
declare
  own_room uuid := current_setting('smoke.alto_one_room')::uuid;
  own_song uuid;
begin
  insert into public.projects (room_id, account_id, title)
  values (own_room, '11111111-1111-1111-1111-111111111111', 'Autumn Leaves, my own')
  returning id into own_song;
  insert into public.song_layers (project_id, recorded_by, storage_path, label, part, duration_ms)
  values (own_song, 'c1a55148-0000-0000-0000-000000000001',
          own_room::text || '/' || own_song::text || '/layers/mine.m4a', 'Mine', 'vocal', 5000);
  perform set_config('smoke.alto_one_song', own_song::text, true);
end $$;

-- The second student: the class, yes; the other student's lesson, no.
set local request.jwt.claims = '{"sub": "c1a55148-0000-0000-0000-000000000002", "email": "alto.two@smoke.test"}';

select public.join_lesson_link(:'class_link_code') as alto_two_room \gset
select set_config('smoke.alto_two_room', :'alto_two_room', true);

do $$
begin
  if not exists (select 1 from public.rooms where id = current_setting('smoke.class_room')::uuid) then
    raise exception 'the second student is not in the class room';
  end if;
  if current_setting('smoke.alto_two_room') = current_setting('smoke.alto_one_room') then
    raise exception 'two students were given one lesson room';
  end if;
  if exists (select 1 from public.rooms where id = current_setting('smoke.alto_one_room')::uuid) then
    raise exception 'a classmate can see another student''s lesson room';
  end if;
  if exists (select 1 from public.projects where id = current_setting('smoke.alto_one_song')::uuid) then
    raise exception 'a classmate can see another student''s lesson song';
  end if;
  if (select count(*) from public.lesson_rooms) <> 1 then
    raise exception 'a classmate can see another student''s lesson';
  end if;
end $$;

reset role;

do $$
declare
  class_room uuid := current_setting('smoke.class_room')::uuid;
  first_lesson uuid := current_setting('smoke.alto_one_room')::uuid;
begin
  if (select count(*) from public.room_members where room_id = class_room) <> 3 then
    raise exception 'the class room does not hold the teacher and both students (holds %)',
      (select count(*) from public.room_members where room_id = class_room);
  end if;
  if (select count(*) from public.room_members
      where room_id = class_room and role = 'viewer') <> 2 then
    raise exception 'a student is in the class room as something other than a viewer';
  end if;
  if (select count(*) from public.room_members where room_id = first_lesson) <> 2 then
    raise exception 'a lesson room made by a class link holds somebody besides the two of them';
  end if;
  if (select role from public.room_members
      where room_id = first_lesson and user_id = 'c1a55148-0000-0000-0000-000000000001')
     is distinct from 'editor' then
    raise exception 'the student cannot work in their own lesson room';
  end if;
  -- Told once per student, the way 0129 tells a teacher.
  if private.wants_invite_responses('11111111-1111-1111-1111-111111111111')
     and (select count(*) from public.notifications
          where user_id = '11111111-1111-1111-1111-111111111111'
            and type = 'invite_accepted'
            and room_id in (first_lesson, current_setting('smoke.alto_two_room')::uuid)) <> 2 then
    raise exception 'the teacher was not told about each student who joined the class';
  end if;
end $$;

-- Turning the class off leaves the room and its people, and a student who
-- scans meanwhile gets a lesson room and no class. Turning it back on is the
-- same room -- a switch flipped twice on a phone must not split a class
-- between two rooms -- and the student who scanned meanwhile is in it the
-- next time they scan. Saying "class" twice makes one. Only once the room is
-- gone does turning the class on make a fresh one, holding only the teacher.
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';
set local role authenticated;

do $$
declare
  link uuid := current_setting('smoke.class_link')::uuid;
begin
  if public.set_lesson_link_class(link, false) is not null then
    raise exception 'turning a class off answered with a room';
  end if;
  if (select l.class_room_id from public.my_lesson_links() l where l.id = link) is not null then
    raise exception 'a link turned off as a class still opens into a class room';
  end if;
end $$;

-- The third student scans while the class is off.
set local request.jwt.claims = '{"sub": "c1a55148-0000-0000-0000-000000000003", "email": "alto.three@smoke.test"}';

select public.join_lesson_link(:'class_link_code') as alto_three_room \gset
select set_config('smoke.alto_three_room', :'alto_three_room', true);

do $$
begin
  if current_setting('smoke.alto_three_room') = current_setting('smoke.class_room') then
    raise exception 'scanning a link whose class is off gave back the class room';
  end if;
  if exists (select 1 from public.rooms where id = current_setting('smoke.class_room')::uuid) then
    raise exception 'a student who scanned while the class was off is in the class room';
  end if;
  if not exists (select 1 from public.rooms where id = current_setting('smoke.alto_three_room')::uuid) then
    raise exception 'a student who scanned while the class was off got no lesson room';
  end if;
end $$;

-- Back on: the same room, under the same name, with the same people in it.
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';

do $$
declare
  link uuid := current_setting('smoke.class_link')::uuid;
  first_room uuid := current_setting('smoke.class_room')::uuid;
begin
  if public.set_lesson_link_class(link, true) is distinct from first_room then
    raise exception 'turning the class back on did not open the room the class is in';
  end if;
  if (select l.class_room_id from public.my_lesson_links() l where l.id = link)
     is distinct from first_room then
    raise exception 'the link does not open into the class room again';
  end if;
  if (select l.class_room_name from public.my_lesson_links() l where l.id = link) <> 'Jazz studio' then
    raise exception 'the class room came back under another name (got %)',
      (select l.class_room_name from public.my_lesson_links() l where l.id = link);
  end if;
  if public.set_lesson_link_class(link, true) is distinct from first_room then
    raise exception 'saying "class" twice made two class rooms';
  end if;
end $$;

-- The student who scanned meanwhile scans again: the same lesson room, and
-- now the class.
set local request.jwt.claims = '{"sub": "c1a55148-0000-0000-0000-000000000003", "email": "alto.three@smoke.test"}';

select public.join_lesson_link(:'class_link_code') as alto_three_room_again \gset
select set_config('smoke.alto_three_room_again', :'alto_three_room_again', true);

do $$
begin
  if current_setting('smoke.alto_three_room_again') <> current_setting('smoke.alto_three_room') then
    raise exception 'scanning again once the class was on made a second lesson room';
  end if;
  if not exists (select 1 from public.rooms where id = current_setting('smoke.class_room')::uuid) then
    raise exception 'a student who scanned again once the class was on is not in the class room';
  end if;
end $$;

reset role;

do $$
declare
  class_room uuid := current_setting('smoke.class_room')::uuid;
begin
  if (select count(*) from public.room_members where room_id = class_room) <> 4 then
    raise exception 'the class room does not hold the teacher and all three students (holds %)',
      (select count(*) from public.room_members where room_id = class_room);
  end if;
  if (select role from public.room_members
      where room_id = class_room and user_id = 'c1a55148-0000-0000-0000-000000000003')
     is distinct from 'viewer' then
    raise exception 'the student who joined the class late is not a viewer in it';
  end if;
  -- The room goes. The app deletes a room outright and the column is set
  -- null with it; this is the other way a room is gone, and the one every
  -- guard in 0148 reads.
  update public.rooms set deleted_at = now() where id = class_room;
end $$;

-- With the room gone, turning the class on makes a fresh one, holding only
-- the teacher, under the name the old room let go of: the unique name index
-- and make_class_room both look past rooms that are gone.
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';
set local role authenticated;

do $$
declare
  link uuid := current_setting('smoke.class_link')::uuid;
  first_room uuid := current_setting('smoke.class_room')::uuid;
  again uuid;
begin
  if (select l.class_room_id from public.my_lesson_links() l where l.id = link) is not null then
    raise exception 'a link still opens into a class room that is gone';
  end if;
  again := public.set_lesson_link_class(link, true);
  if again is null or again = first_room then
    raise exception 'turning the class on with its room gone did not make a class room';
  end if;
  if (select l.class_room_id from public.my_lesson_links() l where l.id = link)
     is distinct from again then
    raise exception 'the link does not open into the new class room';
  end if;
  if (select l.class_room_name from public.my_lesson_links() l where l.id = link) <> 'Jazz studio' then
    raise exception 'the new class room did not take the name the old one let go of (got %)',
      (select l.class_room_name from public.my_lesson_links() l where l.id = link);
  end if;
  perform set_config('smoke.class_room_again', again::text, true);
end $$;

reset role;

do $$
begin
  if (select count(*) from public.room_members
      where room_id = current_setting('smoke.class_room')::uuid) <> 4 then
    raise exception 'turning the class off and on lost the people in the class room';
  end if;
  if (select count(*) from public.room_members
      where room_id = current_setting('smoke.class_room_again')::uuid) <> 1 then
    raise exception 'a class room made again holds somebody besides the teacher';
  end if;
end $$;

-- Nobody but the teacher says what a link is.
set local request.jwt.claims = '{"sub": "99999999-9999-9999-9999-999999999999", "email": "joiner.two@smoke.test"}';
set local role authenticated;

do $$
begin
  begin
    perform public.set_lesson_link_class(current_setting('smoke.class_link')::uuid, false);
    raise exception 'somebody else turned a teacher''s class off';
  exception when insufficient_privilege then null;
  end;
end $$;

-- And the teacher is an adult (0139), for a class as for a link. Joiner One
-- answered as a 15-year-old under "Calls for adults (0134)" above.
set local request.jwt.claims = '{"sub": "88888888-8888-8888-8888-888888888888", "email": "joiner.one@smoke.test"}';

do $$
begin
  begin
    perform public.open_lesson_link('A class from a 15-year-old', true);
    raise exception 'a 15-year-old opened a class';
  exception when invalid_parameter_value then
    if sqlerrm <> 'Lesson links are for people 18 and over for now.' then
      raise exception 'a 15-year-old was refused a class for another reason (%)', sqlerrm;
    end if;
  end;
  -- Somebody else's link is refused as somebody else's, whatever the age of
  -- the person asking: the link is checked first, as 0139 checks it first
  -- for a student.
  begin
    perform public.set_lesson_link_class(current_setting('smoke.class_link')::uuid, true);
    raise exception 'a 15-year-old changed a lesson link';
  exception when insufficient_privilege then null;
  end;
end $$;

-- A link turned off, one at a time, leaves the other open and cannot be
-- made a class: it opens nothing, so there is nothing for it to be a class of.
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';

select public.close_lesson_link(current_setting('smoke.class_link')::uuid);

do $$
begin
  if exists (select 1 from public.my_lesson_links() l
             where l.code = current_setting('smoke.class_link_code')) then
    raise exception 'a link turned off is still open';
  end if;
  if not exists (select 1 from public.my_lesson_links() l
                 where l.code = current_setting('smoke.plain_link_code')) then
    raise exception 'turning one link off turned another off with it';
  end if;
  begin
    perform public.set_lesson_link_class(current_setting('smoke.class_link')::uuid, true);
    raise exception 'a closed link was made a class';
  exception when insufficient_privilege then null;
  end;
end $$;

reset role;

-- ---------------------------------------------------------------------
-- A spoken note at a moment (0152).
--
-- Every Musician, Same Song, 17 September 2026, slice 23. The teacher says
-- something at 1:48 of the take the student sent them, in 0141's lesson
-- room further up this file. It is a moment_notes row with a voice and no
-- words, and every rule a typed note has still holds: the student who
-- played it can read it and is told once, somebody outside the room can
-- neither read it nor leave one, and only the teacher can take it back.
-- A note has to say something, the voice has to live in this song's own
-- folder, and one object is one note.
--
-- Not here: the storage policies the audio goes through. The shim grants
-- storage.objects to service_role only (see 0148's block), so a read or a
-- write as authenticated would be refused on the grant whatever the policy
-- said, and a check that cannot fail for the right reason proves nothing.
-- ---------------------------------------------------------------------

insert into auth.users (id, email, raw_user_meta_data) values
  ('5011e500-0000-0000-0000-000000000152', 'passer.by@smoke.test',
   '{"display_name": "Passer By"}');

-- The teacher says it.
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';
set local role authenticated;

do $$
declare
  spoken uuid;
begin
  -- No words and no voice is not a note.
  begin
    insert into public.moment_notes (project_id, layer_id, at_ms)
    values ('5011e500-0000-0000-0000-00000000014b',
            '5011e500-0000-0000-0000-00000000014c', 108000);
    raise exception 'a note with neither words nor a voice was accepted';
  exception when check_violation then null;
  end;

  -- The voice has to live in this song's own folder, or the read policy
  -- would hand out whatever object the row pointed at.
  begin
    insert into public.moment_notes (project_id, layer_id, at_ms, voice_path)
    values ('5011e500-0000-0000-0000-00000000014b',
            '5011e500-0000-0000-0000-00000000014c', 108000,
            '5011e500-0000-0000-0000-00000000014a/44444444-4444-4444-4444-444444444444/moments/elsewhere.wav');
    raise exception 'a spoken note pointing into another song''s folder was accepted';
  exception when check_violation then null;
  end;

  insert into public.moment_notes (project_id, layer_id, at_ms, voice_path)
  values ('5011e500-0000-0000-0000-00000000014b',
          '5011e500-0000-0000-0000-00000000014c', 108000,
          '5011e500-0000-0000-0000-00000000014a/5011e500-0000-0000-0000-00000000014b/moments/said-at-148.wav')
  returning id into spoken;
  perform set_config('smoke.spoken_note', spoken::text, true);

  if not exists (
    select 1 from public.moment_notes
    where id = spoken and body is null and on_shared_take is true
  ) then
    raise exception 'a spoken note on a sent take did not come back as the room''s, with no words';
  end if;

  -- One object is one note.
  begin
    insert into public.moment_notes (project_id, layer_id, at_ms, voice_path)
    values ('5011e500-0000-0000-0000-00000000014b',
            '5011e500-0000-0000-0000-00000000014c', 109000,
            '5011e500-0000-0000-0000-00000000014a/5011e500-0000-0000-0000-00000000014b/moments/said-at-148.wav');
    raise exception 'two notes were allowed to share one recording';
  exception when unique_violation then null;
  end;
end $$;

-- The student, who played it, was told -- by a card that says the note was
-- spoken, rather than by one with nothing on it. Read without a role, the
-- way 0141's block reads who was told.
reset role;
do $$
begin
  if not exists (
    select 1 from public.notifications
    where user_id = '5011e500-0000-0000-0000-000000000141'
      and type = 'moment_note'
      and actor_id = '11111111-1111-1111-1111-111111111111'
      and title = 'The Writer left a note at 1:48'
      and body = 'Said out loud'
  ) then
    raise exception 'the person who played the take was not told a note was spoken on it';
  end if;
end $$;

-- And can read it.
set local request.jwt.claims = '{"sub": "5011e500-0000-0000-0000-000000000141", "email": "the.student@smoke.test"}';
set local role authenticated;

do $$
begin
  if not exists (
    select 1 from public.moment_notes
    where id = current_setting('smoke.spoken_note')::uuid
      and voice_path is not null
  ) then
    raise exception 'the person who played the take could not read a spoken note on it';
  end if;

  -- Not theirs to take back.
  perform public.delete_moment_note(current_setting('smoke.spoken_note')::uuid);
  if not exists (
    select 1 from public.moment_notes
    where id = current_setting('smoke.spoken_note')::uuid
  ) then
    raise exception 'somebody other than its author took back a spoken note';
  end if;
end $$;

-- Somebody outside the room gets nothing, and may leave nothing.
reset role;
set local request.jwt.claims = '{"sub": "5011e500-0000-0000-0000-000000000152", "email": "passer.by@smoke.test"}';
set local role authenticated;

do $$
begin
  if exists (
    select 1 from public.moment_notes
    where id = current_setting('smoke.spoken_note')::uuid
  ) then
    raise exception 'somebody outside the room could read a spoken note';
  end if;

  begin
    insert into public.moment_notes (project_id, layer_id, at_ms, voice_path)
    values ('5011e500-0000-0000-0000-00000000014b',
            '5011e500-0000-0000-0000-00000000014c', 5000,
            '5011e500-0000-0000-0000-00000000014a/5011e500-0000-0000-0000-00000000014b/moments/uninvited.wav');
    raise exception 'somebody outside the room left a spoken note';
  exception when insufficient_privilege then null;
  end;
end $$;

-- The teacher takes it back, and it is gone for the student too.
reset role;
set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';
set local role authenticated;

do $$
begin
  perform public.delete_moment_note(current_setting('smoke.spoken_note')::uuid);
  if exists (
    select 1 from public.moment_notes
    where id = current_setting('smoke.spoken_note')::uuid
  ) then
    raise exception 'the author could not take back a spoken note';
  end if;
end $$;

reset role;
set local request.jwt.claims = '{"sub": "5011e500-0000-0000-0000-000000000141", "email": "the.student@smoke.test"}';
set local role authenticated;

do $$
begin
  if exists (
    select 1 from public.moment_notes
    where id = current_setting('smoke.spoken_note')::uuid
  ) then
    raise exception 'a spoken note taken back was still readable by the person it was about';
  end if;
end $$;

reset role;

-- ---------------------------------------------------------------------
-- A setlist that knows each song (0157).
--
-- A set stored titles and an order; a gigging band needs what to do with
-- each song. Six nullable columns on the row that joins a song to a set,
-- null meaning "what the song says". The set's owner writes them through
-- 0005's update policy, a song arrives saying nothing, a field cleared goes
-- back to the song, the table refuses what the app would (a key nothing can
-- read, a tempo nothing can count at, an empty string as an answer), and
-- nobody else -- not a viewer of the room, not an editor who can change the
-- song itself -- can see the set or change what it says. The Covers Room
-- and its people are 0142's, above.
-- ---------------------------------------------------------------------

set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';
set local role authenticated;

insert into public.setlists (id, owner_id, name)
values ('a5e70157-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111', 'Saturday at the Anchor');

insert into public.setlist_projects (setlist_id, project_id, position) values
  ('a5e70157-0000-0000-0000-000000000001', '50a6e142-0000-0000-0000-00000000014b', 0),
  ('a5e70157-0000-0000-0000-000000000001', '50a6e142-0000-0000-0000-00000000014c', 1);

do $$
declare
  song record;
begin
  -- A song arrives in a set saying nothing: the app reads the song.
  if exists (
    select 1 from public.setlist_projects
    where setlist_id = 'a5e70157-0000-0000-0000-000000000001'
      and (played_key is not null or bpm is not null or count_in is not null
           or form is not null or ending is not null or note is not null)
  ) then
    raise exception 'a song arrived in a set with answers nobody gave';
  end if;

  -- The owner says what the band does with it.
  update public.setlist_projects
  set played_key = 'Bb major', bpm = 92, count_in = 'Drums, two bars',
      form = 'Intro · Verse · Chorus · Chorus', ending = 'Cold',
      note = 'Straight into the next one'
  where setlist_id = 'a5e70157-0000-0000-0000-000000000001'
    and project_id = '50a6e142-0000-0000-0000-00000000014b';

  select * into song from public.setlist_projects
  where setlist_id = 'a5e70157-0000-0000-0000-000000000001'
    and project_id = '50a6e142-0000-0000-0000-00000000014b';
  if song.played_key is distinct from 'Bb major'
     or song.bpm is distinct from 92
     or song.count_in is distinct from 'Drums, two bars'
     or song.form is distinct from 'Intro · Verse · Chorus · Chorus'
     or song.ending is distinct from 'Cold'
     or song.note is distinct from 'Straight into the next one' then
    raise exception 'the owner''s answers did not land';
  end if;

  -- The other song in the set is untouched.
  if exists (
    select 1 from public.setlist_projects
    where setlist_id = 'a5e70157-0000-0000-0000-000000000001'
      and project_id = '50a6e142-0000-0000-0000-00000000014c'
      and played_key is not null
  ) then
    raise exception 'one song''s key landed on another';
  end if;

  -- A field cleared hands the song back to what it says.
  update public.setlist_projects set bpm = null
  where setlist_id = 'a5e70157-0000-0000-0000-000000000001'
    and project_id = '50a6e142-0000-0000-0000-00000000014b';
  if (select bpm from public.setlist_projects
      where setlist_id = 'a5e70157-0000-0000-0000-000000000001'
        and project_id = '50a6e142-0000-0000-0000-00000000014b') is not null then
    raise exception 'a cleared tempo stayed';
  end if;

  -- The table refuses what the app would, because 0005 lets an owner update
  -- this row directly and a rule that lives only in the app is one request
  -- away from nothing.
  begin
    update public.setlist_projects set played_key = 'Mixolydian'
    where setlist_id = 'a5e70157-0000-0000-0000-000000000001'
      and project_id = '50a6e142-0000-0000-0000-00000000014b';
    raise exception 'a plain update stored something that is not a key';
  exception when check_violation then null;
  end;

  begin
    update public.setlist_projects set bpm = 300
    where setlist_id = 'a5e70157-0000-0000-0000-000000000001'
      and project_id = '50a6e142-0000-0000-0000-00000000014b';
    raise exception 'a tempo nothing can count at was stored';
  exception when check_violation then null;
  end;

  begin
    update public.setlist_projects set note = ''
    where setlist_id = 'a5e70157-0000-0000-0000-000000000001'
      and project_id = '50a6e142-0000-0000-0000-00000000014b';
    raise exception 'an empty note was stored as an answer';
  exception when check_violation then null;
  end;
end $$;

-- Somebody who can only look at the room does not own the set. They cannot
-- see it, and an update from them lands on no row -- which is the silence
-- the app turns into a sentence when no row comes back.
reset role;
set local request.jwt.claims = '{"sub": "50a6e142-0000-0000-0000-000000000147"}';
set local role authenticated;

do $$
declare
  touched integer;
begin
  if exists (
    select 1 from public.setlist_projects
    where setlist_id = 'a5e70157-0000-0000-0000-000000000001'
  ) then
    raise exception 'somebody else''s set was readable by a viewer of the room';
  end if;

  update public.setlist_projects set note = 'Faster'
  where setlist_id = 'a5e70157-0000-0000-0000-000000000001'
    and project_id = '50a6e142-0000-0000-0000-00000000014b';
  get diagnostics touched = row_count;
  if touched <> 0 then
    raise exception 'a viewer of the room changed what somebody else''s set says';
  end if;
end $$;

-- And an editor of the room, who can change the song itself (0144), still
-- cannot change the set: it is the owner's, not the room's.
reset role;
set local request.jwt.claims = '{"sub": "50a6e142-0000-0000-0000-000000000146"}';
set local role authenticated;

do $$
declare
  touched integer;
begin
  update public.setlist_projects set played_key = 'C major'
  where setlist_id = 'a5e70157-0000-0000-0000-000000000001'
    and project_id = '50a6e142-0000-0000-0000-00000000014b';
  get diagnostics touched = row_count;
  if touched <> 0 then
    raise exception 'an editor of the room changed what somebody else''s set says';
  end if;
end $$;

reset role;
do $$
begin
  if (select note from public.setlist_projects
      where setlist_id = 'a5e70157-0000-0000-0000-000000000001'
        and project_id = '50a6e142-0000-0000-0000-00000000014b')
     is distinct from 'Straight into the next one' then
    raise exception 'somebody who does not own the set changed what it says';
  end if;
  if (select played_key from public.setlist_projects
      where setlist_id = 'a5e70157-0000-0000-0000-000000000001'
        and project_id = '50a6e142-0000-0000-0000-00000000014b')
     is distinct from 'Bb major' then
    raise exception 'somebody who does not own the set moved a song''s key';
  end if;
end $$;

set local request.jwt.claims = '{"sub": "11111111-1111-1111-1111-111111111111"}';

commit;
