-- One notification for a session of writing, not one per line.
--
-- notify_project_update is a FOR EACH STATEMENT trigger, and it counts the
-- rows in the statement that fired it — so it already says "added 12 lines"
-- when twelve arrive together. That is what a paste or an import looks like.
--
-- It is not what writing looks like. The lyric editor saves a line at a time,
-- so each line is its own INSERT, its own statement, and its own
-- notification. Somebody working through a verse produced a screenful, and
-- the inbox stopped being worth opening — which is the expensive failure
-- here, because the same inbox carries invitations.
--
-- 0032 solved exactly this for the song's own stream, and the fix is the same
-- shape: an unread notification about the same person writing in the same
-- song is not a second piece of news, it is the same news continuing. Update
-- it rather than adding to the pile.
--
-- Only project_update coalesces. An invitation is a discrete event about a
-- discrete decision, and two of them are genuinely two.

create or replace function private.notify_project_update_coalesced(
  target_user uuid,
  target_room uuid,
  target_project uuid,
  actor uuid,
  actor_name text,
  project_title text,
  window_size interval default interval '2 hours'
)
returns void
language plpgsql
security definer set search_path = ''
as $$
declare
  existing uuid;
  lines integer;
  new_title text;
begin
  -- Unread only. A notification somebody has already read has been dealt
  -- with, and quietly rewriting it underneath them would change what they
  -- remember seeing.
  select id into existing
  from public.notifications
  where user_id = target_user
    and type = 'project_update'
    and project_id = target_project
    and actor_id = actor
    and read_at is null
    and created_at > now() - window_size
  order by created_at desc
  limit 1;

  -- Counted from the contributions themselves rather than kept on the
  -- notification. There is nowhere on the row to store a tally, and a count
  -- derived from the writing cannot drift away from it.
  select count(*) into lines
  from public.contributions c
  where c.project_id = target_project
    and c.author_id = actor
    and c.deleted_at is null
    and c.created_at > now() - window_size;

  if lines <= 1 then
    new_title := coalesce(actor_name, 'Someone') || ' added to '
      || coalesce(project_title, 'a song');
  else
    new_title := coalesce(actor_name, 'Someone') || ' added ' || lines
      || ' lines to ' || coalesce(project_title, 'a song');
  end if;

  if existing is null then
    perform private.notify_user(
      target_user, 'project_update', new_title, '',
      target_room, target_project, null, actor
    );
  else
    -- Bumped to now so the inbox stays ordered by when somebody was last
    -- working, which is the order that makes it readable.
    update public.notifications
    set title = new_title, body = '', created_at = now()
    where id = existing;
  end if;
end;
$$;

revoke all on function private.notify_project_update_coalesced(
  uuid, uuid, uuid, uuid, text, text, interval) from public, anon, authenticated;

create or replace function public.notify_project_update()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
declare
  row_count integer;
  first_project_id uuid;
  first_author_id uuid;
  first_author_name text;
  target_room uuid;
  project_title text;
  member uuid;
begin
  select count(*), min(project_id), min(author_id), min(author_name)
    into row_count, first_project_id, first_author_id, first_author_name
    from new_rows;

  if row_count is null or row_count = 0 then
    return null;
  end if;

  select room_id, title into target_room, project_title
  from public.projects where id = first_project_id;

  for member in
    select user_id from public.room_members
    where room_id = target_room and user_id <> first_author_id
    union
    select user_id from public.project_members
    where project_id = first_project_id and user_id <> first_author_id
  loop
    perform private.notify_project_update_coalesced(
      member, target_room, first_project_id,
      first_author_id, first_author_name, project_title
    );
  end loop;

  return null;
end;
$$;

revoke all on function public.notify_project_update() from public, anon, authenticated;
