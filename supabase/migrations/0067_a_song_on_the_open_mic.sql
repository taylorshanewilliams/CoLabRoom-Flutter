-- Putting a song on the Open Mic.
--
-- Open Mic has been a list of *people* since it shipped. This is the other
-- half and the one three separate things have been waiting behind: a song
-- somebody outside the room can open and actually hear. Without it, Open Mic
-- can find you a bass player who cannot listen to the song you want bass on,
-- a profile cannot show the work somebody has made, and `project_asks`
-- carries an `audience` of 'public' that nothing can reach.
--
-- **What a stranger can hear, and what they cannot.**
--
-- Only takes that have been *shared*. 0057 made a take private to its
-- recorder until they say otherwise, and that line holds here: putting a song
-- on the Open Mic does not publish somebody's unheard draft, including when
-- that somebody is not the person who put it there. The owner of a song can
-- offer the song; they cannot offer a bandmate's private take.
--
-- **Everybody who listens has an account.**
--
-- This is deliberately not a public web link. Taylor's worry about somebody
-- taking an idea is the right worry, and the mitigation that actually works
-- is not obscurity — it is that every listen happens under a name, on top of
-- `song_provenance()`, which already records who did what and when and
-- exports as a PDF. An anonymous URL would remove the one thing that makes a
-- theft answerable.
--
-- **It is one column and it is reversible.** A song is on the Open Mic or it
-- is not, the owner decides, and taking it off is the same gesture backwards.

alter table public.projects
  add column if not exists open_mic_at timestamptz;

comment on column public.projects.open_mic_at is
  'When this song was put on the Open Mic. Null means it is private to its '
  'catalog, which is every song by default and most songs forever.';

create index if not exists projects_open_mic_idx
  on public.projects (open_mic_at desc) where open_mic_at is not null;

-- ---------------------------------------------------------------------
-- Saying so, and taking it back
-- ---------------------------------------------------------------------

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
  select p.id, p.room_id, p.title into song
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

  update public.projects
  set open_mic_at = coalesce(open_mic_at, now())
  where id = target_project
  returning open_mic_at into when_shared;

  return when_shared;
end;
$$;

revoke all on function public.put_on_open_mic(uuid) from public, anon;
grant execute on function public.put_on_open_mic(uuid) to authenticated;

create or replace function public.take_off_open_mic(target_project uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- `is distinct from`, not `<>`. room_role_for is null for somebody who is
  -- not in the room, and `null <> 'owner'` is null, and `if null then` does
  -- not fire — so the plain comparison waves through the exact person the
  -- check exists to stop. See 0068.
  if private.room_role_for(
       (select room_id from public.projects where id = target_project)
     ) is distinct from 'owner' then
    raise exception 'Only the catalog owner can take a song off the Open Mic.'
      using errcode = '42501';
  end if;

  -- Deliberately allowed, and deliberately quiet. Somebody who put a song up
  -- and thought better of it in the morning should be able to take it down
  -- without a conversation, and an app where that is hard is one where people
  -- put fewer songs up.
  update public.projects set open_mic_at = null where id = target_project;
end;
$$;

revoke all on function public.take_off_open_mic(uuid) from public, anon;
grant execute on function public.take_off_open_mic(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Letting somebody outside the room read it
-- ---------------------------------------------------------------------

-- Three policies have to agree, or a song is visible and silent: the project
-- row, the takes on it, and the audio those takes point at. Missing the third
-- is the classic version of this bug — a page that lists four parts and plays
-- none of them.

-- Each of these is the live policy with one clause added, not a fresh one
-- written from the migration history. Reading the deployed definitions first
-- caught three things that would have been regressions: `projects` also
-- admits somebody holding a pending invitation, `storage.objects` also admits
-- a path that matches a `files` row, and the path segments are cast with
-- `private.as_uuid` rather than `::uuid` — a safe cast, because a bucket
-- holds objects whose first folder is not always a uuid and a raw cast throws
-- rather than returning false.

drop policy if exists projects_read_members on public.projects;
create policy projects_read_members on public.projects
for select to authenticated using (
  private.is_room_member(room_id)
  or private.is_project_member(id)
  or exists (
    select 1 from public.invitations invitation
    where invitation.project_id = projects.id
      and invitation.status = 'pending'
      and lower(invitation.email)
          = lower(coalesce((select auth.jwt()) ->> 'email', ''))
  )
  or open_mic_at is not null
);

-- This one also fixes a bug rather than only widening.
--
-- The live policy gated layers on `is_room_member` alone, so somebody who
-- accepted an ask — project membership, not room membership — could open the
-- song and hear none of it. The ask flow shipped this morning was broken end
-- to end for exactly that reason: accept, arrive, silence.
drop policy if exists song_layers_read_members on public.song_layers;
create policy song_layers_read_members on public.song_layers
for select to authenticated using (
  (
    shared_at is not null
    or recorded_by = (select auth.uid())
  )
  and exists (
    select 1 from public.projects p
    where p.id = project_id
      and (
        private.is_room_member(p.room_id)
        or private.is_project_member(p.id)
        -- On the Open Mic, and only what the room has already heard. A
        -- private take stays private even on a song its owner published:
        -- the owner offers the song, never somebody else's unheard draft.
        or (p.open_mic_at is not null and shared_at is not null)
      )
  )
);

-- And the audio, or the page lists four parts and plays none of them.
drop policy if exists room_files_read_members on storage.objects;
create policy room_files_read_members on storage.objects
for select to authenticated using (
  bucket_id = 'room-files'
  and (
    private.is_room_member(private.as_uuid((storage.foldername(name))[1]))
    or (
      array_length(storage.foldername(name), 1) >= 2
      and private.is_project_member(private.as_uuid((storage.foldername(name))[2]))
    )
    or exists (
      select 1 from public.files f
      join public.projects p on p.id = f.project_id
      where f.storage_path = objects.name
        and (private.is_room_member(p.room_id) or private.is_project_member(p.id))
    )
    -- Paths are {room}/{project}/..., so the project is the second segment.
    or (
      array_length(storage.foldername(name), 1) >= 2
      and exists (
        select 1 from public.projects p
        where p.id = private.as_uuid((storage.foldername(name))[2])
          and p.open_mic_at is not null
      )
    )
  )
);

-- ---------------------------------------------------------------------
-- Browsing what is up there
-- ---------------------------------------------------------------------

-- Songs on the Open Mic, newest first, with the one thing that decides
-- whether somebody taps: what it is asking for.
--
-- Blocked in either direction and it is not here, the same as a person.
create or replace function public.open_mic_songs(
  in_part text default null,
  in_limit integer default 30
)
returns table (
  id uuid,
  title text,
  owner_id uuid,
  owner_name text,
  open_mic_at timestamptz,
  take_count bigint,
  asking_for text[]
)
language sql
stable
security definer
set search_path = public
as $$
  select
    p.id,
    p.title,
    p.created_by,
    pr.display_name,
    p.open_mic_at,
    (select count(*) from public.song_layers l
      where l.project_id = p.id and l.shared_at is not null),
    coalesce(
      (select array_agg(distinct a.part)
         from public.project_asks a
        where a.project_id = p.id
          and a.status = 'open'
          and a.part is not null),
      '{}'::text[]
    )
  from public.projects p
  left join public.profiles pr on pr.id = p.created_by
  where p.open_mic_at is not null
    and p.deleted_at is null
    and not private.blocked_between((select auth.uid()), p.created_by)
    and (
      in_part is null
      or exists (
        select 1 from public.project_asks a
        where a.project_id = p.id and a.status = 'open' and a.part = in_part
      )
    )
  order by p.open_mic_at desc
  limit greatest(least(in_limit, 100), 1);
$$;

revoke all on function public.open_mic_songs(text, integer) from public, anon;
grant execute on function public.open_mic_songs(text, integer) to authenticated;

-- What a stranger sees when they open one.
--
-- Enough to decide whether they want to play on it, and nothing about the
-- catalog it lives in — which songs sit beside it is the band's business.
create or replace function public.open_mic_song(target_project uuid)
returns table (
  id uuid,
  title text,
  owner_id uuid,
  owner_name text,
  open_mic_at timestamptz,
  musical_key text,
  bpm double precision,
  asking_for text[],
  ask_note text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    p.id,
    p.title,
    p.created_by,
    pr.display_name,
    p.open_mic_at,
    r.musical_key,
    r.bpm,
    coalesce(
      (select array_agg(distinct a.part)
         from public.project_asks a
        where a.project_id = p.id and a.status = 'open' and a.part is not null),
      '{}'::text[]
    ),
    (select a.note from public.project_asks a
      where a.project_id = p.id and a.status = 'open'
        and char_length(trim(a.note)) > 0
      order by a.created_at desc limit 1)
  from public.projects p
  left join public.profiles pr on pr.id = p.created_by
  left join public.project_audio_references r
    on r.project_id = p.id
  where p.id = target_project
    and p.open_mic_at is not null
    and p.deleted_at is null
    and not private.blocked_between((select auth.uid()), p.created_by)
  limit 1;
$$;

revoke all on function public.open_mic_song(uuid) from public, anon;
grant execute on function public.open_mic_song(uuid) to authenticated;
