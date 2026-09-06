-- Blocking somebody, and reporting something.
--
-- Open Mic turned this into an app where strangers can find each other and
-- send each other things. Everything built for that so far has been about
-- making contact possible; this is the half that makes it safe to accept —
-- and it is a hard requirement rather than a nicety. App Store Review
-- Guideline 1.2 asks any app with user-generated content for a way to report
-- offensive content and a way to block abusive users. An app without them is
-- rejected rather than warned.
--
-- **A block has to actually do something.** The version that only hides a row
-- from one list is theatre: the person is still in search, can still open the
-- profile, can still send an ask. So every surface a stranger can reach
-- somebody through is filtered here, in the database, rather than in four
-- separate places in the client where the fifth one will be forgotten.
--
-- **A block is symmetric in effect and private in fact.** If you block
-- somebody, neither of you sees the other in Open Mic. Symmetric because a
-- one-way block leaves the blocked person able to watch; private because
-- "this person is no longer in your search results" must not be
-- distinguishable from "this person turned themselves off". Nobody is told
-- they were blocked.
--
-- **A block prevents new contact; it does not tear up an existing band.**
-- Blocking somebody you share a catalog with does not remove either of you
-- from it — that would let one member quietly evict another, and there is
-- already a right tool for wanting out of a room (0062's leave_room). What it
-- does is stop them finding you, asking you, or inviting you to anything new.

create table if not exists public.user_blocks (
  blocker_id uuid not null default auth.uid()
    references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  constraint user_blocks_not_self check (blocker_id <> blocked_id)
);

create index if not exists user_blocks_blocked_idx
  on public.user_blocks (blocked_id);

alter table public.user_blocks enable row level security;

-- You can see who you have blocked. You cannot see who has blocked you —
-- that is the whole point of it being quiet.
drop policy if exists user_blocks_read_own on public.user_blocks;
create policy user_blocks_read_own on public.user_blocks
for select to authenticated using (blocker_id = (select auth.uid()));

drop policy if exists user_blocks_write_own on public.user_blocks;
create policy user_blocks_write_own on public.user_blocks
for insert to authenticated with check (blocker_id = (select auth.uid()));

drop policy if exists user_blocks_delete_own on public.user_blocks;
create policy user_blocks_delete_own on public.user_blocks
for delete to authenticated using (blocker_id = (select auth.uid()));

-- The one predicate every stranger-facing function now asks.
--
-- Either direction counts. Kept in `private` so the client cannot call it and
-- use it as an oracle for who has blocked them.
create or replace function private.blocked_between(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.user_blocks
    where (blocker_id = a and blocked_id = b)
       or (blocker_id = b and blocked_id = a)
  );
$$;

revoke all on function private.blocked_between(uuid, uuid)
  from public, anon, authenticated;

create or replace function public.block_user(target_person uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if target_person = auth.uid() then
    raise exception 'You cannot block yourself.' using errcode = '22023';
  end if;

  insert into public.user_blocks (blocker_id, blocked_id)
  values (auth.uid(), target_person)
  on conflict do nothing;

  -- Anything already in flight between you stops being in flight. An open ask
  -- from somebody you have just blocked should not sit in your inbox waiting
  -- for an answer you are never going to give.
  update public.project_asks
  set status = 'declined', answered_at = now()
  where status = 'open'
    and ((asked_of = auth.uid() and asked_by = target_person)
      or (asked_by = auth.uid() and asked_of = target_person));

  update public.room_invites
  set status = 'declined', answered_at = now()
  where status = 'open'
    and ((invited_profile = auth.uid() and invited_by = target_person)
      or (invited_by = auth.uid() and invited_profile = target_person));
end;
$$;

revoke all on function public.block_user(uuid) from public, anon;
grant execute on function public.block_user(uuid) to authenticated;

create or replace function public.unblock_user(target_person uuid)
returns void
language sql
security invoker
set search_path = public
as $$
  delete from public.user_blocks
  where blocker_id = auth.uid() and blocked_id = target_person;
$$;

revoke all on function public.unblock_user(uuid) from public, anon;
grant execute on function public.unblock_user(uuid) to authenticated;

-- Who you have blocked, so the setting can be undone. Nobody wants a switch
-- they can turn on and never find again.
create or replace function public.people_i_blocked()
returns table (id uuid, display_name text, blocked_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select p.id, p.display_name, b.created_at
  from public.user_blocks b
  join public.profiles p on p.id = b.blocked_id
  where b.blocker_id = (select auth.uid())
  order by b.created_at desc;
$$;

revoke all on function public.people_i_blocked() from public, anon;
grant execute on function public.people_i_blocked() to authenticated;

-- ---------------------------------------------------------------------
-- Reporting
-- ---------------------------------------------------------------------

-- Somebody saying "this should not be here".
--
-- One table for every kind of thing that can be reported, because the queue
-- that matters is one queue. A report is never deleted by the person reported
-- and never visible to them.
create table if not exists public.content_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null default auth.uid()
    references public.profiles(id) on delete cascade,

  kind text not null check (kind in ('profile', 'song', 'take', 'link', 'message')),

  -- Exactly one of these, matching kind. Nullable rather than polymorphic
  -- text so the foreign keys still do their job and a report cannot outlive
  -- what it points at as a dangling id.
  target_profile uuid references public.profiles(id) on delete cascade,
  target_project uuid references public.projects(id) on delete cascade,
  target_layer uuid references public.song_layers(id) on delete cascade,
  target_link uuid references public.profile_links(id) on delete cascade,

  -- A short list, because a free-text-only report is one nobody can sort.
  -- 'copyright' is here on purpose: it is the first step of a takedown, and
  -- it needs to arrive somewhere rather than in an email nobody reads.
  reason text not null check (reason in (
    'copyright', 'abuse', 'harassment', 'spam', 'sexual', 'violence', 'other'
  )),
  detail text not null default '' check (char_length(detail) <= 1000),

  status text not null default 'open'
    check (status in ('open', 'actioned', 'dismissed')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,

  constraint content_reports_one_target check (
    (case when target_profile is null then 0 else 1 end)
  + (case when target_project is null then 0 else 1 end)
  + (case when target_layer   is null then 0 else 1 end)
  + (case when target_link    is null then 0 else 1 end) = 1
  )
);

create index if not exists content_reports_open_idx
  on public.content_reports (status, created_at desc);

alter table public.content_reports enable row level security;

-- Reports are write-only from the app's point of view. You can file one and
-- see your own; nobody can read anybody else's, including the person
-- reported. Reviewing happens with the service key, not from a phone.
drop policy if exists content_reports_read_own on public.content_reports;
create policy content_reports_read_own on public.content_reports
for select to authenticated using (reporter_id = (select auth.uid()));

drop policy if exists content_reports_insert_own on public.content_reports;
create policy content_reports_insert_own on public.content_reports
for insert to authenticated with check (reporter_id = (select auth.uid()));

create or replace function public.report_content(
  in_kind text,
  in_reason text,
  in_detail text default '',
  in_profile uuid default null,
  in_project uuid default null,
  in_layer uuid default null,
  in_link uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_report uuid;
begin
  insert into public.content_reports
    (reporter_id, kind, reason, detail,
     target_profile, target_project, target_layer, target_link)
  values
    (auth.uid(), in_kind, in_reason, left(trim(coalesce(in_detail, '')), 1000),
     in_profile, in_project, in_layer, in_link)
  returning id into new_report;

  return new_report;
end;
$$;

revoke all on function public.report_content(text, text, text, uuid, uuid, uuid, uuid)
  from public, anon;
grant execute on function public.report_content(text, text, text, uuid, uuid, uuid, uuid)
  to authenticated;

-- ---------------------------------------------------------------------
-- Making the block mean something
-- ---------------------------------------------------------------------
--
-- Every function a stranger can reach somebody through, re-declared with the
-- block applied. Doing it here rather than in the client is the point: there
-- are four of these today and a fifth will be written eventually, and the
-- filter belongs where the row is chosen.

create or replace function public.find_musicians(
  in_part text default null,
  in_city text default null,
  in_limit integer default 30
)
returns table (
  id uuid,
  display_name text,
  avatar_path text,
  city text,
  plays text[],
  parts_recorded jsonb,
  songs_played_on bigint,
  people_worked_with bigint
)
language sql
security definer
set search_path = public
as $$
  select
    p.id,
    p.display_name,
    p.avatar_path,
    case when p.location_visibility = 'public' then p.city else null end,
    p.plays,
    public.parts_recorded_by(p.id),
    (select count(distinct l.project_id) from public.song_layers l
      where l.recorded_by = p.id and l.shared_at is not null),
    (select count(distinct other.recorded_by)
       from public.song_layers mine
       join public.song_layers other on other.project_id = mine.project_id
      where mine.recorded_by = p.id
        and mine.shared_at is not null
        and other.shared_at is not null
        and other.recorded_by <> p.id)
  from public.profiles p
  where p.discoverable
    -- Blocked in either direction, gone from the list. Not marked, not
    -- greyed: absent, and indistinguishable from somebody who never opted in.
    and not private.blocked_between((select auth.uid()), p.id)
    and (
      in_part is null
      or in_part = any(p.plays)
      or exists (
        select 1 from public.song_layers l
        where l.recorded_by = p.id
          and l.shared_at is not null
          and l.part::text = in_part
      )
    )
    and (
      in_city is null
      or (p.location_visibility = 'public'
          and lower(trim(p.city)) = lower(trim(in_city)))
    )
  order by
    (exists (
      select 1 from public.song_layers l
      where l.recorded_by = p.id and l.shared_at is not null
        and (in_part is null or l.part::text = in_part)
    )) desc,
    p.display_name asc
  limit greatest(least(in_limit, 100), 1);
$$;

revoke all on function public.find_musicians(text, text, integer) from public, anon;
grant execute on function public.find_musicians(text, text, integer) to authenticated;

create or replace function public.musician_profile(target uuid)
returns table (
  id uuid,
  display_name text,
  avatar_path text,
  city text,
  plays text[],
  parts_recorded jsonb,
  songs_played_on bigint,
  people_worked_with bigint,
  discoverable boolean,
  location_visibility text
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
    case when p.id = (select auth.uid()) then p.location_visibility else null end
  from public.profiles p
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

-- The two that send somebody something. Both refuse, and both refuse with the
-- same sentence they would use for anything else that did not work — an error
-- that said "you are blocked" would hand back exactly the fact the block is
-- meant to keep quiet.
create or replace function public.ask_musician(
  target_project uuid,
  target_person uuid,
  in_part text default null,
  in_note text default ''
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  song record;
  asker_name text;
  cleaned_part text;
  new_ask uuid;
begin
  if target_person = auth.uid() then
    raise exception 'You cannot ask yourself.' using errcode = '22023';
  end if;

  if private.blocked_between(auth.uid(), target_person) then
    raise exception 'That musician is not available.' using errcode = '22023';
  end if;

  select p.id, p.title, p.room_id into song
  from public.projects p
  where p.id = target_project;

  if song.id is null then
    raise exception 'That song does not exist.' using errcode = '22023';
  end if;

  if not (private.is_room_member(song.room_id)
          or private.is_project_member(song.id)) then
    raise exception 'That is not your song to offer.' using errcode = '42501';
  end if;

  cleaned_part := nullif(trim(coalesce(in_part, '')), '');

  insert into public.project_asks
    (project_id, asked_by, asked_of, part, note, audience)
  values
    (target_project, auth.uid(), target_person, cleaned_part,
     left(trim(coalesce(in_note, '')), 280), 'collaborators')
  returning id into new_ask;

  select display_name into asker_name
  from public.profiles where id = auth.uid();

  perform private.notify_user(
    target_person,
    'song_ask',
    coalesce(asker_name, 'Somebody') || ' asked you to play ' ||
      coalesce(cleaned_part, 'on a song'),
    coalesce(song.title, 'A song') ||
      case
        when nullif(trim(coalesce(in_note, '')), '') is null then ''
        else ' — ' || left(trim(in_note), 200)
      end,
    song.room_id,
    target_project,
    null,
    auth.uid()
  );

  return new_ask;
end;
$$;

revoke all on function public.ask_musician(uuid, uuid, text, text)
  from public, anon;
grant execute on function public.ask_musician(uuid, uuid, text, text)
  to authenticated;

create or replace function public.invite_musician_to_room(
  target_room uuid,
  target_person uuid,
  in_note text default ''
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  room_name text;
  inviter_name text;
  new_invite uuid;
begin
  if target_person = auth.uid() then
    raise exception 'You are already in it.' using errcode = '22023';
  end if;

  if private.blocked_between(auth.uid(), target_person) then
    raise exception 'That musician is not available.' using errcode = '22023';
  end if;

  if private.room_role_for(target_room) <> 'owner' then
    raise exception 'Only the catalog owner can invite somebody to it.'
      using errcode = '42501';
  end if;

  if exists (
    select 1 from public.room_members
    where room_id = target_room and user_id = target_person
  ) then
    raise exception 'They are already in this catalog.' using errcode = '22023';
  end if;

  select name into room_name from public.rooms where id = target_room;
  select display_name into inviter_name
  from public.profiles where id = auth.uid();

  insert into public.room_invites (room_id, invited_profile, note)
  values (target_room, target_person, left(trim(coalesce(in_note, '')), 280))
  returning id into new_invite;

  perform private.notify_user(
    target_person,
    'invite_received',
    coalesce(inviter_name, 'Somebody') || ' invited you to ' ||
      coalesce(room_name, 'a catalog'),
    case
      when nullif(trim(coalesce(in_note, '')), '') is null
        then 'You would see the songs in it.'
      else left(trim(in_note), 200)
    end,
    target_room,
    null,
    null,
    auth.uid()
  );

  return new_invite;
end;
$$;

revoke all on function public.invite_musician_to_room(uuid, uuid, text)
  from public, anon;
grant execute on function public.invite_musician_to_room(uuid, uuid, text)
  to authenticated;

-- And the showcase, which is the one place a stranger's words and links are
-- drawn under somebody's name on a page other people read.
create or replace function public.showcase_for(target_profile uuid)
returns table (
  id uuid,
  url text,
  title text,
  platform text,
  position integer
)
language sql
stable
security definer
set search_path = public
as $$
  select l.id, l.url, l.title, l.platform, l.position
  from public.profile_links l
  where l.profile_id = target_profile
    and not private.blocked_between((select auth.uid()), target_profile)
  order by l.position, l.created_at;
$$;

revoke all on function public.showcase_for(uuid) from public, anon;
grant execute on function public.showcase_for(uuid) to authenticated;
