-- The layer between a stranger and a bandmate.
--
-- This app has had two kinds of person in it and nothing in between. Somebody
-- is in a room with you -- a working relationship with shared files and shared
-- edits -- or they are a name on the Open Mic you have never met. The person
-- you jammed with once, the friend who plays bass, the drummer you met here
-- and would work with again: all of them were strangers every time you opened
-- the app, and the only way to keep hold of one was to put them in a room,
-- which grants them everything.
--
-- So: a connection. Mutual, because "bandmates and friends" is a mutual idea
-- and a one-way follow is a different product. It grants nothing on its own --
-- no room, no files, no edits. What it does is let two people find each other
-- again, see whether the other is around, and send something directly.

do $$
begin
  if not exists (select 1 from pg_type where typname = 'connection_state') then
    create type public.connection_state as enum ('pending', 'accepted');
  end if;
end
$$;

create table if not exists public.connections (
  requester_id uuid not null references public.profiles (id) on delete cascade,
  addressee_id uuid not null references public.profiles (id) on delete cascade,
  state public.connection_state not null default 'pending',
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  primary key (requester_id, addressee_id),
  constraint connections_not_self check (requester_id <> addressee_id)
);

-- Both directions get an index. Every question this table is asked is "who is
-- connected to me", and the answer lives in whichever column the other person
-- happens to occupy.
create index if not exists connections_addressee_idx
  on public.connections (addressee_id, state);
create index if not exists connections_requester_idx
  on public.connections (requester_id, state);

alter table public.connections enable row level security;

-- Read your own edges, in either direction. Nothing else.
drop policy if exists connections_read_own on public.connections;
create policy connections_read_own on public.connections
  for select using (
    auth.uid() = requester_id or auth.uid() = addressee_id
  );

-- Writes go through the functions below rather than straight at the table,
-- because every one of them has a rule attached: not yourself, not somebody
-- who blocked you, and a request that crosses an existing one in the opposite
-- direction is two people agreeing rather than two rows.
revoke insert, update, delete on public.connections from authenticated, anon;

-- How reachable somebody is, for longer than a green dot lasts.
--
-- A live presence signal is honest for the few minutes a day somebody has the
-- app open. This is the other half: something a person sets on purpose that
-- stays true for days, which is the timescale a band actually works on. Both
-- are wanted -- the dot says message now, this says whether it is worth asking
-- at all -- and this is the half that still says something when nobody is
-- online, which is most of the time until there are a great many more people
-- here.
alter table public.profiles
  add column if not exists availability text not null default 'unset',
  add column if not exists availability_note text,
  add column if not exists availability_until timestamptz;

alter table public.profiles
  drop constraint if exists profiles_availability_check;
alter table public.profiles
  add constraint profiles_availability_check
  check (availability in ('unset', 'open', 'busy', 'away'));

-- Ask somebody to connect.
--
-- Returns the state the pair ended in, so the caller can tell "asked" from
-- "you had already been asked, and now you are connected" without a second
-- query.
create or replace function public.request_connection(other_id uuid)
returns text
language plpgsql
security definer set search_path = ''
as $fn$
declare
  me uuid := auth.uid();
  existing public.connections%rowtype;
begin
  if me is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;
  if other_id = me then
    raise exception 'You are already yourself.' using errcode = '22023';
  end if;
  if not exists (select 1 from public.profiles where id = other_id) then
    raise exception 'That person is no longer here.' using errcode = '22023';
  end if;

  -- Blocking outranks everything, in both directions, and says the same thing
  -- either way. Telling somebody "they blocked you" hands them exactly the
  -- information the block exists to withhold.
  if exists (
    select 1 from public.user_blocks
    where (blocker_id = me and blocked_id = other_id)
       or (blocker_id = other_id and blocked_id = me)
  ) then
    raise exception 'That person cannot be added.' using errcode = '42501';
  end if;

  -- They asked you first. Two people who have each pressed the button are
  -- connected; making the second wait for the first to notice is a pointless
  -- day of delay.
  select * into existing from public.connections
  where requester_id = other_id and addressee_id = me;
  if found then
    if existing.state = 'accepted' then
      return 'accepted';
    end if;
    update public.connections
      set state = 'accepted', responded_at = now()
    where requester_id = other_id and addressee_id = me;
    return 'accepted';
  end if;

  insert into public.connections (requester_id, addressee_id)
  values (me, other_id)
  on conflict (requester_id, addressee_id) do nothing;

  select * into existing from public.connections
  where requester_id = me and addressee_id = other_id;
  return existing.state::text;
end;
$fn$;

revoke all on function public.request_connection(uuid) from public, anon;
grant execute on function public.request_connection(uuid) to authenticated;

-- Say yes or no to somebody who asked.
create or replace function public.respond_to_connection(other_id uuid, accept boolean)
returns text
language plpgsql
security definer set search_path = ''
as $fn$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;

  if not accept then
    -- Deleted rather than marked declined. A declined row is a record of a
    -- refusal sitting in a table, and it would stop them ever asking again
    -- after a change of mind.
    delete from public.connections
    where requester_id = other_id and addressee_id = me and state = 'pending';
    return 'none';
  end if;

  update public.connections
    set state = 'accepted', responded_at = now()
  where requester_id = other_id and addressee_id = me and state = 'pending';

  if not found then
    return 'none';
  end if;
  return 'accepted';
end;
$fn$;

revoke all on function public.respond_to_connection(uuid, boolean) from public, anon;
grant execute on function public.respond_to_connection(uuid, boolean) to authenticated;

-- Undo, from either side, whatever the state.
create or replace function public.remove_connection(other_id uuid)
returns void
language plpgsql
security definer set search_path = ''
as $fn$
declare
  me uuid := auth.uid();
begin
  if me is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;
  delete from public.connections
  where (requester_id = me and addressee_id = other_id)
     or (requester_id = other_id and addressee_id = me);
end;
$fn$;

revoke all on function public.remove_connection(uuid) from public, anon;
grant execute on function public.remove_connection(uuid) to authenticated;

-- Everybody you are connected to or have been asked by, with enough about
-- them to draw a row.
--
-- `direction` matters to the screen and not to the graph: an accepted pair is
-- symmetric, but a pending one is either something you are waiting on or
-- something waiting on you, and those are different rows with different
-- buttons.
create or replace function public.my_connections()
returns table (
  person_id uuid,
  display_name text,
  avatar_path text,
  plays text[],
  state text,
  direction text,
  availability text,
  availability_note text,
  availability_until timestamptz,
  since timestamptz
)
language sql
security definer set search_path = ''
stable
as $fn$
  select
    p.id,
    p.display_name,
    p.avatar_path,
    p.plays,
    c.state::text,
    case when c.requester_id = auth.uid() then 'outgoing' else 'incoming' end,
    -- An expired status is not a status. Somebody who said they were busy
    -- until Friday is not busy on Saturday, and showing it a week later is
    -- how a feature like this starts lying.
    case
      when p.availability_until is not null and p.availability_until < now()
        then 'unset'
      else p.availability
    end,
    case
      when p.availability_until is not null and p.availability_until < now()
        then null
      else p.availability_note
    end,
    p.availability_until,
    coalesce(c.responded_at, c.created_at)
  from public.connections c
  join public.profiles p
    on p.id = case when c.requester_id = auth.uid()
                   then c.addressee_id else c.requester_id end
  where auth.uid() in (c.requester_id, c.addressee_id)
    and not exists (
      select 1 from public.user_blocks b
      where (b.blocker_id = auth.uid() and b.blocked_id = p.id)
         or (b.blocker_id = p.id and b.blocked_id = auth.uid())
    )
  order by
    case c.state when 'pending' then 0 else 1 end,
    coalesce(c.responded_at, c.created_at) desc;
$fn$;

revoke all on function public.my_connections() from public, anon;
grant execute on function public.my_connections() to authenticated;

-- Set how reachable you are.
--
-- `until` is the part that keeps it honest. A status with no end date is one
-- somebody sets in a good week and forgets, and six weeks later the app is
-- still telling their band they are up for playing.
create or replace function public.set_availability(
  new_state text,
  note text default null,
  until timestamptz default null
)
returns void
language plpgsql
security definer set search_path = ''
as $fn$
begin
  if auth.uid() is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;
  if new_state not in ('unset', 'open', 'busy', 'away') then
    raise exception 'Unknown availability.' using errcode = '22023';
  end if;
  update public.profiles
  set availability = new_state,
      availability_note = nullif(left(coalesce(trim(note), ''), 80), ''),
      availability_until = until,
      updated_at = now()
  where id = auth.uid();
end;
$fn$;

revoke all on function public.set_availability(text, text, timestamptz) from public, anon;
grant execute on function public.set_availability(text, text, timestamptz) to authenticated;

-- Who is worth adding, that you have not already added.
--
-- Not a recommendation engine, and deliberately not one. The source is a fact
-- rather than a guess: people you already share a room with. That is what
-- somebody means by "my bandmates", and the app already knows it.
create or replace function public.people_you_might_add()
returns table (
  person_id uuid,
  display_name text,
  avatar_path text,
  because text
)
language sql
security definer set search_path = ''
stable
as $fn$
  with mine as (
    select case when requester_id = auth.uid() then addressee_id else requester_id end as id
    from public.connections
    where auth.uid() in (requester_id, addressee_id)
  ),
  roommates as (
    select distinct m2.user_id as id
    from public.room_members m1
    join public.room_members m2 on m2.room_id = m1.room_id
    where m1.user_id = auth.uid() and m2.user_id <> auth.uid()
  )
  select r.id, p.display_name, p.avatar_path, 'In a room with you'::text
  from roommates r
  join public.profiles p on p.id = r.id
  where r.id not in (select id from mine)
    and not exists (
      select 1 from public.user_blocks b
      where (b.blocker_id = auth.uid() and b.blocked_id = r.id)
         or (b.blocker_id = r.id and b.blocked_id = auth.uid())
    )
  order by p.display_name;
$fn$;

revoke all on function public.people_you_might_add() from public, anon;
grant execute on function public.people_you_might_add() to authenticated;
