-- Layers a band records over each other, and the combinations they save.
--
-- The shape here follows one decision: layers belong to the *song*, not to a
-- version of it. A version is a saved set of layers, which makes it metadata
-- over audio that already exists — a few hundred bytes rather than another
-- copy of the recording. That is what makes sharing affordable enough to give
-- away: a layer is uploaded once ever, and a band can then explore endlessly
-- without moving another byte.
--
-- It is also what "everyone hears what the person who recorded it wanted them
-- to hear" costs: one row, not one upload.
--
-- The scope this is built for is ideas and collaboration, not production. A
-- band that is ready to properly record a song will not be doing it here, and
-- nothing below should be read as the start of a DAW.

create table public.song_layers (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  -- Who played it. The basis of "Dylan's lead" everywhere in the app, and the
  -- only person besides a room owner allowed to delete it.
  recorded_by uuid not null default auth.uid() references public.profiles(id),
  storage_path text not null,
  label text not null default '',
  -- Free text rather than an enum. The app offers a short list, and a list
  -- that needs a migration every time a band names something new is a list
  -- that will be wrong.
  part text not null default 'other',
  -- The name shown for the player, which is not always the account holder: a
  -- phone gets handed around a room.
  performer text,
  duration_ms integer,
  -- Latency correction, in milliseconds trimmed from the front. Stored per
  -- layer because it is a property of the take — one may have been recorded
  -- on speaker and the next on Bluetooth.
  offset_ms integer not null default 0,
  gain real not null default 1.0 check (gain >= 0 and gain <= 2),
  byte_size bigint,
  created_at timestamptz not null default now(),
  -- Retention's input. Touched when somebody actually plays the layer, so
  -- expiry can be about what a band still uses rather than how old it is.
  last_opened_at timestamptz not null default now()
);

create index song_layers_project_idx on public.song_layers (project_id, created_at);
create index song_layers_recorded_by_idx on public.song_layers (recorded_by);
create index song_layers_last_opened_idx on public.song_layers (last_opened_at);

-- A named combination. Deliberately an array of ids rather than a join table:
-- a version is read whole, written whole, and never queried by "which
-- versions contain this layer" — and the array keeps a saved mix to a single
-- row, which is the entire economic argument for versions existing.
create table public.song_layer_versions (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  created_by uuid not null default auth.uid() references public.profiles(id),
  -- Null means nobody typed one, and the app composes a name from the layers
  -- instead. Kept nullable rather than defaulted so a chosen name is
  -- distinguishable from a generated one.
  name text,
  layer_ids uuid[] not null default '{}',
  created_at timestamptz not null default now()
);

create index song_layer_versions_project_idx
  on public.song_layer_versions (project_id, created_at desc);

alter table public.song_layers enable row level security;
alter table public.song_layer_versions enable row level security;

-- ---------------------------------------------------------------------
-- Who may do what.
--
-- Read and add: any member of the room. Adding a part is the whole point.
--
-- Delete: the person who recorded it, or a room owner. Not "anyone", because
-- deleting is the one action here that destroys somebody else's playing and
-- cannot be undone. Muting — which is what a bandmate actually wants when a
-- layer is in the way — is a local view and costs nobody anything, so the
-- destructive version does not need to be shared out.
--
-- Update: only the recorder. Gain and offset are how a take is meant to sit;
-- a bandmate who disagrees mutes it or saves their own version.
-- ---------------------------------------------------------------------

create policy song_layers_read_members on public.song_layers
for select to authenticated using (
  exists (
    select 1 from public.projects p
    where p.id = project_id and private.is_room_member(p.room_id)
  )
);

create policy song_layers_insert_members on public.song_layers
for insert to authenticated with check (
  recorded_by = auth.uid()
  and exists (
    select 1 from public.projects p
    where p.id = project_id and private.is_room_member(p.room_id)
  )
);

create policy song_layers_update_own on public.song_layers
for update to authenticated using (recorded_by = auth.uid())
with check (recorded_by = auth.uid());

create policy song_layers_delete_own_or_owner on public.song_layers
for delete to authenticated using (
  recorded_by = auth.uid()
  or exists (
    select 1 from public.projects p
    where p.id = project_id and private.room_role_for(p.room_id) = 'owner'
  )
);

-- Versions are cheap and disposable, so anyone in the room may save one and
-- anyone may tidy up their own. A version holding no audio means deleting one
-- costs nothing but the name.
create policy song_layer_versions_read_members on public.song_layer_versions
for select to authenticated using (
  exists (
    select 1 from public.projects p
    where p.id = project_id and private.is_room_member(p.room_id)
  )
);

create policy song_layer_versions_insert_members on public.song_layer_versions
for insert to authenticated with check (
  created_by = auth.uid()
  and exists (
    select 1 from public.projects p
    where p.id = project_id and private.is_room_member(p.room_id)
  )
);

create policy song_layer_versions_modify_own on public.song_layer_versions
for update to authenticated using (created_by = auth.uid())
with check (created_by = auth.uid());

create policy song_layer_versions_delete_own on public.song_layer_versions
for delete to authenticated using (created_by = auth.uid());

grant select, insert, update, delete on table public.song_layers to authenticated;
grant select, insert, update, delete on table public.song_layer_versions to authenticated;

-- ---------------------------------------------------------------------
-- Storage. Layers live in room-files beside everything else a project owns,
-- under {project_id}/layers/{layer_id}.
--
-- The read policy is keyed on the layer row rather than on the path, so a
-- deleted row makes its object unreadable immediately and there is one place
-- that decides who may hear what.
-- ---------------------------------------------------------------------

create policy song_layer_files_read_members on storage.objects
for select to authenticated using (
  bucket_id = 'room-files'
  and exists (
    select 1
    from public.song_layers l
    join public.projects p on p.id = l.project_id
    where l.storage_path = name and private.is_room_member(p.room_id)
  )
);

-- Written before the row exists, so this one has to trust the path: the
-- upload happens first and the row is inserted once the bytes are there.
-- Scoped to a project the writer is actually a member of, which is the part
-- that matters.
create policy song_layer_files_write_members on storage.objects
for insert to authenticated with check (
  bucket_id = 'room-files'
  and name like '%/layers/%'
  and exists (
    select 1 from public.projects p
    where private.is_room_member(p.room_id)
      and name like p.id::text || '/layers/%'
  )
);

create policy song_layer_files_delete_own on storage.objects
for delete to authenticated using (
  bucket_id = 'room-files'
  and exists (
    select 1
    from public.song_layers l
    join public.projects p on p.id = l.project_id
    where l.storage_path = name
      and (l.recorded_by = auth.uid() or private.room_role_for(p.room_id) = 'owner')
  )
);

-- ---------------------------------------------------------------------
-- Tell the band.
--
-- "Dylan added a lead" is the thing that pulls people back into a song, and
-- it is the reason this side of the app is worth giving away: layers cost
-- almost nothing to move and they are what keeps a band coming back.
--
-- Every other member of the room, not just the song's owner — a part added to
-- a song is addressed to everyone working on it. notify_user already declines
-- to notify the actor about their own action, so the recorder is skipped
-- without needing to be excluded here.
-- ---------------------------------------------------------------------

create or replace function public.notify_layer_added()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
declare
  song record;
  member record;
  who text;
begin
  select id, room_id, title into song
  from public.projects
  where id = new.project_id;

  who := coalesce(
    nullif(trim(new.performer), ''),
    (select display_name from public.profiles where id = new.recorded_by),
    'Someone'
  );

  for member in
    select user_id from public.room_members where room_id = song.room_id
  loop
    perform private.notify_user(
      member.user_id,
      'project_update',
      who || ' added a part to ' || coalesce(song.title, 'a song'),
      case
        when coalesce(trim(new.label), '') <> '' then new.label
        else 'A new layer is on the song.'
      end,
      song.room_id,
      new.project_id,
      null,
      new.recorded_by
    );
  end loop;

  return new;
end;
$$;

create trigger song_layers_notify_added
after insert on public.song_layers
for each row execute function public.notify_layer_added();
