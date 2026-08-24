-- The room you are both in while you work on a song.
--
-- One stream, carrying two things that are usually kept apart: what people
-- say, and what the app did. That is the whole design, and it exists to solve
-- the reason in-app chat almost always dies — the empty room. Nobody types
-- into a blank box, so it stays blank, so it looks abandoned, so nobody
-- types.
--
-- A stream the app itself fills is never blank. "Taylor added a recording",
-- "Analysis finished", "Jess rewrote the chorus" — it is alive before anyone
-- says a word, and saying something into it becomes the obvious next move
-- rather than a leap of faith. That is also, on its own, the "keep each other
-- up to date" half of the problem, and it needs nobody to type at all.
--
-- Deliberately not a general band chat. This belongs to one song, and its
-- competition is not Discord: a band already has a group chat and will not
-- move it. What Discord cannot do is sit beside the song and tell you what
-- just changed in it.

create table public.project_events (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,

  -- Null for a system event with no human behind it, and for a person whose
  -- account has since been deleted. Their words stay; a conversation with
  -- half of it removed is worse for the people still in it.
  actor_id uuid references public.profiles(id) on delete set null,

  -- 'message' is a person talking. Everything else is the app reporting, and
  -- is written by triggers or by the service role rather than by a client.
  kind text not null check (
    kind in ('message', 'edited', 'analyzed', 'recording', 'joined')
  ),

  body text not null default '',

  created_at timestamptz not null default now()
);

create index project_events_project_created_idx
  on public.project_events (project_id, created_at desc);

-- Coalescing key for automatic events. Without it, a lyric editor that saves
-- on a 700ms debounce would post "Jess made an edit" every few seconds and
-- bury every real message in the stream. Events that share a bucket collapse
-- into one; see the trigger below.
create index project_events_coalesce_idx
  on public.project_events (project_id, actor_id, kind, created_at desc);

alter table public.project_events enable row level security;

-- Same read shape as project_stems: a project member sees their project's
-- stream, a room member sees every project's stream in that room, both
-- through the security-definer helpers rather than plain subqueries (see
-- migration 0016 for why that distinction is load-bearing).
create policy project_events_read_members on public.project_events
for select to authenticated using (
  private.is_project_member(project_id)
  or exists (
    select 1 from public.projects p
    where p.id = project_id and private.is_room_member(p.room_id)
  )
);

-- You may say things, as yourself. You may not author the app's voice: a
-- client that could insert 'analyzed' could put a finished analysis in the
-- stream of a song that has none.
create policy project_events_write_own_messages on public.project_events
for insert to authenticated with check (
  kind = 'message'
  and actor_id = (select auth.uid())
  and char_length(trim(body)) between 1 and 2000
  and (
    private.is_project_member(project_id)
    or exists (
      select 1 from public.projects p
      where p.id = project_id and private.is_room_member(p.room_id)
    )
  )
);

-- Deleting your own message. No edit: a stream where earlier lines can change
-- under you is a stream you cannot trust, and "delete and say it again" is
-- the honest version of editing in a conversation.
create policy project_events_delete_own on public.project_events
for delete to authenticated using (
  kind = 'message' and actor_id = (select auth.uid())
);

-- ---------------------------------------------------------------------
-- The app's own voice.
-- ---------------------------------------------------------------------

-- How long an automatic event absorbs later ones of the same kind from the
-- same person. Someone working through a verse produces a save every few
-- seconds; the useful statement is "Jess is working on the lyrics", once,
-- not ninety times.
create or replace function private.record_project_event(
  target_project uuid,
  actor uuid,
  event_kind text,
  event_body text,
  coalesce_within interval default interval '10 minutes'
)
returns void
language plpgsql
security definer set search_path = ''
as $$
begin
  if target_project is null or event_kind is null then
    return;
  end if;
  -- Already said recently enough. Refreshing the timestamp rather than
  -- inserting keeps the stream ordered by when someone was last active,
  -- which is what a reader actually wants to know.
  if exists (
    select 1 from public.project_events e
    where e.project_id = target_project
      and e.actor_id is not distinct from actor
      and e.kind = event_kind
      and e.created_at > now() - coalesce_within
  ) then
    update public.project_events e
    set created_at = now(), body = coalesce(nullif(event_body, ''), e.body)
    where e.id = (
      select id from public.project_events
      where project_id = target_project
        and actor_id is not distinct from actor
        and kind = event_kind
      order by created_at desc
      limit 1
    );
    return;
  end if;
  insert into public.project_events (project_id, actor_id, kind, body)
  values (target_project, actor, event_kind, coalesce(event_body, ''));
end;
$$;

revoke all on function private.record_project_event(uuid, uuid, text, text, interval)
  from public, anon, authenticated;

-- Lyric edits. The one automatic event that would drown the stream without
-- coalescing, and the one that most says "somebody is in here with you".
create or replace function private.on_contribution_changed()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
begin
  perform private.record_project_event(
    coalesce(new.project_id, old.project_id),
    auth.uid(),
    'edited',
    'made changes to the lyrics'
  );
  return null;
exception
  when others then
    -- Never let the stream stop somebody writing. A missing event is a gap
    -- in a feed; a failed insert here would be a lyric that wouldn't save.
    return null;
end;
$$;

drop trigger if exists contributions_project_event on public.contributions;
create trigger contributions_project_event
after insert or update of body on public.contributions
for each row execute function private.on_contribution_changed();
