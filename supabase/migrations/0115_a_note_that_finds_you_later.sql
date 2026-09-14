-- A note that finds you later.
--
-- The shallowest ask there is: "I'd like to meet singers." Nothing attached,
-- no song, no part on a bar. Until now it had nowhere to live. Somebody who
-- narrowed the Open Mic to singers and found none was left exactly where
-- they were, and when a singer turned up a week later nobody was told --
-- the search had been a question with no memory.
--
-- So: a standing want. One row per person per part, kept for a month and
-- then gone (a want with no end date is one somebody set in a good week and
-- forgot, and the room fills with ghosts). When somebody who plays that
-- part becomes findable, the person who left the note is told, once per
-- person, and only when the two of them could plausibly be in a room
-- together: if both say where they are, the cities must agree.
--
-- The same record read the other way is what a newcomer sees: "two people
-- around here are looking for a bass player." Counts, never names -- the
-- names are on the Open Mic for whoever chooses to be there, and a want is
-- not a listing.

create table public.standing_wants (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null default auth.uid()
    references public.profiles(id) on delete cascade,

  -- The stored word, matching profiles.plays and song_layers.part.
  part text not null check (char_length(trim(part)) between 1 and 40),

  -- What to call it to a person ("a singer"), decided by the app that knows
  -- the vocabulary, so the notification does not have to say "vocal".
  label text not null check (char_length(trim(label)) between 1 and 40),

  note text check (note is null or char_length(note) <= 140),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '30 days',
  unique (profile_id, part)
);

create index standing_wants_part_idx on public.standing_wants (part, expires_at);

alter table public.standing_wants enable row level security;

-- Your own, readable. Written only through the functions below, which set
-- the expiry and the vocabulary; the table is not a free-text inbox.
create policy standing_wants_read_own on public.standing_wants
for select to authenticated using (profile_id = (select auth.uid()));

revoke insert, update, delete on public.standing_wants from authenticated, anon;

-- Who a want has already met, so somebody switching their listing off and
-- on is one match, not one a day.
create table public.standing_want_matches (
  want_id uuid not null references public.standing_wants(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  matched_at timestamptz not null default now(),
  primary key (want_id, profile_id)
);

alter table public.standing_want_matches enable row level security;

create policy standing_want_matches_read_own on public.standing_want_matches
for select to authenticated using (
  exists (
    select 1 from public.standing_wants w
    where w.id = want_id and w.profile_id = (select auth.uid())
  )
);

revoke insert, update, delete on public.standing_want_matches from authenticated, anon;

-- ---------------------------------------------------------------------
-- Leaving one, dropping one, reading your own.
-- ---------------------------------------------------------------------

create or replace function public.leave_want(
  in_part text,
  in_label text,
  in_note text default null
)
returns uuid
language plpgsql
security definer set search_path = ''
as $fn$
declare
  me uuid := auth.uid();
  cleaned_part text := lower(trim(coalesce(in_part, '')));
  new_id uuid;
begin
  if me is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;
  if cleaned_part = '' then
    raise exception 'Say what you are looking for.' using errcode = '22023';
  end if;

  -- Leaving the same note again renews it: a month from today, with
  -- whatever was said this time. Who it has already met is kept, so a
  -- renewal does not re-introduce everybody.
  insert into public.standing_wants (profile_id, part, label, note, expires_at)
  values (
    me,
    cleaned_part,
    left(trim(coalesce(nullif(in_label, ''), cleaned_part)), 40),
    nullif(left(trim(coalesce(in_note, '')), 140), ''),
    now() + interval '30 days'
  )
  on conflict (profile_id, part) do update
    set label = excluded.label,
        note = excluded.note,
        expires_at = excluded.expires_at,
        created_at = now()
  returning id into new_id;

  return new_id;
end;
$fn$;

revoke all on function public.leave_want(text, text, text) from public, anon;
grant execute on function public.leave_want(text, text, text) to authenticated;

create or replace function public.drop_want(target uuid)
returns void
language sql
security definer set search_path = ''
as $fn$
  delete from public.standing_wants
  where id = target and profile_id = auth.uid();
$fn$;

revoke all on function public.drop_want(uuid) from public, anon;
grant execute on function public.drop_want(uuid) to authenticated;

create or replace function public.my_wants()
returns table (
  id uuid,
  part text,
  label text,
  note text,
  expires_at timestamptz,
  matched bigint
)
language sql
stable
security definer set search_path = ''
as $fn$
  select
    w.id, w.part, w.label, w.note, w.expires_at,
    (select count(*) from public.standing_want_matches m where m.want_id = w.id)
  from public.standing_wants w
  where w.profile_id = auth.uid()
    and w.expires_at > now()
  order by w.created_at desc;
$fn$;

revoke all on function public.my_wants() from public, anon;
grant execute on function public.my_wants() to authenticated;

-- ---------------------------------------------------------------------
-- The other direction: who is looking for what you play.
-- ---------------------------------------------------------------------

-- Counts per part, for the parts you play, from people you are not blocked
-- from and could be in a room with. Never names. Reads the same rows the
-- matcher writes to, which is the whole idea: one record, two directions.
create or replace function public.wants_around()
returns table (part text, label text, people bigint)
language sql
stable
security definer set search_path = ''
as $fn$
  with me as (
    select p.id, p.plays, p.city, p.location_visibility
    from public.profiles p
    where p.id = auth.uid()
  )
  select w.part, min(w.label), count(distinct w.profile_id)
  from public.standing_wants w
  join public.profiles wp on wp.id = w.profile_id
  cross join me
  where w.expires_at > now()
    and w.profile_id <> me.id
    and w.part = any(
      select lower(trim(t)) from unnest(coalesce(me.plays, '{}'::text[])) t
    )
    and not private.blocked_between(me.id, w.profile_id)
    and (
      me.location_visibility <> 'public'
      or wp.location_visibility <> 'public'
      or me.city is null
      or wp.city is null
      or lower(trim(me.city)) = lower(trim(wp.city))
    )
  group by w.part
  order by count(distinct w.profile_id) desc, w.part;
$fn$;

revoke all on function public.wants_around() from public, anon;
grant execute on function public.wants_around() to authenticated;

-- ---------------------------------------------------------------------
-- The note finding you.
-- ---------------------------------------------------------------------

-- Fires when a profile changes in a way that changes who it is to a search:
-- becoming findable, or playing something new. Each unexpired want for a
-- part they play is told once, under the newcomer's name, and the pair is
-- remembered so it is never told twice.
create or replace function private.match_standing_wants()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
declare
  want record;
begin
  if not coalesce(new.discoverable, false) then
    return new;
  end if;

  for want in
    select w.id, w.profile_id, w.label,
           wp.city as wanter_city, wp.location_visibility as wanter_visibility
    from public.standing_wants w
    join public.profiles wp on wp.id = w.profile_id
    where w.expires_at > now()
      and w.profile_id <> new.id
      and w.part = any(
        select lower(trim(t)) from unnest(coalesce(new.plays, '{}'::text[])) t
      )
      and not exists (
        select 1 from public.standing_want_matches m
        where m.want_id = w.id and m.profile_id = new.id
      )
      and not private.blocked_between(w.profile_id, new.id)
  loop
    -- Local first. When both say where they are the cities must agree; a
    -- city either of them keeps to themselves is not a different city.
    if new.location_visibility = 'public'
       and want.wanter_visibility = 'public'
       and new.city is not null
       and want.wanter_city is not null
       and lower(trim(new.city)) <> lower(trim(want.wanter_city)) then
      continue;
    end if;

    insert into public.standing_want_matches (want_id, profile_id)
    values (want.id, new.id);

    perform private.notify_user(
      want.profile_id,
      'want_matched',
      coalesce(new.display_name, 'Somebody') || ' just turned up',
      'You left a note that you would like to meet ' ||
        lower(want.label) || '. They are on the Open Mic now.',
      null,
      null,
      null,
      new.id
    );
  end loop;

  return new;
end;
$$;

drop trigger if exists profiles_match_wants on public.profiles;
create trigger profiles_match_wants
after insert or update of discoverable, plays on public.profiles
for each row execute function private.match_standing_wants();
