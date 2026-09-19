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
  ('contributions_project_event'),
  ('comments_set_updated_at'),
  ('notification_preferences_set_updated_at'),
  ('analysis_errors_set_signature'),
  ('project_audio_references_notify_ready'),
  -- Moved up from acknowledged: the scenario now attaches a recording and
  -- takes it through to 'ready', so this one genuinely fires.
  ('project_audio_references_set_updated_at'),
  -- The scenario adds two layers and asserts who was told about them.
  ('song_layers_notify_added'),
  -- The scenario inserts a song claiming the wrong account, then moves one
  -- across an account boundary, and asserts the account followed both times.
  ('projects_account_follows_room'),
  -- The scenario has two accounts accept invitations to one Room and
  -- asserts they came out with distinct colours.
  ('room_members_assign_colour'),
  ('project_members_assign_colour'),
  -- The scenario posts an open ask and a specific one, and asserts both
  -- reached the song activity stream and the rest of the room.
  ('project_asks_announce'),
  -- 0110. The scenario replies to the open ask from both sides and asserts
  -- who was told each time, and who was not.
  ('ask_replies_announce'),
  -- 0112. The scenario sends one message and asserts the other person was
  -- told under the sender's name, and the sender was not.
  ('direct_messages_announce'),
  ('room_messages_announce'),
  -- 0113. The scenario has an outsider nod with a line and the owner nod
  -- their own song, and asserts one project update, then none for a re-save.
  ('project_nods_announce'),
  -- 0115. The scenario leaves a note for a bass player, toggles the bass
  -- player's listing, and asserts one introduction, then none for a repeat.
  ('profiles_match_wants'),
  -- 0132. The scenario asks, answers, removes, asks again and withdraws, and
  -- asserts who was told each time, that a repeat within a day told nobody,
  -- and that answered and withdrawn requests took their cards with them.
  ('connections_announce'),
  ('connections_forget_request'),
  -- Fires on every notification the scenario causes, with push_config
  -- set at the top of it so the delivery path actually runs.
  ('notifications_deliver'),
  -- The scenario adds a good link and is refused a bad one.
  ('profile_links_platform'),
  ('profile_links_capped'),
  -- The collaboration ledger (0093). The scenario asks, is accepted, and
  -- has somebody share a take on a song that is not theirs — then deletes
  -- that account and asserts the ledger went with it. These three are the
  -- only writers of the table, so a trigger that stopped firing would be a
  -- memory quietly filling with gaps and nothing else would notice.
  ('project_asks_remember'),
  ('project_asks_remember_answer'),
  ('song_layers_remember_delivery'),
  -- 0104. The scenario shares two takes and asserts each became news exactly
  -- once, that re-writing shared_at on an already-shared take does not
  -- announce it twice, and that a private take never reaches the feed at all.
  ('song_layers_remember_event'),
  ('song_layers_remember_event_on_share'),
  -- 0141. The scenario pins notes on a shared take, on a draft and on the
  -- song's own recording, and asserts who was told each time and who was not.
  ('moment_notes_announce'),
  -- 0141. The scenario pins on a draft, shares that take, and asserts the
  -- note stayed its author's alone -- which is this trigger's whole job.
  ('moment_notes_freeze_audience'),
  -- 0142. The scenario tries to put somebody else's song on the Open Mic and
  -- on the showcase with a plain update, the way 0005's policy allows, and
  -- asserts both were refused. That is the trigger's whole reason for
  -- existing: the two functions refuse a cover as well, so if this stopped
  -- firing every other assertion in that block would still pass.
  ('projects_no_cover_in_public'),
  -- 0145. The scenario sends a writing ask, then tries to turn it into a
  -- playing one as the role that owns the table, and asserts both the refusal
  -- and that the row is unchanged afterwards. The same block closes an ask,
  -- which is the update this trigger sees most and has to wave through.
  ('project_asks_terms_are_fixed'),
  -- 0154. The scenario has the room's owner try to open somebody else's
  -- opinions and asserts the refusal, has the asker open them, and asserts
  -- a second "I'm ready" leaves the first one's time alone.
  ('project_asks_opinions_open'),
  -- 0155. The scenario has the owner try to put a song up, and show it,
  -- with a plain update while a bandmate's part is unanswered, and asserts
  -- both refusals. The two functions refuse as well, so without this the
  -- rest of that block would pass with the trigger dead.
  ('projects_wait_for_everyone'),
  -- 0155. The scenario shares a draft onto a song that is already out and
  -- asserts its player was asked once, and that the part stayed with the
  -- room until they answered.
  ('song_layers_ask_on_share'),
  -- 0158. The scenario has a player write the seal's day with a plain
  -- update -- one that has passed, one forty years off -- and share a sealed
  -- take, and asserts all three refusals, then rewrites the day it was
  -- sealed and asserts it did not move, then ends the seal and asserts the
  -- retention clock and its warning started over. seal_take and unseal_take
  -- do none of that themselves, so with this dead the block fails rather
  -- than passing quietly.
  ('song_layers_a_seal_has_a_day'),
  -- 0166. The scenario has somebody in two bands leave one and asserts that
  -- band's songs left their set while the other band's stayed, that the
  -- other member's set was untouched, that the card stopped offering them,
  -- and that rejoining brought nothing back. Then the room's owner removes
  -- somebody, which is the other way out and the same trigger.
  ('room_members_leaving_takes_the_songs'),
  -- 0166. The scenario moves a song into a room one set's owner is in and
  -- another's is not, and asserts it left exactly one of the two sets.
  ('projects_a_moved_song_leaves_sets');

-- Not fired, and a deliberate choice rather than an oversight. Each of these
-- is the same one-line `set updated_at = now()` body on a table the scenario
-- has no reason to build. If one of them ever grows a real body, move it up.
insert into smoke_acknowledged (name, reason) values
  ('setlists_set_updated_at',                'timestamp only; setlists are not on the song write path'),
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
