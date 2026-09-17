-- A code for meeting in person.
--
-- Taylor, 16 September 2026: "the same qr code system, could each user have
-- one in their profile? say you meet someone at a concert, or open mic
-- night, or anywhere, you could just scan each other's codes and become
-- friends in the app."
--
-- A connection (0101) already has the right shape: mutual, granting
-- nothing, and two people who have each asked are connected without either
-- waiting on the other. What was missing is finding the person standing
-- next to you. A name shouted over a band is a guess, and searching for it
-- shows you strangers. So everybody gets a code -- a QR code on their phone
-- -- that opens their card.
--
-- The consent rule holds. Opening a code shows whose it is and does nothing
-- else. Adding is a separate tap, and it is a request the other person
-- answers -- unless they have already scanned yours, in which case both of
-- you have said yes and request_connection connects you on the spot. That
-- is "scan each other's codes", with no new rule to make it happen.
--
-- The code can be changed, and it is not the person's id. A code in a photo
-- that ends up somewhere it should not be is one button from dead; an id is
-- forever.

create table public.meeting_codes (
  person_id uuid primary key references public.profiles(id) on delete cascade,

  -- Eight characters from an alphabet with no i, l, o or u, shown as
  -- k7m2-9xqp: short enough to read out over a band, and nothing in it can
  -- be mistaken for anything else in it.
  code text not null unique check (code ~ '^[0-9a-hjkmnp-tv-z]{8}$'),

  created_at timestamptz not null default now()
);

alter table public.meeting_codes enable row level security;

create policy meeting_codes_read_own on public.meeting_codes
for select to authenticated using (person_id = (select auth.uid()));

grant select on public.meeting_codes to authenticated;
revoke insert, update, delete on public.meeting_codes from authenticated, anon;

-- Eight random characters. A v4 UUID's bytes 6 and 8 carry its version and
-- variant; the eight used here carry nothing but randomness, and a byte
-- taken modulo 32 is as even as the byte.
create or replace function private.draw_meeting_code()
returns text
language plpgsql
volatile
set search_path = ''
as $fn$
declare
  alphabet constant text := '0123456789abcdefghjkmnpqrstvwxyz';
  bytes constant bytea := uuid_send(gen_random_uuid());
  picked integer;
  drawn text := '';
begin
  foreach picked in array array[0, 1, 2, 3, 4, 5, 9, 10] loop
    drawn := drawn || substr(alphabet, get_byte(bytes, picked) % 32 + 1, 1);
  end loop;
  return drawn;
end;
$fn$;

revoke all on function private.draw_meeting_code() from public, anon, authenticated;

-- What somebody typed, the way it is stored: dashes and spaces gone, lower
-- case, and the letters a person reads as digits read as those digits.
create or replace function private.clean_meeting_code(in_code text)
returns text
language sql
immutable
set search_path = ''
as $fn$
  select translate(lower(regexp_replace(coalesce(in_code, ''), '[^0-9A-Za-z]', '', 'g')), 'oil', '011');
$fn$;

revoke all on function private.clean_meeting_code(text) from public, anon, authenticated;

-- Your code, made the first time you ask for it.
create or replace function public.my_meeting_code()
returns text
language plpgsql
security definer set search_path = ''
as $fn$
declare
  me uuid := auth.uid();
  kept text;
begin
  if me is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;

  select m.code into kept from public.meeting_codes m where m.person_id = me;
  if kept is not null then
    return kept;
  end if;

  loop
    begin
      insert into public.meeting_codes (person_id, code)
      values (me, private.draw_meeting_code())
      on conflict (person_id) do nothing
      returning code into kept;
      if kept is null then
        -- Asked twice at once, from two devices: the other call made it.
        select m.code into kept from public.meeting_codes m where m.person_id = me;
      end if;
      return kept;
    exception when unique_violation then
      -- Somebody else already has that code. Draw again.
      null;
    end;
  end loop;
end;
$fn$;

revoke all on function public.my_meeting_code() from public, anon;
grant execute on function public.my_meeting_code() to authenticated;

-- A new code. The old one opens nobody from now on; people already added
-- stay added.
create or replace function public.change_my_meeting_code()
returns text
language plpgsql
security definer set search_path = ''
as $fn$
declare
  me uuid := auth.uid();
  kept text;
begin
  if me is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;

  loop
    begin
      insert into public.meeting_codes (person_id, code)
      values (me, private.draw_meeting_code())
      on conflict (person_id) do update
        set code = excluded.code, created_at = now()
      returning code into kept;
      return kept;
    exception when unique_violation then
      null;
    end;
  end loop;
end;
$fn$;

revoke all on function public.change_my_meeting_code() from public, anon;
grant execute on function public.change_my_meeting_code() to authenticated;

-- Whose code this is: enough to recognise the person in front of you, and
-- where the two of you already stand. It adds nobody.
--
-- `state` is 'none', 'pending' or 'accepted'; `direction` is 'outgoing'
-- when you asked, 'incoming' when they did, null when nobody has.
create or replace function public.person_with_meeting_code(in_code text)
returns table (
  person_id uuid,
  display_name text,
  avatar_path text,
  plays text[],
  state text,
  direction text
)
language plpgsql
stable
security definer set search_path = ''
as $fn$
declare
  me uuid := auth.uid();
  them uuid;
begin
  if me is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;

  select m.person_id into them
  from public.meeting_codes m
  where m.code = private.clean_meeting_code(in_code);
  if them is null then
    raise exception 'That code does not open anybody. They may have changed it.' using errcode = '22023';
  end if;
  if them = me then
    raise exception 'That is your own code. Show it to somebody.' using errcode = '22023';
  end if;
  -- The words request_connection uses, so a block reads the same from
  -- either side and from either door.
  if private.blocked_between(me, them) then
    raise exception 'That person cannot be added.' using errcode = '42501';
  end if;

  return query
  select
    p.id,
    p.display_name,
    p.avatar_path,
    p.plays,
    coalesce(c.state::text, 'none'),
    case
      when c.requester_id is null then null
      when c.requester_id = me then 'outgoing'
      else 'incoming'
    end
  from public.profiles p
  left join public.connections c
    on (c.requester_id = me and c.addressee_id = p.id)
    or (c.requester_id = p.id and c.addressee_id = me)
  where p.id = them;
end;
$fn$;

revoke all on function public.person_with_meeting_code(text) from public, anon;
grant execute on function public.person_with_meeting_code(text) to authenticated;
