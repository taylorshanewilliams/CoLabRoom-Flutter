-- Seal a take for later.
--
-- Every Musician, Same Song, 17 September 2026, from the big swings worth
-- keeping, kept small: "A year ago tonight you sealed this. Play it now?"
-- Somebody records an idea and seals it. The app puts it away and offers it
-- back on a day they choose, a year on unless they say otherwise. Until then
-- it is not among the song's takes, the retention sweep leaves it alone, and
-- nobody else can see it. On the day there is one quiet card, and either
-- answer ends it: played or "Not now", the take is back among their takes
-- and the card does not come again. Nothing is counted, and nothing records
-- which answer was given.
--
-- **Only a take nobody has heard.** A take is private until its player
-- shares it (0057), and a sealed take is a private take that has also been
-- put away. Sealing one the room has already heard would mean taking it out
-- of other people's mixes and saved versions (0038) and out from under the
-- notes pinned to it (0141), so that is refused, and sharing a sealed take
-- is refused the same way. Everything written since 0057 about who may hear
-- a draft therefore holds for a sealed take without being restated.
--
-- **Proved rather than implied.** `song_layers_read_members` has been
-- restated five times (0057, 0067, 0088, 0094, 0155) and will be again. A
-- promise that lives inside it lasts until the next restatement forgets it.
-- So the promise here is a *restrictive* policy of its own: it is ANDed with
-- whatever the permissive ones admit, now and after any later migration, and
-- says one thing -- a sealed take is read by whoever recorded it.
--
-- **The audio, not only the row** (0155's lesson). `room_files_read_members`
-- admits a room member to every object under the room's folder, so a
-- bandmate who listed the layers folder could fetch a draft's bytes. For a
-- sealed take that is closed the same way, with a restrictive policy on
-- storage.objects answered by a security-definer function.
--
-- **Expiry.** tools/expire_layers.py is what deletes takes, and it now holds
-- a sealed take out of both passes until ninety days after its day: a take
-- put away for a year has by definition gone unopened for a year, and the
-- ordinary rule would warn it and delete it in the fortnight after it came
-- back. Ending the seal starts the clock again from that moment.

alter table public.song_layers
  add column if not exists sealed_at timestamptz,
  add column if not exists sealed_until timestamptz;

comment on column public.song_layers.sealed_at is
  'When the person who recorded this sealed it. Null means it is not sealed. '
  'Every Musician, Same Song, 17 September 2026.';
comment on column public.song_layers.sealed_until is
  'The day a sealed take is offered back to the person who recorded it. '
  'Until then it is out of the take list, kept by the retention sweep, and '
  'read by nobody else. Cleared, with sealed_at, when the seal ends.';

-- The backstops. The trigger below says these things as sentences first; the
-- constraints are what is left if it is ever switched off.
alter table public.song_layers
  drop constraint if exists song_layers_a_seal_is_whole;
alter table public.song_layers
  add constraint song_layers_a_seal_is_whole
  check ((sealed_at is null) = (sealed_until is null));

alter table public.song_layers
  drop constraint if exists song_layers_sealed_is_unheard;
alter table public.song_layers
  add constraint song_layers_sealed_is_unheard
  check (sealed_until is null or shared_at is null);

-- The card's read: my sealed takes whose day has come. Partial, because
-- almost no take is ever sealed.
create index if not exists song_layers_sealed_idx
  on public.song_layers (recorded_by, sealed_until)
  where sealed_until is not null;

-- ---------------------------------------------------------------------
-- The rule at the table
-- ---------------------------------------------------------------------

-- `song_layers_update_own` (0038) lets the person who recorded a take write
-- any column of it through PostgREST, so seal_take below is not the only way
-- these two columns get written, and 0142 already learned that a rule living
-- only in the functions is one request away from nothing. What matters at
-- the table is small: a seal opens on a day that has not come, no further
-- off than ten years (it is an exemption from expiry, and an exemption with
-- no end is free storage for ever), the day it was sealed is the day it was
-- sealed, and a sealed take is never a shared one.
--
-- The retention sweep's side of it is here too, so that it holds however
-- the seal was written. A warning given before a take was put away is not a
-- warning about the day it comes back, so sealing clears it and the take is
-- owed a fresh one. And a seal ending starts the clock again: a take that
-- comes back after a year has not been "unopened for a year" in any sense
-- tools/expire_layers.py means, and without this the first Sunday after
-- "Not now" would warn it and the second would delete it.
create or replace function private.a_seal_has_a_day()
returns trigger
language plpgsql
set search_path = ''
as $fn$
begin
  if new.sealed_until is null then
    -- Not sealed, or a seal ending. Nothing is kept about one that ended.
    new.sealed_at := null;
    if tg_op = 'UPDATE' and old.sealed_until is not null then
      new.last_opened_at := now();
      new.expiry_warned_at := null;
    end if;
    return new;
  end if;

  if new.shared_at is not null then
    raise exception 'A sealed take stays put away until its day.'
      using errcode = '22023';
  end if;

  -- The same seal, on a row being updated for some other reason: a label,
  -- a level, last_opened_at. When it was sealed is not rewritten.
  if tg_op = 'UPDATE'
     and old.sealed_until is not distinct from new.sealed_until then
    new.sealed_at := old.sealed_at;
    return new;
  end if;

  if new.sealed_until <= now() then
    raise exception 'Pick a day that has not come yet.'
      using errcode = '22023';
  end if;
  if new.sealed_until > now() + interval '10 years' then
    raise exception 'Ten years is as far as a seal goes.'
      using errcode = '22023';
  end if;

  new.sealed_at := now();
  new.expiry_warned_at := null;
  return new;
end;
$fn$;

revoke all on function private.a_seal_has_a_day()
  from public, anon, authenticated;

drop trigger if exists song_layers_a_seal_has_a_day on public.song_layers;
create trigger song_layers_a_seal_has_a_day
before insert or update on public.song_layers
for each row execute function private.a_seal_has_a_day();

-- ---------------------------------------------------------------------
-- Nobody else reads it
-- ---------------------------------------------------------------------

-- Restrictive, so it narrows whatever the permissive policies admit rather
-- than being one more of them. No role named: whoever is asking, a sealed
-- take is read by the person who recorded it and by nobody else. For
-- somebody signed out auth.uid() is null, the comparison is null, and the
-- row is refused.
--
-- It reaches further than reading, which is wanted: Postgres applies select
-- policies to the rows an update or a delete has to find, so a room owner
-- (`song_layers_delete_own_or_owner`, 0038) cannot delete a sealed take they
-- cannot see, any more than they could a draft.
drop policy if exists song_layers_sealed_is_yours on public.song_layers;
create policy song_layers_sealed_is_yours on public.song_layers
as restrictive
for select
using (
  sealed_until is null
  or recorded_by = (select auth.uid())
);

-- And the bytes. Answered by a security-definer function for the reason
-- 0155 gives: a policy expression runs as the viewer, so a subquery on
-- song_layers written into the policy would see only what the policy above
-- admits -- which hides from a bandmate precisely the sealed row that ought
-- to refuse them the object. Looked up by path, which 0155 indexed.
create or replace function private.sealed_from_me(object_name text)
returns boolean
language sql
stable
security definer set search_path = ''
as $fn$
  select exists (
    select 1
    from public.song_layers l
    where l.storage_path = object_name
      and l.sealed_until is not null
      and l.recorded_by is distinct from (select auth.uid())
  );
$fn$;

revoke all on function private.sealed_from_me(text) from public, anon;
grant execute on function private.sealed_from_me(text) to authenticated;

-- To authenticated, like every other policy on this table: nobody signed out
-- has a permissive policy on room-files to narrow. Everything that is not a
-- take passes on its path alone, so an avatar or a lyric sheet never costs
-- the lookup.
drop policy if exists sealed_takes_are_put_away on storage.objects;
create policy sealed_takes_are_put_away on storage.objects
as restrictive
for select
to authenticated
using (
  bucket_id is distinct from 'room-files'
  or name not like '%/layers/%'
  or not private.sealed_from_me(name)
);

-- ---------------------------------------------------------------------
-- Sealing
-- ---------------------------------------------------------------------

-- A function rather than a plain update, for the reason share_layer (0057)
-- is one: sealing always means the same thing and always happens once. A
-- second call on a take that is already sealed changes nothing and returns
-- the day it already opens.
--
-- Security invoker. The person sealing is the person who recorded the take,
-- and every row this touches is one their own policies already give them.
-- One answer for a take that is not there and a take that is not yours, so
-- asking says nothing about somebody else's draft.
create or replace function public.seal_take(
  target_layer uuid,
  open_on timestamptz default null
)
returns timestamptz
language plpgsql
security invoker
set search_path = ''
as $fn$
declare
  me uuid := auth.uid();
  take record;
  -- A year, unless they chose a day.
  opens timestamptz := coalesce(open_on, now() + interval '1 year');
begin
  if me is null then
    raise exception 'You must be signed in.' using errcode = '42501';
  end if;

  select l.id, l.recorded_by, l.shared_at, l.sealed_until into take
  from public.song_layers l
  where l.id = target_layer;

  if take.id is null or take.recorded_by is distinct from me then
    raise exception 'No such take.' using errcode = '22023';
  end if;

  if take.sealed_until is not null then
    return take.sealed_until;
  end if;

  if take.shared_at is not null then
    raise exception 'Only a take nobody else has heard can be sealed.'
      using errcode = '22023';
  end if;

  -- The day itself is checked by the trigger above, which is the one place
  -- that rule lives.
  update public.song_layers
  set sealed_until = opens
  where id = target_layer
    and recorded_by = me
    and shared_at is null
    and sealed_until is null;

  return opens;
end;
$fn$;

revoke all on function public.seal_take(uuid, timestamptz) from public, anon;
grant execute on function public.seal_take(uuid, timestamptz) to authenticated;

-- The seal ending: "Play it now", "Not now", or Undo a moment after sealing.
-- All three are the same act, and nothing records which it was -- the plan's
-- rule is no counts, and a column saying somebody declined to listen to
-- their own idea would be one.
--
-- The take goes back among their takes exactly as it was, still private. The
-- retention clock starting again is the trigger's doing, above, so that it
-- holds for a seal ended by a plain update as well.
--
-- Quiet when there is nothing to end, like unshare_layer (0057): already
-- ended, or not yours, and neither is worth an error in front of somebody.
create or replace function public.unseal_take(target_layer uuid)
returns void
language sql
security invoker
set search_path = ''
as $fn$
  update public.song_layers
  set sealed_until = null
  where id = target_layer
    and recorded_by = auth.uid()
    and sealed_until is not null;
$fn$;

revoke all on function public.unseal_take(uuid) from public, anon;
grant execute on function public.unseal_take(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- The day
-- ---------------------------------------------------------------------

-- My sealed takes whose day has come, earliest first, with what the card
-- needs to say which song it is and to play it. The server's clock decides
-- what "has come" means, so a phone with the wrong date neither opens a seal
-- early nor sits on one.
--
-- Security invoker: these are the caller's own rows on songs they can still
-- reach. A take on a song they have since left, or one that was deleted, is
-- not offered -- there is no take list for it to go back to.
create or replace function public.sealed_takes_due()
returns table (
  layer_id uuid,
  project_id uuid,
  song_title text,
  label text,
  part text,
  storage_path text,
  duration_ms integer,
  sealed_at timestamptz,
  sealed_until timestamptz
)
language sql
stable
security invoker
set search_path = ''
as $fn$
  select
    l.id,
    l.project_id,
    p.title,
    l.label,
    l.part,
    l.storage_path,
    l.duration_ms,
    l.sealed_at,
    l.sealed_until
  from public.song_layers l
  join public.projects p on p.id = l.project_id
  where l.recorded_by = (select auth.uid())
    and l.sealed_until is not null
    and l.sealed_until <= now()
    and p.deleted_at is null
  order by l.sealed_until, l.id;
$fn$;

revoke all on function public.sealed_takes_due() from public, anon;
grant execute on function public.sealed_takes_due() to authenticated;
