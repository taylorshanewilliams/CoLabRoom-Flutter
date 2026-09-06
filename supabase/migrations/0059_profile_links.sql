-- Work somebody made somewhere else.
--
-- A profile should feel like a room a musician is proud of, and on the day
-- they arrive there is nothing in it. Everything CoLabRoom knows about
-- somebody is earned inside CoLabRoom, which is correct for reputation and
-- useless for a first impression: a player with twenty years of records
-- behind them looks identical to somebody who signed up this morning.
--
-- Linking out fixes that, and it fixes something else that matters more at
-- scale. Storage is the one line on this bill paid again every month on
-- everything ever uploaded — a showcase full of hosted audio would be a cost
-- that grew on its own forever. A showcase full of links costs nothing to
-- keep, plays the mastered version rather than a phone take, and stays under
-- the control of the person who made it.
--
-- **What this is not.** It is not part of the record. Anybody can paste a
-- link to anything, so these are shown and never counted: they say what
-- somebody sounds like, not what they have done here. The distinction is the
-- same one the profile already draws between what a person declares and what
-- they have actually recorded, and it is kept for the same reason.

create table public.profile_links (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null default auth.uid()
    references public.profiles(id) on delete cascade,

  url text not null check (char_length(url) between 8 and 2048),

  -- What to call it. Theirs to write: a track title, a band name, "the album
  -- we did in 2019".
  title text not null default '' check (char_length(title) <= 120),

  -- Derived from the host on write, never sent by the client. A row that let
  -- the client name its own platform would let somebody paste a link to
  -- anywhere and label it Spotify.
  platform text not null,

  position integer not null default 0,
  created_at timestamptz not null default now()
);

create index profile_links_profile_idx
  on public.profile_links (profile_id, position, created_at);

alter table public.profile_links enable row level security;

-- Readable by any signed-in person: a showcase nobody can see is not a
-- showcase. Writable only by its owner.
create policy profile_links_read on public.profile_links
for select to authenticated using (true);

create policy profile_links_write_own on public.profile_links
for insert to authenticated with check (profile_id = (select auth.uid()));

create policy profile_links_update_own on public.profile_links
for update to authenticated using (profile_id = (select auth.uid()))
with check (profile_id = (select auth.uid()));

create policy profile_links_delete_own on public.profile_links
for delete to authenticated using (profile_id = (select auth.uid()));

-- ---------------------------------------------------------------------
-- Which hosts are allowed
-- ---------------------------------------------------------------------

-- An allowlist, not a validator.
--
-- A profile that renders arbitrary user-supplied URLs is a phishing surface
-- with a musician's name on it: somebody links what looks like their album
-- and it opens a page asking for a password. Checking that a URL "looks safe"
-- cannot work, because the attacker chooses the URL. Naming the handful of
-- places music actually lives can.
--
-- Adding to this list is a migration on purpose. It should be a decision
-- somebody makes, not a field somebody fills in.
create or replace function private.link_platform(in_url text)
returns text
language plpgsql
immutable
as $$
declare
  host text;
begin
  -- Scheme first: anything that is not https is refused outright, which
  -- disposes of javascript:, data: and http in one line.
  if in_url !~* '^https://' then
    return null;
  end if;

  host := lower(split_part(split_part(substring(in_url from 9), '/', 1), ':', 1));
  -- Strip credentials, which are the classic way to make a hostile URL read
  -- as a friendly one: https://open.spotify.com@evil.example/track
  if position('@' in host) > 0 then
    return null;
  end if;

  return case
    when host in ('soundcloud.com', 'www.soundcloud.com', 'on.soundcloud.com')
      then 'SoundCloud'
    when host in ('open.spotify.com', 'spotify.link') then 'Spotify'
    when host in ('youtube.com', 'www.youtube.com', 'm.youtube.com', 'youtu.be')
      then 'YouTube'
    when host = 'bandcamp.com' or host like '%.bandcamp.com' then 'Bandcamp'
    when host in ('music.apple.com', 'embed.music.apple.com') then 'Apple Music'
    when host in ('vimeo.com', 'player.vimeo.com') then 'Vimeo'
    when host in ('audiomack.com', 'www.audiomack.com') then 'Audiomack'
    when host = 'bsky.app' then null
    else null
  end;
end;
$$;

revoke all on function private.link_platform(text) from public, anon, authenticated;

create or replace function private.set_link_platform()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
declare
  named text;
begin
  named := private.link_platform(new.url);
  if named is null then
    raise exception 'Links can point to SoundCloud, Spotify, YouTube, Bandcamp, Apple Music, Vimeo or Audiomack.'
      using errcode = '22023';
  end if;
  new.platform := named;
  return new;
end;
$$;

drop trigger if exists profile_links_platform on public.profile_links;
create trigger profile_links_platform
before insert or update of url on public.profile_links
for each row execute function private.set_link_platform();

-- Somewhere to stop.
--
-- A showcase is a handful of things somebody is proud of. Twenty links is a
-- list nobody scrolls, and an unbounded one is a place to put spam.
create or replace function private.limit_profile_links()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
begin
  if (select count(*) from public.profile_links
      where profile_id = new.profile_id) > 8 then
    raise exception 'A profile can show up to eight links.'
      using errcode = '54000';
  end if;
  return null;
end;
$$;

drop trigger if exists profile_links_capped on public.profile_links;
create constraint trigger profile_links_capped
after insert on public.profile_links
for each row execute function private.limit_profile_links();
