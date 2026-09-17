-- Whose song is this?
--
-- One column, three answers: ours, public domain, or somebody else's. Every
-- Musician, Same Song, 17 September 2026 calls it one of the two gates,
-- because almost everything the plan wants for schools, worship teams and
-- cover bands is safe on a song the room wrote and is not safe on a song
-- somebody else wrote. Without this column the app cannot tell the two
-- apart, so it has to treat every song as if it were the risky kind — which
-- is why "covered songs stay sheet-only" is the standing rule and why it
-- blocks the work behind it.
--
-- **Null is the honest fourth state.** It means nobody has been asked yet,
-- which is true of every song in the database right now and will stay true
-- of every song that never leaves its room. The app asks once, the first
-- time a song's audience moves beyond "Only you", and never again. A default
-- of 'ours' would have been a claim the app made on somebody's behalf.
--
-- **No legal claim is being made or recorded.** These are three plain
-- answers to a plain question, used to decide what this app does with a
-- song's words and where it will let the song go. They are not a licence,
-- and nothing here checks one.

alter table public.projects
  add column if not exists song_origin text
  check (song_origin in ('ours', 'public_domain', 'cover'));

comment on column public.projects.song_origin is
  'Whose song this is: ours, public_domain, or cover (somebody else wrote '
  'it). Null means nobody has been asked yet, which is every song until its '
  'audience moves beyond "Only you".';

-- ---------------------------------------------------------------------
-- Answering the question
-- ---------------------------------------------------------------------

-- Owner or editor, because this is a fact about the song rather than a
-- decision about who may hear it. Anybody trusted to write on a song is
-- trusted to say where it came from — and the person who started a cover in
-- somebody else's catalog is usually the editor, not the owner.
create or replace function public.set_song_origin(
  target_project uuid,
  in_origin text
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  song record;
  role_here public.room_role;
begin
  if in_origin is null
     or in_origin not in ('ours', 'public_domain', 'cover') then
    raise exception 'That is not one of the three answers.'
      using errcode = '22023';
  end if;

  select p.id, p.room_id into song
  from public.projects p
  where p.id = target_project and p.deleted_at is null;

  if song.id is null then
    raise exception 'That song does not exist.' using errcode = '22023';
  end if;

  role_here := private.room_role_for(song.room_id);

  -- `is distinct from` twice, not `not in`. room_role_for is null for
  -- somebody who is not in the room, `null not in ('owner', 'editor')` is
  -- null, and `if null then` does not fire — so the plain form waves through
  -- the exact person the check exists to stop. See 0068.
  if role_here is distinct from 'owner' and role_here is distinct from 'editor'
  then
    raise exception 'Only somebody who can edit this song can say whose it is.'
      using errcode = '42501';
  end if;

  update public.projects
  set song_origin = in_origin,
      -- Marking a song as somebody else's takes it off both public surfaces
      -- in the same statement. It has to be the same statement: the guard
      -- trigger below refuses a row that is both, so clearing them
      -- afterwards would be refusing the answer instead of acting on it.
      open_mic_at =
        case when in_origin = 'cover' then null else open_mic_at end,
      -- The showcase as well as the Open Mic. A song already on
      -- colabroom.com is the case that most needs the answer to act: the
      -- Open Mic reaches signed-in accounts, `public_songs` (0096) is
      -- granted to anon, so the showcase is the open internet. Answering
      -- "somebody else" a week later has to take it down, not leave it up
      -- with nothing in the app saying so.
      showcased_at =
        case when in_origin = 'cover' then null else showcased_at end
  where id = target_project and deleted_at is null;

  -- `finished_at` is left alone on purpose. It is private (0088) and it is a
  -- statement about the work, not about who may hear it — a cover a band
  -- finished is still finished.
end;
$fn$;

revoke all on function public.set_song_origin(uuid, text) from public, anon;
grant execute on function public.set_song_origin(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- A cover never goes in front of strangers
-- ---------------------------------------------------------------------

-- **Both public surfaces, not only the Open Mic.** There are two ways a song
-- becomes audible to people the room never chose, and the second one is the
-- wider of the two: `open_mic_at` (0067) reaches signed-in accounts, while
-- `showcased_at` (0088) is served by `public_songs` (0096), which is granted
-- to anon — so a showcased song is a page on colabroom.com with the band's
-- own audio on it. It is also the looser of the two: `show_song` admits
-- anybody in the room, where `put_on_open_mic` is the catalog owner only.
--
-- Gating both is what the plan asks for. "Covered songs stay sheet-only
-- until whose-song exists and a lawyer has looked" (Every Musician, Same
-- Song, 17 September 2026), and its what-not-to-build table already rules
-- out team recordings of licensed songs shared as *rehearsal* audio —
-- sharing them with the open internet cannot be the milder case. The dial
-- says "Songs by somebody else stay with the people you choose", and a
-- promise made in the app has to be true of every surface or it is not a
-- promise. Opening the showcase back up later is one migration; publishing
-- somebody else's song cannot be taken back the same way.
--
-- The rule at the table, not only in the functions that are supposed to be
-- the way in. Both are restated below with their own refusals, so somebody
-- gets a sentence rather than a constraint. But `projects_update_editors`
-- (0005) lets an owner or editor update this table directly through
-- PostgREST, columns and all, so the functions are not the only way these
-- two columns can be set and a check that lives only in a function is a
-- check somebody can walk around with one request.
create or replace function private.no_cover_in_public()
returns trigger
language plpgsql
security definer set search_path = ''
as $fn$
begin
  -- `is not distinct from`, so an unanswered song — null, which is most of
  -- them — is left alone rather than read as a cover.
  if new.song_origin is not distinct from 'cover'
     and (new.open_mic_at is not null or new.showcased_at is not null) then
    raise exception 'Songs by somebody else stay with the people you choose.'
      using errcode = '42501';
  end if;
  return new;
end;
$fn$;

revoke all on function private.no_cover_in_public()
  from public, anon, authenticated;

drop trigger if exists projects_no_cover_in_public on public.projects;
create trigger projects_no_cover_in_public
before insert or update on public.projects
for each row execute function private.no_cover_in_public();

-- Restated from 0067, which is still its latest definition, with the one
-- refusal added. Everything else — the owner-only check, the `coalesce` that
-- makes a second press a no-op, the returned timestamp — is 0067's.
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

  update public.projects
  set open_mic_at = coalesce(open_mic_at, now())
  where id = target_project
  returning open_mic_at into when_shared;

  return when_shared;
end;
$$;

revoke all on function public.put_on_open_mic(uuid) from public, anon;
grant execute on function public.put_on_open_mic(uuid) to authenticated;

-- Restated from 0088, which is still its latest definition, with the one
-- refusal added. Everything else — the room-member check inside the update,
-- the `coalesce` that finishes a song somebody skipped finishing, the
-- 'No such song.' for a row that is not theirs — is 0088's.
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
  -- outside the room what is in it — a stranger still gets 'No such song.'
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

-- `unshow_song` (0088) is deliberately untouched. Taking a song down is the
-- move nobody should ever be stopped from making, whoever wrote the song.
