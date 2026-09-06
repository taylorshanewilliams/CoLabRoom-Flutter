-- Retiring studio_drafts, so a recording is a song straight away.
--
-- The Studio kept a second library. A recording landed in `studio_drafts`
-- with its own analysis columns, its own state machine and its own storage
-- bucket, and became a song only when somebody pressed "Use in a song" — a
-- conversion step that is where a song once forked into two projects holding
-- the same name and half the words each.
--
-- Everything that step existed to do already exists on the project side. Both
-- paths call the same `analyze-chords` function; the only difference is which
-- table the answer lands in. So the second table goes, and a recording starts
-- life as what it always was.
--
-- **Nothing is destroyed here.** Seven drafts exist. Two became songs and
-- five did not, and one of those five is called "Took time to understand I'm
-- not" — an eighteen-second phone recording named from the words somebody
-- sang into it. That is not test material, whatever the mp3 re-uploads beside
-- it are. So the rows are archived rather than dropped, the audio stays
-- exactly where it is in the `studio-drafts` bucket, and recovering any of it
-- later is a decision somebody can still make.

-- ---------------------------------------------------------------------
-- Somewhere for a recording with no home yet
-- ---------------------------------------------------------------------

-- The catalog a recording lands in when nobody has said where it goes.
--
-- Created on first use rather than at signup, so an account that never
-- records never grows an empty catalog it has to look at. Find-or-create in
-- one call, under an advisory lock on the caller's own id: two recordings
-- started at once must not race into two catalogs both called Ideas.
create or replace function public.ideas_catalog()
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  found uuid;
begin
  if me is null then
    raise exception 'You must be signed in.' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtext('ideas_catalog:' || me::text));

  select r.id into found
  from public.rooms r
  where r.account_id = me and lower(trim(r.name)) = 'ideas'
  limit 1;

  if found is not null then
    return found;
  end if;

  insert into public.rooms (account_id, name, icon)
  values (me, 'Ideas', '💡')
  returning id into found;

  -- The colour comes from 0047's trigger rather than being named here, which
  -- is what stopped a second person joining a catalog from colliding with the
  -- first.
  insert into public.room_members (room_id, user_id, display_name, role)
  values (found, me,
          coalesce((select display_name from public.profiles where id = me),
                   'Member'),
          'owner')
  on conflict (room_id, user_id) do nothing;

  return found;
end;
$$;

revoke all on function public.ideas_catalog() from public, anon;
grant execute on function public.ideas_catalog() to authenticated;

-- ---------------------------------------------------------------------
-- Archiving what was there
-- ---------------------------------------------------------------------

-- Not a working table. A record of what the drafts were and where their audio
-- sits, so "retired" does not have to mean "gone" and nobody has to trust
-- that a judgement made in August about five rows still holds for seven.
create table if not exists public.retired_studio_drafts (
  id uuid primary key,
  account_id uuid references public.profiles(id) on delete cascade,
  display_name text,
  storage_path text,
  duration_ms integer,
  musical_key text,
  transcript_text text,
  became_project uuid,
  created_at timestamptz,
  retired_at timestamptz not null default now()
);

alter table public.retired_studio_drafts enable row level security;

-- Your own, readable. Nobody writes to this from a phone.
drop policy if exists retired_drafts_read_own on public.retired_studio_drafts;
create policy retired_drafts_read_own on public.retired_studio_drafts
for select to authenticated using (account_id = (select auth.uid()));

do $$
begin
  if exists (
    select 1 from information_schema.tables
    where table_schema = 'public' and table_name = 'studio_drafts'
  ) then
    insert into public.retired_studio_drafts
      (id, account_id, display_name, storage_path, duration_ms,
       musical_key, transcript_text, became_project, created_at)
    select d.id, d.account_id, d.display_name, d.storage_path, d.duration_ms,
           d.musical_key, d.transcript_text, d.promoted_project_id, d.created_at
    from public.studio_drafts d
    on conflict (id) do nothing;
  end if;
end $$;

-- Everything that points at the table, before the table.
--
-- Dropping it outright fails: a policy on `storage.objects` gates the
-- `studio-drafts` bucket by looking a row up in `studio_drafts`, and the
-- realtime publication carries it. Neither is a foreign key, so neither is
-- visible from the table definition — they are only visible from the error.
drop policy if exists studio_drafts_files_owner on storage.objects;

do $$
begin
  if exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'studio_drafts'
  ) then
    alter publication supabase_realtime drop table public.studio_drafts;
  end if;
end $$;

-- The whole family, and explicitly rather than by cascade. `drop ... cascade`
-- removes the dependent *constraints* and leaves the dependent tables behind
-- as orphans with no parent and no purpose, which is a worse mess than the
-- one being cleaned up. Children first, then the parent.
drop table if exists public.studio_chord_cues;
drop table if exists public.studio_draft_stems;

-- The audio itself is deliberately left alone. Dropping the bucket would
-- destroy recordings in a migration, which is not a thing to do on the
-- strength of a filename looking like a test.
drop table if exists public.studio_drafts;
