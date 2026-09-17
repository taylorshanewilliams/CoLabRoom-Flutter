-- An age answer stays.
--
-- The audit of 17 September 2026 (CO1): answering the birth month question
-- with a year that made somebody under 13 said "CoLabRoom is for people 13
-- and over." and left the year picker open, so the next try could simply pick
-- an older year. 0134 kept nothing about that answer, which meant there was
-- nothing to stop the second one.
--
-- The FTC's COPPA FAQ (Complying with COPPA: Frequently Asked Questions,
-- D.7 and H.3, read 17 September 2026) says an age screen should not
-- encourage children to falsify their age, for example by telling them
-- under 13s cannot take part, and recommends technical means, "using a
-- cookie to prevent children from back-buttoning to enter a different age".
-- A cookie lives on one device and clears with the browser; this is kept
-- against the account instead, so another phone or a reinstall is the same
-- answer.
--
-- So an under-13 answer is now remembered, as the fact that it was given and
-- when. The month itself is still never stored: a child's birth month is
-- exactly the data 0134 would not keep, and nothing here needs it. After it:
--
--   * every later answer is refused, an adult one included;
--   * the app's standing reads 'refused', and it never offers the picker again;
--   * calls stay closed, and a call in one of their rooms does not tell them.
--
-- Nothing else about the account changes: no deletion, no lock, no sign-out.
-- What happens to the account is a legal decision for Taylor, not something
-- a migration decides. A mistaken answer is corrected the way 0134 corrects a
-- birth month: through a person, who deletes the row.
--
-- The words said to the person are one sentence with no age in it, so they
-- say nothing a second try could be aimed at.

create table if not exists private.age_refusals (
  person_id uuid primary key references public.profiles(id) on delete cascade,
  -- When, and nothing else: no month, no year, no age.
  refused_at timestamptz not null default now()
);

revoke all on table private.age_refusals from public, anon, authenticated;
alter table private.age_refusals enable row level security;

-- As 0134, with 'refused' first: somebody who answered under 13 has no birth
-- month, and must not read as never asked.
create or replace function public.my_call_standing()
returns text
language sql
stable
security definer set search_path = ''
as $fn$
  select case
    when exists (select 1 from private.age_refusals r where r.person_id = auth.uid()) then 'refused'
    when not exists (select 1 from private.birth_months b where b.person_id = auth.uid()) then 'unknown'
    when private.is_adult(auth.uid()) then 'adult'
    else 'minor'
  end;
$fn$;

revoke all on function public.my_call_standing() from public, anon;
grant execute on function public.my_call_standing() to authenticated;

-- As 0134, except an under-13 answer is remembered and answered with
-- 'refused' rather than an error. It cannot be an error: raising rolls back
-- the row that remembers it. An app from before this sees 'refused' as never
-- asked and closes the sheet; if it asks again, the answer is refused here.
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
  -- Before anything about the answer itself: after an under-13 answer there
  -- is no second one, whatever it says.
  if exists (select 1 from private.age_refusals r where r.person_id = me) then
    raise exception 'Calls are not available on this account.' using errcode = '22023';
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
  -- Under 13 is below the sign-up floor (age_confirmed_13). The answer is
  -- remembered; the month is not.
  if (born + interval '1 month' - interval '1 day') > (current_date - interval '13 years') then
    insert into private.age_refusals (person_id) values (me)
    on conflict (person_id) do nothing;
    return 'refused';
  end if;

  insert into private.birth_months (person_id, born) values (me, born);
  return public.my_call_standing();
end;
$fn$;

revoke all on function public.set_my_birth_month(integer, integer) from public, anon;
grant execute on function public.set_my_birth_month(integer, integer) to authenticated;

-- As 0134, with the refusal said before a birth month is asked for. Without
-- it, call-token would answer 'birth_month_needed' and the app would open the
-- picker again. The sentence goes to the person as it is, through call-token.
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
  if exists (select 1 from private.age_refusals r where r.person_id = me) then
    return 'Calls are not available on this account.';
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

-- As 0134, and nobody calls are closed to is told a call started: they would
-- tap it and be turned away, the same reason a 15-year-old is not told.
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
        -- Nor somebody calls are closed to (0138).
        and not exists (
          select 1 from private.age_refusals r where r.person_id = m.user_id
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
