-- What each person has already heard.
--
-- The pull in a band app is one sentence: somebody played something for you
-- and you have not heard it yet. Nothing in the schema could express that.
--
-- song_layers.last_opened_at looks like the answer and is not. It is a single
-- column on the layer, stamped for every layer whenever anyone opens the
-- takes screen, so it records that *somebody* opened it — the input retention
-- needs, and exactly the wrong shape for a badge. A bandmate listening would
-- clear the marker for everyone else. Read state has to carry a person on it.
--
-- Per project rather than per layer, deliberately. Per layer is one row per
-- person per take and answers a question nobody asks ("which of these six did
-- I hear"); per project is one row per person per song and answers the one
-- they do ("is there anything new on this"). A song opened is a song heard.
create table public.project_reads (
  project_id uuid not null references public.projects(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  -- Moves forward only. Opening a song is the act of catching up, and going
  -- backwards would resurrect a badge somebody already dealt with.
  last_seen_at timestamptz not null default now(),
  primary key (project_id, profile_id)
);

create index project_reads_profile_idx on public.project_reads (profile_id);

alter table public.project_reads enable row level security;

-- Your own read state, and nobody else's. There is no legitimate reason for
-- one member to see when another last listened — that is a presence signal
-- this app has deliberately decided not to have, and leaving it readable
-- would be shipping it by accident.
create policy project_reads_read_own on public.project_reads
for select to authenticated using (profile_id = (select auth.uid()));

create policy project_reads_write_own on public.project_reads
for insert to authenticated with check (
  profile_id = (select auth.uid())
  and exists (
    select 1 from public.projects p
    where p.id = project_id and private.is_room_member(p.room_id)
  )
);

create policy project_reads_update_own on public.project_reads
for update to authenticated using (profile_id = (select auth.uid()))
with check (profile_id = (select auth.uid()));

-- Catching up on one song.
--
-- A function rather than an upsert from the client so "only ever forwards" is
-- enforced in one place. greatest() against the existing value means an
-- out-of-order call — a slow request landing after a newer one — cannot
-- rewind somebody's read state and make heard takes unread again.
create or replace function public.mark_project_seen(target_project uuid)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  if not private.is_room_member(
    (select room_id from public.projects where id = target_project)
  ) then
    raise exception 'not a member of that room';
  end if;

  insert into public.project_reads (project_id, profile_id, last_seen_at)
  values (target_project, auth.uid(), now())
  on conflict (project_id, profile_id) do update
    set last_seen_at = greatest(public.project_reads.last_seen_at, excluded.last_seen_at);
end;
$$;

revoke all on function public.mark_project_seen(uuid) from public, anon;
grant execute on function public.mark_project_seen(uuid) to authenticated;

-- How many takes have arrived on each song since you last listened.
--
-- Your own takes never count. Pressing record and then being told you have
-- one unheard part is the app failing to know who you are, and it is the
-- fastest way to teach somebody that the badge means nothing.
--
-- A song never opened counts everything on it, which is what makes an
-- invitation to a song that already has parts arrive as parts rather than as
-- silence.
create or replace function public.unheard_take_counts()
returns table (project_id uuid, unheard integer)
language sql
security invoker
set search_path = public
as $$
  select l.project_id, count(*)::integer as unheard
  from public.song_layers l
  join public.projects p on p.id = l.project_id
  where l.recorded_by <> auth.uid()
    and private.is_room_member(p.room_id)
    and l.created_at > coalesce(
      (select r.last_seen_at from public.project_reads r
        where r.project_id = l.project_id and r.profile_id = auth.uid()),
      'epoch'::timestamptz
    )
  group by l.project_id;
$$;

revoke all on function public.unheard_take_counts() from public, anon;
grant execute on function public.unheard_take_counts() to authenticated;
