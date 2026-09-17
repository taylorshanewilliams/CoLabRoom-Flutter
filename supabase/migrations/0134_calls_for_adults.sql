-- Calls for adults.
--
-- Taylor, 16 September 2026: lesson rooms with "a video feed if wanted", and
-- the same for bandmates. Slice 4, stage A: live voice and video inside a room,
-- between adults. The video itself runs on LiveKit Cloud; the call-token Edge
-- Function hands out a ticket only to somebody this database says may be there.
--
-- Who may be in a call is the part that has to be right, and it was decided
-- with Taylor rather than guessed ("I dont want to exclude a young prodigy but
-- i dont want to burn the company"):
--
--   * Stage A (this): people who share a room, and who are 18 or older.
--   * Stage B (next): 13-17 join through a parent or guardian who approves
--     each adult, is told about every call and can sit in.
--   * Nothing is ever recorded. Florida, where the company is, needs every
--     party's consent to record a call.
--
-- So age is a birth month and year, asked once before somebody's first call,
-- rather than an "I am 18" box: stage B needs to know when a 16-year-old turns
-- 18 without asking them again, and a box cannot say.
--
-- ---------------------------------------------------------------------
-- A birth month
-- ---------------------------------------------------------------------
--
-- In `private`, not on profiles: every signed-in account can read profiles,
-- and nobody needs anybody else's birthday. The app only ever learns its own
-- standing -- adult, minor, or not yet asked.

create table if not exists private.birth_months (
  person_id uuid primary key references public.profiles(id) on delete cascade,
  -- The first of the month. The day is not asked for, because nothing here
  -- needs it.
  born date not null check (extract(day from born) = 1),
  set_at timestamptz not null default now()
);

revoke all on table private.birth_months from public, anon, authenticated;
alter table private.birth_months enable row level security;

-- Eighteen for the whole of their birth month, not from its first day: the
-- careful side of a month nobody can narrow down.
create or replace function private.is_adult(person uuid)
returns boolean
language sql
stable
security definer set search_path = ''
as $fn$
  select exists (
    select 1 from private.birth_months b
    where b.person_id = person
      and (b.born + interval '1 month' - interval '1 day') <= (current_date - interval '18 years')
  );
$fn$;

revoke all on function private.is_adult(uuid) from public, anon, authenticated;

-- Where you stand for calls: 'adult', 'minor', or 'unknown' before you have
-- been asked.
create or replace function public.my_call_standing()
returns text
language sql
stable
security definer set search_path = ''
as $fn$
  select case
    when not exists (select 1 from private.birth_months b where b.person_id = auth.uid()) then 'unknown'
    when private.is_adult(auth.uid()) then 'adult'
    else 'minor'
  end;
$fn$;

revoke all on function public.my_call_standing() from public, anon;
grant execute on function public.my_call_standing() to authenticated;

-- Said once. A birth month that could be changed from the app is a
-- 16-year-old's second try, so correcting a mistake goes through a person.
create or replace function public.set_my_birth_month(in_year integer, in_month integer)
returns text
language plpgsql
security definer set search_path = ''
as $fn$
declare
  me uuid := auth.uid();
  born date;
begin
  if me is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;
  if exists (select 1 from private.birth_months b where b.person_id = me) then
    raise exception 'Your birth month is already saved. To correct it, send feedback from Account.'
      using errcode = '22023';
  end if;
  if in_month is null or in_month < 1 or in_month > 12
     or in_year is null or in_year < 1900 or in_year > extract(year from current_date) then
    raise exception 'That is not a month and year.' using errcode = '22023';
  end if;

  born := make_date(in_year, in_month, 1);
  if born > current_date then
    raise exception 'That is not a month and year.' using errcode = '22023';
  end if;
  -- Under 13 is below the sign-up floor (age_confirmed_13). Not stored: a
  -- child's birth month is exactly the data this app must not keep.
  if (born + interval '1 month' - interval '1 day') > (current_date - interval '13 years') then
    raise exception 'CoLabRoom is for people 13 and over.' using errcode = '22023';
  end if;

  insert into private.birth_months (person_id, born) values (me, born);
  return public.my_call_standing();
end;
$fn$;

revoke all on function public.set_my_birth_month(integer, integer) from public, anon;
grant execute on function public.set_my_birth_month(integer, integer) to authenticated;

-- ---------------------------------------------------------------------
-- Who is in a call
-- ---------------------------------------------------------------------
--
-- The phone says so every twenty seconds while it is in a call. It is how the
-- room shows "Jess is in a call · Join" and how a call knows it has started.
-- It is not the security check: that is LiveKit's own list of who is actually
-- connected, read by call-token before it lets anybody in.

create table if not exists public.call_presence (
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  -- One person on two devices is two rows, and leaving on one is not leaving.
  device text not null check (char_length(device) between 1 and 64),
  heard_at timestamptz not null default now(),
  primary key (room_id, user_id, device)
);

create index if not exists call_presence_room_idx on public.call_presence (room_id, heard_at desc);

alter table public.call_presence enable row level security;
-- Read through room_call, written through hear_me_in_call: nothing directly.
revoke all on table public.call_presence from authenticated, anon;

-- When a room was last told a call had started, so a dropped connection and a
-- rejoin is not a second push to everybody.
create table if not exists private.call_announcements (
  room_id uuid primary key references public.rooms(id) on delete cascade,
  announced_at timestamptz not null default now()
);

revoke all on table private.call_announcements from public, anon, authenticated;
alter table private.call_announcements enable row level security;

-- Whether somebody may be in a call in this room: a member, and an adult.
-- The reason is said to the person, so it is written for them.
create or replace function public.may_join_call(in_room uuid)
returns text
language plpgsql
stable
security definer set search_path = ''
as $fn$
declare
  me uuid := auth.uid();
begin
  if me is null then
    return 'Sign in first.';
  end if;
  if not exists (
    select 1 from public.room_members m where m.room_id = in_room and m.user_id = me
  ) then
    return 'Calls are for people in this room.';
  end if;
  if not exists (select 1 from private.birth_months b where b.person_id = me) then
    return 'birth_month_needed';
  end if;
  if not private.is_adult(me) then
    return 'Calls are for people 18 and over for now. Calls with a parent or guardian are coming.';
  end if;
  return 'ok';
end;
$fn$;

revoke all on function public.may_join_call(uuid) from public, anon;
grant execute on function public.may_join_call(uuid) to authenticated;

-- Whether you and any of these people have blocked each other. For call-token,
-- which knows who is connected; true means you are not let in.
create or replace function public.blocked_with_any(in_people uuid[])
returns boolean
language sql
stable
security definer set search_path = ''
as $fn$
  select exists (
    select 1 from unnest(coalesce(in_people, '{}'::uuid[])) as other(id)
    where other.id <> auth.uid() and private.blocked_between(auth.uid(), other.id)
  );
$fn$;

revoke all on function public.blocked_with_any(uuid[]) from public, anon;
grant execute on function public.blocked_with_any(uuid[]) to authenticated;

-- I am in the call. Every twenty seconds. The first voice in a quiet room
-- tells the rest of the room, once in ten minutes.
create or replace function public.hear_me_in_call(in_room uuid, in_device text)
returns void
language plpgsql
security definer set search_path = ''
as $fn$
declare
  me uuid := auth.uid();
  quiet boolean;
  my_name text;
  room_name text;
  member record;
begin
  if public.may_join_call(in_room) <> 'ok' then
    raise exception 'You cannot be in a call in this room.' using errcode = '42501';
  end if;

  select not exists (
    select 1 from public.call_presence p
    where p.room_id = in_room
      and p.heard_at > now() - interval '2 minutes'
      and not (p.user_id = me and p.device = left(in_device, 64))
  ) into quiet;

  insert into public.call_presence (room_id, user_id, device)
  values (in_room, me, left(in_device, 64))
  on conflict (room_id, user_id, device) do update set heard_at = now();

  if quiet and not exists (
    select 1 from private.call_announcements a
    where a.room_id = in_room and a.announced_at > now() - interval '10 minutes'
  ) then
    insert into private.call_announcements (room_id) values (in_room)
    on conflict (room_id) do update set announced_at = now();

    select coalesce(nullif(trim(p.display_name), ''), 'Somebody') into my_name
    from public.profiles p where p.id = me;
    select r.name into room_name from public.rooms r where r.id = in_room;

    for member in
      select m.user_id from public.room_members m
      where m.room_id = in_room and m.user_id <> me
        and not private.blocked_between(me, m.user_id)
        -- Not somebody who cannot join yet: a 15-year-old in a band room
        -- told about a call they are not allowed into. Somebody not yet
        -- asked for a birth month is told, and asked when they tap Join.
        and not exists (
          select 1 from private.birth_months b
          where b.person_id = m.user_id and not private.is_adult(m.user_id)
        )
    loop
      perform private.notify_user(
        member.user_id,
        'call_started',
        my_name || ' started a call',
        coalesce(room_name, 'Your room') || '. Join from the room.',
        in_room, null, null,
        me
      );
    end loop;
  end if;
end;
$fn$;

revoke all on function public.hear_me_in_call(uuid, text) from public, anon;
grant execute on function public.hear_me_in_call(uuid, text) to authenticated;

create or replace function public.leave_call(in_room uuid, in_device text)
returns void
language sql
security definer set search_path = ''
as $fn$
  delete from public.call_presence p
  where p.room_id = in_room and p.user_id = auth.uid() and p.device = left(in_device, 64);
$fn$;

revoke all on function public.leave_call(uuid, text) from public, anon;
grant execute on function public.leave_call(uuid, text) to authenticated;

-- Who is in this room's call right now, for "Jess is in a call · Join". Heard
-- in the last 45 seconds, members only, nobody you have blocked or who has
-- blocked you.
create or replace function public.room_call(in_room uuid)
returns table (user_id uuid, display_name text)
language sql
stable
security definer set search_path = ''
as $fn$
  select distinct p.user_id, coalesce(nullif(trim(pr.display_name), ''), 'Somebody')
  from public.call_presence p
  join public.profiles pr on pr.id = p.user_id
  where p.room_id = in_room
    and p.heard_at > now() - interval '45 seconds'
    and exists (
      select 1 from public.room_members m where m.room_id = in_room and m.user_id = auth.uid()
    )
    and not private.blocked_between(auth.uid(), p.user_id);
$fn$;

revoke all on function public.room_call(uuid) from public, anon;
grant execute on function public.room_call(uuid) to authenticated;
