-- Finished things.
--
-- The Open Mic is one surface doing two jobs badly. A half-finished idea
-- asking for a bass player and a record somebody spent six months on sit in
-- the same list, in the same order, described the same way — so the person
-- browsing for somebody to work with cannot tell what they are hearing, and
-- the person who finished something has nowhere to put it that means
-- *finished*.
--
-- They are different rooms in every real building. One is where you try
-- things in front of people who might help; the other is where you play the
-- thing you are proud of. This app has had names for both since the day
-- somebody described it — a rehearsal room and a stage — and only ever built
-- the first.
--
-- **And hearing what somebody finished is the better introduction.** A raw
-- idea tells you what they are working on. A finished song tells you what
-- they are capable of, which is what anybody deciding whether to work with a
-- stranger actually wants to know.
--
-- ---------------------------------------------------------------------
-- Made here
-- ---------------------------------------------------------------------
--
-- The claim worth making, and the reason to make it carefully.
--
-- "Collabed here" is the app's whole argument — that people who would never
-- have met made something together — and it is worthless the moment it is
-- decoration. So it is computed, never set:
--
--   made_here  more than one person has a shared take on it. Two musicians
--              actually played on this, in this app.
--   met_here   somebody holds project-scoped membership on it. That row is
--              only ever written by an accepted ask or a per-song invitation
--              (0013, 0061), so it is the record of two strangers where one
--              asked and the other said yes.
--
-- `met_here` deliberately does not read `project_asks.status`. An accepted
-- ask is set to 'closed' by answer_ask — and so is one the owner withdrew,
-- so the status cannot tell the two apart. The membership it grants can.
--
-- The second is the strong one and it is rarer. Both are facts about rows
-- that exist; neither is a badge anybody can award themselves.

-- **Finishing is not publishing, and conflating them would be the worst
-- privacy bug this app has shipped.**
--
-- A band marking their song done is saying something to each other. If that
-- put it in front of every signed-in account, the first version of this
-- feature would have taken private work public on a button labelled "Done" —
-- which is precisely what the audience dial exists to stop.
--
-- So there are two marks and they mean different things. `finished_at` is
-- private and is the useful one for your own library: this is done, stop
-- offering to make a song sheet for it. `showcased_at` is consent, given
-- separately, exactly like `open_mic_at`.
alter table public.projects
  add column if not exists finished_at timestamptz;

alter table public.projects
  add column if not exists showcased_at timestamptz;

create index if not exists projects_showcased_idx
  on public.projects (showcased_at desc) where showcased_at is not null;

create index if not exists projects_finished_idx
  on public.projects (finished_at desc) where finished_at is not null;

comment on column public.projects.finished_at is
  'When somebody in the room said it was done. Private: this alone shows it '
  'to nobody. Finishing takes it off the Open Mic, because a finished song '
  'is not asking for anything.';

comment on column public.projects.showcased_at is
  'When somebody chose to show the finished song publicly. The same kind of '
  'consent as open_mic_at, and required for the showcase — finishing alone '
  'never publishes anything.';

-- Saying it is done.
--
-- Takes it off the Open Mic in the same statement. A song cannot both be
-- asking for a bass player and be finished, and leaving it in both places is
-- how the two lists stopped meaning anything in the first place.
create or replace function public.finish_song(target_project uuid)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  -- Anybody in the room, not only the owner. A band finishes a song
  -- together and whoever puts the last take on it should be able to say so.
  if not exists (
    select 1 from public.projects p
    where p.id = target_project
      and (private.is_room_member(p.room_id) or p.created_by = auth.uid())
  ) then
    raise exception 'Only somebody in the room can finish this song.'
      using errcode = '42501';
  end if;

  update public.projects
  set finished_at = now(),
      open_mic_at = null
  where id = target_project and deleted_at is null;

  if not found then
    raise exception 'No such song.' using errcode = '22023';
  end if;

  -- Nothing is asking for anything any more.
  update public.project_asks
  set status = 'closed'
  where project_id = target_project and status = 'open';
end;
$fn$;

revoke all on function public.finish_song(uuid) from public, anon;
grant execute on function public.finish_song(uuid) to authenticated;

-- Showing the finished thing, which is a separate decision.
create or replace function public.show_song(target_project uuid)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
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

create or replace function public.unshow_song(target_project uuid)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  update public.projects
  set showcased_at = null
  where id = target_project
    and deleted_at is null
    and (private.is_room_member(room_id) or created_by = auth.uid());

  if not found then
    raise exception 'No such song.' using errcode = '22023';
  end if;
end;
$fn$;

revoke all on function public.unshow_song(uuid) from public, anon;
grant execute on function public.unshow_song(uuid) to authenticated;

-- And taking it back, because "done" is a thing people change their mind
-- about and a one-way door is a door nobody walks through.
create or replace function public.unfinish_song(target_project uuid)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  update public.projects
  set finished_at = null
  where id = target_project
    and deleted_at is null
    and (private.is_room_member(room_id) or created_by = auth.uid());

  if not found then
    raise exception 'No such song.' using errcode = '22023';
  end if;
end;
$fn$;

revoke all on function public.unfinish_song(uuid) from public, anon;
grant execute on function public.unfinish_song(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- The showcase
-- ---------------------------------------------------------------------

-- Finished songs, newest first, with who made them.
--
-- Newest first and nothing else, deliberately. The moment this is ordered by
-- listens it is a chart, and 0072 and 0074 spent two migrations making sure
-- this app does not rank people. Somebody's first finished song appears above
-- a record with a thousand plays if they finished it this morning, which is
-- the correct behaviour for a room rather than a league.
create or replace function public.showcase(
  in_limit integer default 24,
  in_before timestamptz default null
)
returns table (
  id uuid,
  title text,
  owner_id uuid,
  owner_name text,
  owner_avatar text,
  finished_at timestamptz,
  showcased_at timestamptz,
  storage_path text,
  duration_ms integer,
  musical_key text,
  -- Who played on it, as names, so a card can say "with Mara and Dev"
  -- rather than a number.
  players jsonb,
  made_here boolean,
  met_here boolean
)
language sql
stable
security definer
set search_path = public
as $fn$
  select
    p.id,
    p.title,
    p.created_by,
    pr.display_name,
    pr.avatar_path,
    p.finished_at,
    p.showcased_at,
    audio.storage_path,
    audio.duration_ms,
    r.musical_key,
    coalesce(
      (select jsonb_agg(distinct jsonb_build_object(
                'id', who.id, 'name', coalesce(who.display_name, 'Somebody')))
         from public.song_layers l
         join public.profiles who on who.id = l.recorded_by
        where l.project_id = p.id
          and l.shared_at is not null
          and l.recorded_by is distinct from p.created_by),
      '[]'::jsonb
    ),
    (select count(distinct l.recorded_by) > 1
       from public.song_layers l
      where l.project_id = p.id and l.shared_at is not null),
    exists (
      select 1 from public.project_members m
      where m.project_id = p.id
        and m.user_id is distinct from p.created_by
    )
  from public.projects p
  left join public.profiles pr on pr.id = p.created_by
  left join public.project_audio_references r on r.project_id = p.id
  left join lateral private.song_audio(p.id) audio on true
  -- Shown, not merely finished. Finishing is private; this column is the
  -- consent, and reading finished_at here would publish every band's
  -- private work the moment somebody pressed Done.
  where p.showcased_at is not null
    and p.deleted_at is null
    -- Nothing silent. A showcase card with nothing to play is worse than a
    -- shorter showcase.
    and audio.storage_path is not null
    and not private.blocked_between((select auth.uid()), p.created_by)
    and (in_before is null or p.showcased_at < in_before)
  order by p.showcased_at desc
  limit greatest(least(in_limit, 48), 1);
$fn$;

revoke all on function public.showcase(integer, timestamptz)
  from public, anon;
grant execute on function public.showcase(integer, timestamptz)
  to authenticated;

-- ---------------------------------------------------------------------
-- And the three layers that make it audible
-- ---------------------------------------------------------------------

-- The same three 0067 had to widen for the Open Mic, for the same reason and
-- with the same failure if they are missed: the row, the takes on it, and the
-- audio those takes point at. Missing the third is the classic version — a
-- page that lists a finished song and plays none of it.
--
-- Necessary here because finishing *clears* `open_mic_at`, so a showcased
-- song is no longer covered by any of the branches 0067 added. Without this
-- the showcase would render and be silent for everybody but the room.
--
-- Each is the live policy with one clause added, read from the deployed
-- definition rather than rebuilt from history — which is how 0067 avoided
-- dropping a pending-invitation clause it did not know about.

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
  or showcased_at is not null
);

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
        -- Shared takes only, on either public surface. A private take stays
        -- private on a song its room has published: the room offers the
        -- song, never somebody's unheard draft.
        or ((p.open_mic_at is not null or p.showcased_at is not null)
            and shared_at is not null)
      )
  )
);

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
      select 1
      from public.files f
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
          and (p.open_mic_at is not null or p.showcased_at is not null)
      )
    )
  )
);
