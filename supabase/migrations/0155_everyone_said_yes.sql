-- Everyone on it says yes before it goes out.
--
-- Every Musician, Same Song, 17 September 2026: "consent that knows who
-- hears it", and the one rule the plan asks for before any multi-person
-- publishing -- "everyone on it said yes, and anyone can pull their part".
-- The audit left it as a decision (CO2) and the plan adopted it.
--
-- Until now a room owner could put a band song on the Open Mic and every
-- shared take on it became audible to strangers on the owner's say-so. 0067
-- was careful that a *private* take never went out that way ("the owner
-- offers the song, never somebody else's unheard draft"), and stopped there:
-- a take you had shared with four people in a room was, from that moment,
-- the owner's to put in front of everybody. Nobody was asked. Nobody was
-- told. The showcase (0088) is the same door opened wider, and any member
-- can open it.
--
-- **The rule.** Before a song goes in front of strangers, everybody with a
-- shared take on it is asked, once, in a plain notification that is
-- answered in one tap. Until they answer, the song does not go out. A yes
-- puts their part on it; a no leaves their part with the room and the song
-- can still go out without it. Anybody can change their answer afterwards:
-- pulling a part takes it off the public song and the song stays up without
-- it -- or comes down, if nothing audible is left. No deadline, no
-- reminder, no count of who has answered anywhere: the owner sees names and
-- words.
--
-- **Where the yes lives.** One row per take, because consent is about a
-- recording, not a person in general: somebody who said yes to their bass
-- has not said yes to the harmony they share next week. The question goes
-- to a person, though, once, however many takes they have on the song --
-- and their answer lands on all of them.
--
-- **What "in front of strangers" means.** Both public surfaces. The Open Mic
-- reaches every signed-in account and the showcase reaches the open
-- internet through `public_songs` (0096); a promise made about one of them
-- and not the other is not a promise. So the same rows gate both, the same
-- function asks on both paths, and the same table trigger refuses a plain
-- update to either column -- 0005's policy lets an owner set them directly,
-- and 0142 already learned that a rule living only in the functions is one
-- request away from nothing.
--
-- **Your own parts.** Putting a song out is your yes to the parts you
-- recorded on it. It is recorded as a row like everybody else's, so "each
-- person's yes is theirs" is literally true of the owner too, and the
-- owner can pull their own part the same way.
--
-- **Demo accounts** (0078) have nothing to consent to: they are the app's
-- own invention, seeded to keep the Open Mic from being empty for the
-- first real people. Their takes count as agreed without a row, so the
-- seeder's plain update still works and the demo songs still play.
--
-- **A take whose player is gone.** 0065 keeps a shared take when the account
-- that made it is deleted, with `recorded_by` set to null: the band cannot
-- re-record a bass part. There is nobody to ask about it and nobody who
-- said yes, so it stays with the room -- never audible to strangers -- and
-- the song does not wait on it. The one thing that must never happen is a
-- consent row with no person on it, which is what a question addressed to
-- a null player would be.
--
-- **The audio, not only the row.** A take that is not public is hidden
-- three ways -- its row, its bytes, and the fallback in `private.song_audio`
-- that plays the earliest shared take as "the song" when a song has no
-- reference recording. Missing any one of those is the classic version of
-- this bug: a page that says a part is gone and plays it anyway.

-- Added first and used only inside plpgsql bodies, which are planned on
-- first call in a later transaction. Nothing in this file calls them, so it
-- holds under both runners (see 0141 on why that matters).
alter type public.notification_type add value if not exists 'part_question';

-- ---------------------------------------------------------------------
-- One row per take
-- ---------------------------------------------------------------------

create table if not exists public.take_consents (
  layer_id uuid primary key references public.song_layers(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  asked_at timestamptz not null default now(),
  -- Who asked, or null when nobody did: a take shared onto a song that was
  -- already out there asks its own player, and there is no asker to name.
  asked_by uuid references public.profiles(id) on delete set null,
  answered_at timestamptz,
  -- Null until answered. True is "with my part", false is "leave my part
  -- out" -- and the second one is a real answer, not a dismissal.
  agreed boolean,
  check ((answered_at is null) = (agreed is null))
);

comment on table public.take_consents is
  'Whether the person who recorded a take has said their part may go in '
  'front of strangers (the Open Mic and the showcase). One row per take, '
  'asked once, answerable any time. Every Musician, Same Song, 17 September '
  '2026.';

create index if not exists take_consents_person_idx
  on public.take_consents (user_id, project_id);
create index if not exists take_consents_project_idx
  on public.take_consents (project_id);

-- The storage policy below looks a take up by its object path, which
-- nothing indexed before.
create index if not exists song_layers_storage_path_idx
  on public.song_layers (storage_path);

alter table public.take_consents enable row level security;

-- Your own rows and nothing else. Who has answered on a song is read
-- through song_audience, which already decides who may ask that; the
-- inbox's questions come through part_questions_for_me. Nobody writes this
-- table directly: every row is made and answered by the functions below.
drop policy if exists take_consents_read_own on public.take_consents;
create policy take_consents_read_own on public.take_consents
for select to authenticated using (user_id = (select auth.uid()));

revoke all on table public.take_consents from public, anon;
grant select on table public.take_consents to authenticated;

-- ---------------------------------------------------------------------
-- The one question every surface asks
-- ---------------------------------------------------------------------

-- Whether a take may be heard by people the room never chose. Shared, and
-- either its player said yes or its player is one of the app's own demo
-- accounts. A take whose player is gone (0065) has neither, and reads as
-- not public without a special case. Used by the read policies, the storage
-- policy, the audio fallback and the public lists, so that all of them can
-- only ever agree.
create or replace function private.take_is_public(target_layer uuid)
returns boolean
language sql
stable
security definer set search_path = ''
as $fn$
  select exists (
    select 1
    from public.song_layers l
    left join public.take_consents c on c.layer_id = l.id
    left join public.profiles pr on pr.id = l.recorded_by
    where l.id = target_layer
      and l.shared_at is not null
      and (c.agreed is true or coalesce(pr.is_demo, false))
  );
$fn$;

revoke all on function private.take_is_public(uuid) from public, anon;
grant execute on function private.take_is_public(uuid) to authenticated;

-- Whether anybody with a shared take on a song has not answered yet. This
-- is the whole gate: a song waits while this is true, and nothing else
-- about the answers matters to whether it goes out. A take with no player
-- left to ask is not anybody.
create or replace function private.waiting_on_anyone(target_project uuid)
returns boolean
language sql
stable
security definer set search_path = ''
as $fn$
  select exists (
    select 1
    from public.song_layers l
    left join public.take_consents c on c.layer_id = l.id
    left join public.profiles pr on pr.id = l.recorded_by
    where l.project_id = target_project
      and l.shared_at is not null
      and l.recorded_by is not null
      and not coalesce(pr.is_demo, false)
      and (c.layer_id is null or c.answered_at is null)
  );
$fn$;

revoke all on function private.waiting_on_anyone(uuid)
  from public, anon, authenticated;

-- "bass", "bass and vocal", "bass, keys and vocal", in the order given. The
-- one part with no name of its own ('other') reads as "part", so a sentence
-- never says "with your other on it".
create or replace function private.parts_in_words(parts text[])
returns text
language sql
immutable
set search_path = ''
as $fn$
  select case
    when cardinality(named.list) = 0 then 'part'
    when cardinality(named.list) = 1 then named.list[1]
    else array_to_string(named.list[1:cardinality(named.list) - 1], ', ')
         || ' and ' || named.list[cardinality(named.list)]
  end
  from (
    select coalesce(
      array_agg(case when p = 'other' then 'part' else p end order by n),
      '{}'::text[]
    ) as list
    from unnest(coalesce(parts, '{}'::text[])) with ordinality as u(p, n)
  ) named;
$fn$;

revoke all on function private.parts_in_words(text[])
  from public, anon, authenticated;

-- Asks everybody with a shared take on a song, once, and says whether the
-- song may go out now. Called on both ways out of the room.
--
-- The caller's own parts are answered yes by the act: publishing is your
-- yes. That also answers a question the song has already put to you (a
-- take you shared after it went out), and never touches a no you gave on
-- purpose. Everybody else gets one question per person, whatever the number
-- of takes, and only for takes that have never been asked about -- so
-- pressing "Put it on the Open Mic" twice nags nobody.
create or replace function private.ask_everyone_on(target_project uuid)
returns boolean
language plpgsql
security definer set search_path = ''
as $fn$
declare
  me uuid := auth.uid();
  song record;
  asker text;
  person record;
begin
  select p.id, p.room_id, p.title into song
  from public.projects p
  where p.id = target_project;

  if song.id is null then
    return false;
  end if;

  insert into public.take_consents as c
    (layer_id, project_id, user_id, asked_by, answered_at, agreed)
  select l.id, l.project_id, l.recorded_by, me, now(), true
  from public.song_layers l
  where l.project_id = target_project
    and l.shared_at is not null
    and l.recorded_by = me
  on conflict (layer_id) do update
    set answered_at = now(), agreed = true
    where c.answered_at is null;

  asker := coalesce(
    (select pr.display_name from public.profiles pr where pr.id = me),
    'Somebody'
  );

  -- Never a take whose player is gone (0065): there is nobody to write a
  -- row for, and a question with no person on it is a not-null violation
  -- that would stop the owner's own song going up.
  for person in
    select l.recorded_by as id,
           array_agg(distinct l.part order by l.part) as parts
    from public.song_layers l
    left join public.profiles pr on pr.id = l.recorded_by
    where l.project_id = target_project
      and l.shared_at is not null
      and l.recorded_by is not null
      and l.recorded_by is distinct from me
      and not coalesce(pr.is_demo, false)
      and not exists (
        select 1 from public.take_consents c where c.layer_id = l.id
      )
    group by l.recorded_by
  loop
    insert into public.take_consents (layer_id, project_id, user_id, asked_by)
    select l.id, l.project_id, l.recorded_by, me
    from public.song_layers l
    where l.project_id = target_project
      and l.shared_at is not null
      and l.recorded_by = person.id
      and not exists (
        select 1 from public.take_consents c where c.layer_id = l.id
      );

    -- One plain question. It says what would happen, that it waits, and
    -- that a yes is not for good -- the three things somebody deciding
    -- wants to know, and nothing about anybody else's answer.
    perform private.notify_user(
      person.id,
      'part_question',
      asker || ' wants to put ' || coalesce(song.title, 'a song')
        || ' in front of everybody',
      'With your ' || private.parts_in_words(person.parts) || ' on it. It '
        || 'waits until you answer, and you can take your part back off it '
        || 'later.',
      song.room_id,
      song.id,
      null,
      me
    );
  end loop;

  return not private.waiting_on_anyone(target_project);
end;
$fn$;

revoke all on function private.ask_everyone_on(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The two ways out of the room
-- ---------------------------------------------------------------------

-- Restated from 0142, which is still its latest definition, with the gate
-- added after the two refusals. Everything else -- the owner-only check, the
-- cover refusal, the `coalesce` that makes a second press a no-op, the
-- returned timestamp -- is 0142's and 0067's.
--
-- Null is the new answer: everybody has been asked and the song is not up
-- yet. Not an error, because nothing went wrong -- the app reads who is
-- still to answer from song_audience and says so.
create or replace function public.put_on_open_mic(target_project uuid)
returns timestamptz
language plpgsql
security definer
set search_path = public
as $$
declare
  song record;
  when_shared timestamptz;
begin
  select p.id, p.room_id, p.title, p.song_origin into song
  from public.projects p where p.id = target_project;

  if song.id is null then
    raise exception 'That song does not exist.' using errcode = '22023';
  end if;

  -- The catalog owner only. An editor can record on a song; deciding that
  -- strangers may hear it is a different size of decision and belongs to
  -- whoever owns the catalog it lives in.
  if private.room_role_for(song.room_id) is distinct from 'owner' then
    raise exception 'Only the catalog owner can put a song on the Open Mic.'
      using errcode = '42501';
  end if;

  -- Somebody else's song does not go in front of strangers. The Open Mic is
  -- the one place in this app a song is audible to people the room never
  -- chose, and a song the room did not write is the one kind that must not
  -- get there. Refused here as a sentence, and again by the trigger above as
  -- a rule, because this function is not the only way in.
  if song.song_origin is not distinct from 'cover' then
    raise exception 'Songs by somebody else stay with the people you choose.'
      using errcode = '42501';
  end if;

  -- Everybody with a part on it is asked first. The song waits.
  if not private.ask_everyone_on(song.id) then
    return null;
  end if;

  update public.projects
  set open_mic_at = coalesce(open_mic_at, now())
  where id = target_project
  returning open_mic_at into when_shared;

  return when_shared;
end;
$$;

revoke all on function public.put_on_open_mic(uuid) from public, anon;
grant execute on function public.put_on_open_mic(uuid) to authenticated;

-- Restated from 0142, which is still its latest definition, with the gate
-- added between the cover refusal and the update. The membership check that
-- 0088 kept inside the update's where clause is asked once more before
-- anybody is asked anything, so a stranger's call still ends in 'No such
-- song.' and never in four people being told about it.
--
-- Returning without showing is the same "not yet" put_on_open_mic gives as
-- null: the app reads who is still to answer from song_audience. The song
-- is not finished by the attempt either -- showing implies finishing, and
-- nothing was shown.
create or replace function public.show_song(target_project uuid)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  -- Somebody else's song is not shown to everybody either, and this is the
  -- surface that reaches furthest: `public_songs` (0096) is granted to anon,
  -- so showing a song makes a page anybody can open.
  --
  -- Checked before the update so this reads as a sentence, and gated on the
  -- same membership the update uses so a refusal never tells somebody
  -- outside the room what is in it -- a stranger still gets 'No such song.'
  if exists (
    select 1 from public.projects p
    where p.id = target_project
      and p.deleted_at is null
      and (private.is_room_member(p.room_id) or p.created_by = auth.uid())
      and p.song_origin is not distinct from 'cover'
  ) then
    raise exception 'Songs by somebody else stay with the people you choose.'
      using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.projects p
    where p.id = target_project
      and p.deleted_at is null
      and (private.is_room_member(p.room_id) or p.created_by = auth.uid())
  ) then
    raise exception 'No such song.' using errcode = '22023';
  end if;

  if not private.ask_everyone_on(target_project) then
    return;
  end if;

  update public.projects
  set showcased_at = now(),
      -- Finishing it if somebody skipped that step. Showing something is a
      -- stronger statement than finishing it, so it implies it.
      finished_at = coalesce(finished_at, now())
  where id = target_project
    and deleted_at is null
    and (private.is_room_member(room_id) or created_by = auth.uid());

  if not found then
    raise exception 'No such song.' using errcode = '22023';
  end if;
end;
$fn$;

revoke all on function public.show_song(uuid) from public, anon;
grant execute on function public.show_song(uuid) to authenticated;

-- `take_off_open_mic` (0067) and `unshow_song` (0088) are deliberately
-- untouched, and so are the answers when a song comes down: a yes given is
-- still given, and a song put back up a month later asks nobody again.
-- Anybody who has changed their mind changes their answer.

-- ---------------------------------------------------------------------
-- The rule at the table
-- ---------------------------------------------------------------------

-- `projects_update_editors` (0005) lets an owner or editor write this table
-- directly through PostgREST, columns and all, so the two functions above
-- are not the only way a song goes public. This refuses the crossing --
-- from private to either public surface -- while anybody on the song has
-- not answered. Taking a song down, answering whose song it is, and every
-- other update pass straight through.
create or replace function private.wait_for_everyone()
returns trigger
language plpgsql
security definer set search_path = ''
as $fn$
begin
  if ((new.open_mic_at is not null and old.open_mic_at is null)
      or (new.showcased_at is not null and old.showcased_at is null))
     and private.waiting_on_anyone(new.id) then
    raise exception 'Everybody with a part on it is asked first.'
      using errcode = '42501';
  end if;
  return new;
end;
$fn$;

revoke all on function private.wait_for_everyone()
  from public, anon, authenticated;

drop trigger if exists projects_wait_for_everyone on public.projects;
create trigger projects_wait_for_everyone
before update on public.projects
for each row execute function private.wait_for_everyone();

-- ---------------------------------------------------------------------
-- A take shared onto a song that is already out there
-- ---------------------------------------------------------------------

-- Sharing tells the room (0057). When the room's song is already in front
-- of strangers, sharing would also have published the take -- silently, to
-- people the player never chose. So the take stays with the room and its
-- player is asked the same one-tap question, whoever they are: one rule,
-- with no special case for the person who put the song up. Nothing is
-- asked twice: a take that already has a row keeps its answer.
create or replace function private.ask_about_a_shared_take()
returns trigger
language plpgsql
security definer set search_path = ''
as $fn$
declare
  song record;
begin
  -- The same crossing notify_layer_added (0057) looks for: shared on
  -- insert, or the move from private to shared. Renaming a shared take is
  -- not sharing it again.
  if new.shared_at is null then
    return new;
  end if;
  if tg_op = 'UPDATE' and old.shared_at is not null then
    return new;
  end if;

  select p.id, p.room_id, p.title, p.open_mic_at, p.showcased_at into song
  from public.projects p
  where p.id = new.project_id;

  if song.open_mic_at is null and song.showcased_at is null then
    return new;
  end if;
  -- Nobody to ask: a demo account, or a take whose player is gone.
  if new.recorded_by is null or coalesce(
       (select pr.is_demo from public.profiles pr where pr.id = new.recorded_by),
       false) then
    return new;
  end if;

  insert into public.take_consents (layer_id, project_id, user_id)
  values (new.id, new.project_id, new.recorded_by)
  on conflict (layer_id) do nothing;

  if not found then
    return new;
  end if;

  -- No actor: this is the one question a person is told about their own
  -- doing, and notify_user would otherwise skip it as self-notification.
  perform private.notify_user(
    new.recorded_by,
    'part_question',
    'Your ' || private.parts_in_words(array[new.part]) || ' on '
      || coalesce(song.title, 'a song'),
    coalesce(song.title, 'The song') || ' is out there already. Your part '
      || 'goes out with it when you say yes, and stays with the room until '
      || 'then.',
    song.room_id,
    song.id,
    null,
    null
  );

  return new;
end;
$fn$;

revoke all on function private.ask_about_a_shared_take()
  from public, anon, authenticated;

drop trigger if exists song_layers_ask_on_share on public.song_layers;
create trigger song_layers_ask_on_share
after insert or update of shared_at on public.song_layers
for each row execute function private.ask_about_a_shared_take();

-- ---------------------------------------------------------------------
-- Answering, and changing your mind
-- ---------------------------------------------------------------------

-- Yes or no, for every take of yours on the song, now and whenever you
-- like. A no on a song that is already out takes your part off it; if that
-- leaves nothing to hear -- no reference recording and no other public
-- part -- the song comes down, because a page with nothing to play is a
-- page about a title. The owners of the room are told in plain words,
-- through the switch every other piece of news about their song rides on.
create or replace function public.answer_for_my_part(
  target_project uuid,
  in_yes boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  me uuid := auth.uid();
  song record;
  touched integer;
  up boolean;
  came_down boolean := false;
  who text;
  parts text;
  said_title text;
  said_body text;
  owner record;
begin
  if in_yes is null then
    raise exception 'Yes or no.' using errcode = '22023';
  end if;

  select p.id, p.title, p.room_id, p.open_mic_at, p.showcased_at into song
  from public.projects p
  where p.id = target_project and p.deleted_at is null;

  if song.id is null then
    raise exception 'That song does not exist.' using errcode = '22023';
  end if;

  -- Your rows only, whoever is asking. The owner's answer never reaches
  -- anybody else's take, which is the whole of what "each person's yes is
  -- theirs" means.
  update public.take_consents c
  set answered_at = now(), agreed = in_yes
  where c.project_id = target_project and c.user_id = me;

  get diagnostics touched = row_count;
  if touched = 0 then
    raise exception 'Nobody has asked about your part on this song.'
      using errcode = '22023';
  end if;

  up := song.open_mic_at is not null or song.showcased_at is not null;

  if not in_yes and up
     and not exists (
       select 1 from public.project_audio_references r
       join public.files f on f.id = r.file_id
       where r.project_id = target_project
     )
     and not exists (
       select 1 from public.song_layers l
       where l.project_id = target_project
         and private.take_is_public(l.id)
     ) then
    update public.projects
    set open_mic_at = null, showcased_at = null
    where id = target_project;
    came_down := true;
  end if;

  who := coalesce(
    (select pr.display_name from public.profiles pr where pr.id = me),
    'Somebody'
  );
  parts := private.parts_in_words((
    select array_agg(distinct l.part order by l.part)
    from public.song_layers l
    join public.take_consents c on c.layer_id = l.id
    where c.project_id = target_project
      and c.user_id = me
      and l.shared_at is not null
  ));

  if in_yes then
    said_title := who || ' said yes';
    said_body := case
      when up then 'Their ' || parts || ' is on ' || song.title
        || ' for everybody now.'
      else song.title || ' can go out with their ' || parts || ' on it.'
    end;
  else
    said_title := who || ' is leaving their part out';
    said_body := case
      when came_down then 'Nothing was left to hear on ' || song.title
        || ', so it came down.'
      when up then song.title || ' is still up, without their ' || parts
        || '.'
      else song.title || ' can still go out without it.'
    end;
  end if;

  for owner in
    select m.user_id from public.room_members m
    where m.room_id = song.room_id and m.role = 'owner'
  loop
    perform private.notify_user(
      owner.user_id, 'project_update', said_title, said_body,
      song.room_id, song.id, null, me
    );
  end loop;
end;
$fn$;

revoke all on function public.answer_for_my_part(uuid, boolean)
  from public, anon;
grant execute on function public.answer_for_my_part(uuid, boolean)
  to authenticated;

-- The questions waiting on you, one per song, for the card in the inbox.
-- Takes that have since been unshared are not on the list: there is nothing
-- to answer about a part the room can no longer hear.
create or replace function public.part_questions_for_me()
returns table (
  project_id uuid,
  song_title text,
  asked_by uuid,
  asked_by_name text,
  parts text[],
  asked_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $fn$
  with mine as (
    select
      c.project_id,
      p.title,
      min(c.asked_at) as asked_at,
      (array_agg(c.asked_by order by c.asked_at))[1] as asked_by,
      array_agg(distinct l.part order by l.part) as parts
    from public.take_consents c
    join public.song_layers l on l.id = c.layer_id
    join public.projects p on p.id = c.project_id
    where c.user_id = (select auth.uid())
      and c.answered_at is null
      and l.shared_at is not null
      and p.deleted_at is null
    group by c.project_id, p.title
  )
  select
    m.project_id,
    m.title,
    m.asked_by,
    pr.display_name,
    m.parts,
    m.asked_at
  from mine m
  left join public.profiles pr on pr.id = m.asked_by
  order by m.asked_at;
$fn$;

revoke all on function public.part_questions_for_me() from public, anon;
grant execute on function public.part_questions_for_me() to authenticated;

-- ---------------------------------------------------------------------
-- Who has answered, in words
-- ---------------------------------------------------------------------

-- Restated from 0089, which is still its latest definition, with two
-- columns added: everybody else with a part on the song and what they said
-- (waiting, yes or no), and your own answer, or null when nobody has asked
-- you. Names and words, never a number -- the control shows "Jess has not
-- answered yet", not "1 of 2".
--
-- Dropped first, because `create or replace` cannot change the shape of a
-- `returns table`.
drop function if exists public.song_audience(uuid);

create function public.song_audience(target_project uuid)
returns table (
  reach text,
  room_name text,
  room_icon text,
  listeners jsonb,
  on_open_mic boolean,
  on_showcase boolean,
  open_mic_at timestamptz,
  answers jsonb,
  my_answer text
)
language sql
stable
security definer
set search_path = public
as $fn$
  with the_song as (
    select p.id, p.room_id, p.open_mic_at, p.showcased_at, p.created_by
    from public.projects p
    where p.id = target_project
      and p.deleted_at is null
      and (
        private.is_room_member(p.room_id)
        or private.is_project_member(p.id)
      )
  ),
  hearers as (
    select m.user_id, pr.display_name, pr.avatar_path, false as song_only
    from public.room_members m
    join the_song s on s.room_id = m.room_id
    left join public.profiles pr on pr.id = m.user_id
    union
    select pm.user_id, pr.display_name, pr.avatar_path, true
    from public.project_members pm
    join the_song s on s.id = pm.project_id
    left join public.profiles pr on pr.id = pm.user_id
    where not exists (
      select 1 from public.room_members m2
      join the_song s2 on s2.room_id = m2.room_id
      where m2.user_id = pm.user_id
    )
  ),
  others as (
    select * from hearers where user_id is distinct from (select auth.uid())
  ),
  -- One line per person with a shared take that has been asked about.
  -- Waiting while any of their takes is unanswered; yes while any part of
  -- theirs is out there; otherwise no.
  said as (
    select
      c.user_id,
      coalesce(pr.display_name, 'Somebody') as name,
      case
        when bool_or(c.answered_at is null) then 'waiting'
        when bool_or(c.agreed) then 'yes'
        else 'no'
      end as answer
    from public.take_consents c
    join the_song s on s.id = c.project_id
    join public.song_layers l on l.id = c.layer_id
    left join public.profiles pr on pr.id = c.user_id
    where l.shared_at is not null
    group by c.user_id, pr.display_name
  )
  select
    case
      -- Either public surface is "anyone". Showing finished work reaches
      -- exactly as far as the Open Mic does, and a dial that said otherwise
      -- would be understating reach — the one direction it must never err in.
      when s.open_mic_at is not null or s.showcased_at is not null
        then 'anyone'
      when exists (select 1 from others where song_only) then 'invited'
      when exists (select 1 from others) then 'room'
      else 'just_you'
    end,
    r.name,
    r.icon,
    coalesce(
      (select jsonb_agg(
                jsonb_build_object(
                  'id', o.user_id,
                  'name', coalesce(o.display_name, 'Somebody'),
                  'avatar_path', o.avatar_path,
                  'song_only', o.song_only
                )
                order by o.song_only, coalesce(o.display_name, 'Somebody')
              )
         from others o),
      '[]'::jsonb
    ),
    s.open_mic_at is not null,
    s.showcased_at is not null,
    s.open_mic_at,
    coalesce(
      (select jsonb_agg(
                jsonb_build_object(
                  'id', a.user_id,
                  'name', a.name,
                  'answer', a.answer
                )
                order by a.name
              )
         from said a
        where a.user_id is distinct from (select auth.uid())),
      '[]'::jsonb
    ),
    (select a.answer from said a where a.user_id = (select auth.uid()))
  from the_song s
  left join public.rooms r on r.id = s.room_id;
$fn$;

revoke all on function public.song_audience(uuid) from public, anon;
grant execute on function public.song_audience(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- What a stranger can hear
-- ---------------------------------------------------------------------

-- Both restated from 0094, which is still their latest definition, with the
-- public-surface branch narrowed from "shared" to "public": shared, and
-- its player said yes. The branch for somebody asked to play on the song
-- (0094) is left as it was -- that consent is the room's, addressed to one
-- named person, and it is the room's shared takes it covers.
drop policy if exists song_layers_read_members on public.song_layers;
create policy song_layers_read_members on public.song_layers
for select to authenticated using (
  (
    shared_at is not null
    or recorded_by = (select auth.uid())
  )
  and exists (
    select 1 from public.projects p
    where p.id = project_id
      and (
        private.is_room_member(p.room_id)
        or private.is_project_member(p.id)
        -- On either public surface: only a take whose player said yes. A
        -- private take stays private, and so does a shared one until the
        -- person who played it agrees -- the room offers the song, never
        -- somebody's part.
        or ((p.open_mic_at is not null or p.showcased_at is not null)
            and private.take_is_public(song_layers.id))
        or (private.was_asked(p.id) and shared_at is not null)
      )
  )
);

-- And the audio, or a part is gone from the page and still plays for
-- anybody holding its path. The public-surface branch used to admit every
-- object under a public song's folder, drafts included; it now admits a
-- take's file exactly as far as the policy above admits its row.
drop policy if exists room_files_read_members on storage.objects;
create policy room_files_read_members on storage.objects
for select to authenticated using (
  bucket_id = 'room-files'
  and (
    private.is_room_member(private.as_uuid((storage.foldername(name))[1]))
    or (
      array_length(storage.foldername(name), 1) >= 2
      and private.is_project_member(private.as_uuid((storage.foldername(name))[2]))
    )
    or exists (
      select 1
      from public.files f
      join public.projects p on p.id = f.project_id
      where f.storage_path = objects.name
        and (private.is_room_member(p.room_id) or private.is_project_member(p.id))
    )
    -- Paths are {room}/{project}/..., so the project is the second segment.
    or (
      array_length(storage.foldername(name), 1) >= 2
      and exists (
        select 1 from public.projects p
        where p.id = private.as_uuid((storage.foldername(name))[2])
          and (p.open_mic_at is not null or p.showcased_at is not null
               or private.was_asked(p.id))
      )
      and not exists (
        select 1 from public.song_layers l
        where l.storage_path = objects.name
          and not (
            private.take_is_public(l.id)
            or (l.shared_at is not null and private.was_asked(l.project_id))
          )
      )
    )
  )
);

-- Restated from 0073, which is still its latest definition. The fallback
-- take now depends on who is asking, the same way the policies do: somebody
-- in the room, on the song or asked onto it hears the earliest shared take;
-- anybody else hears the earliest take its player agreed to. Without this
-- a stranger's page would name a path the storage policy then refuses,
-- which is a play button that does nothing.
create or replace function private.song_audio(target_project uuid)
returns table (storage_path text, duration_ms integer)
language sql
stable
security definer
set search_path = public
as $fn$
  select
    coalesce(f.storage_path, take.storage_path),
    coalesce(r.duration_ms, take.duration_ms)
  from public.projects p
  left join public.project_audio_references r on r.project_id = p.id
  left join public.files f on f.id = r.file_id
  left join lateral (
    select l.storage_path, l.duration_ms
    from public.song_layers l
    where l.project_id = p.id
      and l.shared_at is not null
      and (
        private.is_room_member(p.room_id)
        or private.is_project_member(p.id)
        or private.was_asked(p.id)
        or private.take_is_public(l.id)
      )
    order by l.shared_at
    limit 1
  ) take on true
  where p.id = target_project
  limit 1;
$fn$;

revoke all on function private.song_audio(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The lists that count or name the parts
-- ---------------------------------------------------------------------

-- Each restated from its latest definition with one change: where it read
-- "shared" as meaning "audible to strangers", it now reads the take's own
-- answer. A count that includes a pulled part is a list that says three
-- and plays two; a name on the showcase page is a claim about a person who
-- said no.

-- Restated from 0073, which is still its latest definition.
create or replace function public.open_mic_songs(
  in_part text default null,
  in_limit integer default 30,
  include_not_asking boolean default false
)
returns table (
  id uuid,
  title text,
  owner_id uuid,
  owner_name text,
  owner_avatar text,
  open_mic_at timestamptz,
  take_count bigint,
  asking_for text[],
  storage_path text,
  duration_ms integer
)
language sql
stable
security definer
set search_path = public
as $fn$
  select
    p.id,
    p.title,
    p.created_by,
    pr.display_name,
    pr.avatar_path,
    p.open_mic_at,
    (select count(*) from public.song_layers l
      where l.project_id = p.id and private.take_is_public(l.id)),
    coalesce(
      (select array_agg(distinct a.part)
         from public.project_asks a
        where a.project_id = p.id
          and a.status = 'open'
          and a.part is not null),
      '{}'::text[]
    ),
    audio.storage_path,
    audio.duration_ms
  from public.projects p
  left join public.profiles pr on pr.id = p.created_by
  left join lateral private.song_audio(p.id) audio on true
  where p.open_mic_at is not null
    and p.deleted_at is null
    and not private.blocked_between((select auth.uid()), p.created_by)
    and (
      in_part is null
      or exists (
        select 1 from public.project_asks a
        where a.project_id = p.id and a.status = 'open' and a.part = in_part
      )
    )
    and (
      include_not_asking
      or exists (
        select 1 from public.project_asks a
        where a.project_id = p.id and a.status = 'open'
      )
    )
  order by p.open_mic_at desc
  limit greatest(least(in_limit, 100), 1);
$fn$;

revoke all on function public.open_mic_songs(text, integer, boolean)
  from public, anon;
grant execute on function public.open_mic_songs(text, integer, boolean)
  to authenticated;

-- Restated from 0073, which is still its latest definition. A profile lists
-- the songs somebody's parts are out on, so a part they pulled no longer
-- puts the song on their page, and no longer names the part.
create or replace function public.songs_by(target_profile uuid)
returns table (
  id uuid,
  title text,
  owner_id uuid,
  owner_name text,
  owner_avatar text,
  open_mic_at timestamptz,
  take_count bigint,
  asking_for text[],
  their_parts text[],
  storage_path text,
  duration_ms integer
)
language sql
stable
security definer
set search_path = public
as $fn$
  select
    p.id,
    p.title,
    p.created_by,
    pr.display_name,
    pr.avatar_path,
    p.open_mic_at,
    (select count(*) from public.song_layers l
      where l.project_id = p.id and private.take_is_public(l.id)),
    coalesce(
      (select array_agg(distinct a.part)
         from public.project_asks a
        where a.project_id = p.id
          and a.status = 'open'
          and a.part is not null),
      '{}'::text[]
    ),
    coalesce(
      (select array_agg(distinct l.part::text)
         from public.song_layers l
        where l.project_id = p.id
          and l.recorded_by = target_profile
          and private.take_is_public(l.id)),
      '{}'::text[]
    ),
    audio.storage_path,
    audio.duration_ms
  from public.projects p
  left join public.profiles pr on pr.id = p.created_by
  left join lateral private.song_audio(p.id) audio on true
  where p.open_mic_at is not null
    and p.deleted_at is null
    and not private.blocked_between((select auth.uid()), target_profile)
    and (
      p.created_by = target_profile
      or exists (
        select 1 from public.song_layers l
        where l.project_id = p.id
          and l.recorded_by = target_profile
          and private.take_is_public(l.id)
      )
    )
  order by p.open_mic_at desc
  limit 30;
$fn$;

revoke all on function public.songs_by(uuid) from public, anon;
grant execute on function public.songs_by(uuid) to authenticated;

-- Restated from 0085, which is still its latest definition. The song a
-- person's card plays in find_musicians is the newest one they can be heard
-- on, and somebody who pulled their part cannot be heard on that song.
create or replace function private.heard_from(target_profile uuid)
returns table (
  song_id uuid,
  title text,
  storage_path text,
  duration_ms integer
)
language sql
stable
security definer
set search_path = public
as $fn$
  select p.id, p.title, audio.storage_path, audio.duration_ms
  from public.projects p
  left join lateral private.song_audio(p.id) audio on true
  where p.open_mic_at is not null
    and p.deleted_at is null
    and audio.storage_path is not null
    and (
      p.created_by = target_profile
      or exists (
        select 1 from public.song_layers l
        where l.project_id = p.id
          and l.recorded_by = target_profile
          and private.take_is_public(l.id)
      )
    )
  order by p.open_mic_at desc
  limit 1;
$fn$;

revoke all on function private.heard_from(uuid)
  from public, anon, authenticated;

-- Restated from 0096, which is still its latest definition. The players
-- named on a colabroom.com page are the ones whose parts are on it.
create or replace function public.public_songs(
  in_limit integer default 500,
  in_offset integer default 0
)
returns table (
  id uuid,
  title text,
  owner_id uuid,
  owner_name text,
  showcased_at timestamptz,
  duration_ms integer,
  musical_key text,
  players jsonb,
  made_here boolean
)
language sql
stable
security definer
set search_path = public
as $fn$
  select
    p.id,
    p.title,
    p.created_by,
    coalesce(pr.display_name, 'Somebody'),
    p.showcased_at,
    audio.duration_ms,
    r.musical_key,
    coalesce(
      (select jsonb_agg(distinct jsonb_build_object(
                'name', coalesce(who.display_name, 'Somebody')))
         from public.song_layers l
         join public.profiles who on who.id = l.recorded_by
        where l.project_id = p.id
          and private.take_is_public(l.id)
          and not who.is_demo
          and l.recorded_by is distinct from p.created_by),
      '[]'::jsonb
    ),
    (select count(distinct l.recorded_by) > 1
       from public.song_layers l
      where l.project_id = p.id and private.take_is_public(l.id))
  from public.projects p
  left join public.profiles pr on pr.id = p.created_by
  left join public.project_audio_references r on r.project_id = p.id
  left join lateral private.song_audio(p.id) audio on true
  where p.showcased_at is not null
    and p.deleted_at is null
    -- Nothing silent. A page for a song with nothing to play is a page about
    -- a title.
    and audio.storage_path is not null
    and coalesce(pr.is_demo, false) = false
  order by p.showcased_at desc
  limit greatest(least(in_limit, 2000), 1)
  offset greatest(in_offset, 0);
$fn$;

revoke all on function public.public_songs(integer, integer) from public;
grant execute on function public.public_songs(integer, integer)
  to anon, authenticated;

comment on function public.public_songs(integer, integer) is
  'Songs their owner put on the showcase, for the static pages on '
  'colabroom.com. Consent is showcased_at and each player''s own yes (0155); '
  'no lyrics, no demo accounts, and no viewer to filter blocks for.';

-- ---------------------------------------------------------------------
-- Songs that are already out there
-- ---------------------------------------------------------------------

-- Every shared take on a song that is public today gets its row. The
-- person the song belongs to -- the room's owner, or whoever started it --
-- put it up, and that was their yes; everybody else is asked, the way they
-- would have been. Their parts stay with the room until they answer, and
-- the question is the card in their inbox rather than a push: a push about
-- a song that went out weeks ago is not a plain question, and the enum
-- value at the top of this file cannot be used in this transaction anyway.
insert into public.take_consents
  (layer_id, project_id, user_id, answered_at, agreed)
select
  l.id,
  l.project_id,
  l.recorded_by,
  case when theirs.yes then now() end,
  case when theirs.yes then true end
from public.song_layers l
join public.projects p on p.id = l.project_id
join public.profiles pr on pr.id = l.recorded_by
cross join lateral (
  select
    l.recorded_by = p.created_by
    or exists (
      select 1 from public.room_members m
      where m.room_id = p.room_id
        and m.user_id = l.recorded_by
        and m.role = 'owner'
    ) as yes
) theirs
where l.shared_at is not null
  and not pr.is_demo
  and (p.open_mic_at is not null or p.showcased_at is not null)
on conflict (layer_id) do nothing;
