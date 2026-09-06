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
  select * into found from public.find_musicians('lead', null, 10)
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
    select 1 from public.find_musicians('vocal', null, 10)
    where id = '11111111-1111-1111-1111-111111111111'
  ) then
    raise exception 'a declared instrument did not find its owner';
  end if;

  -- And not found by a city they never made public.
  if exists (
    select 1 from public.find_musicians(null, 'Glasgow', 10)
    where id = '11111111-1111-1111-1111-111111111111'
  ) then
    raise exception 'searching a city found somebody who never published one';
  end if;

  -- Nobody who has not opted in appears at all.
  if exists (
    select 1 from public.find_musicians(null, null, 50)
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
    select 1 from public.find_musicians('bass', 'Glasgow', 50)
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
select public.ask_musician(
  :'project',
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
      and n.kind = 'song_ask'
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

  perform public.answer_ask(the_ask, true);

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


commit;
