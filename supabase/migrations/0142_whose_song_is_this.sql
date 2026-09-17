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
      -- Marking a song as somebody else's takes it off the Open Mic in the
      -- same statement. It has to be the same statement: the guard trigger
      -- below refuses a row that is both, so clearing it afterwards would be
      -- refusing the answer instead of acting on it.
      open_mic_at = case when in_origin = 'cover' then null else open_mic_at end
  where id = target_project and deleted_at is null;
end;
$fn$;

revoke all on function public.set_song_origin(uuid, text) from public, anon;
grant execute on function public.set_song_origin(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- A cover is never on the Open Mic
-- ---------------------------------------------------------------------

-- The rule at the table, not only in the function that is supposed to be the
-- way in.
--
-- `put_on_open_mic` is the app's path and it is restated below with its own
-- refusal, so somebody gets a sentence rather than a constraint. But
-- `projects_update_editors` (0005) lets an owner or editor update this table
-- directly through PostgREST, columns and all, so the function is not the
-- only way `open_mic_at` can be set and a check that lives only in the
-- function is a check somebody can walk around with one request.
create or replace function private.no_cover_on_the_open_mic()
returns trigger
language plpgsql
security definer set search_path = ''
as $fn$
begin
  -- `is not distinct from`, so an unanswered song — null, which is most of
  -- them — is left alone rather than read as a cover.
  if new.song_origin is not distinct from 'cover'
     and new.open_mic_at is not null then
    raise exception 'Songs by somebody else stay with the people you choose.'
      using errcode = '42501';
  end if;
  return new;
end;
$fn$;

revoke all on function private.no_cover_on_the_open_mic()
  from public, anon, authenticated;

drop trigger if exists projects_no_cover_on_the_open_mic on public.projects;
create trigger projects_no_cover_on_the_open_mic
before insert or update on public.projects
for each row execute function private.no_cover_on_the_open_mic();

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
