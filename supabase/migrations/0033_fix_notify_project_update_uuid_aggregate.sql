-- No line could be added to a song. Not a slow save, not a flaky one: every
-- insert into `contributions` was refused outright, and had been since 0018
-- introduced the trigger below.
--
-- `notify_project_update` opened with
--
--   select count(*), min(project_id), min(author_id), min(author_name) ...
--
-- and Postgres has no `min(uuid)`. It has `<` for uuid, so `order by` on one
-- is fine, but the min/max aggregates are simply not defined for the type
-- before PG 18. plpgsql does not plan a statement until it runs, so this was
-- created without complaint and threw `function min(uuid) does not exist`
-- the first time anybody wrote a lyric — 42883, inside an AFTER INSERT
-- trigger, which takes the whole transaction down with it.
--
-- The app reported that as a save that would not go through, and the editor
-- retried it on a 700ms timer, which is the same failure every time: the
-- trigger has no opinion about the row, it cannot compile its own first
-- query. Only inserts were affected, so editing a line already in the song
-- kept working and only *new* writing was lost — which is the worst possible
-- shape for this bug, because the song looked healthy right up until you
-- added to it.
--
-- The aggregate was never the point. It wanted one representative row out of
-- the statement's transition table, so it asks for one, ordered the way the
-- document is ordered rather than by whichever uuid happened to sort first.
-- That is also more correct than the original intended: for a bulk import,
-- `min(author_id)` was the smallest uuid among the authors, which is nobody
-- in particular.

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
  first_body text;
  target_room uuid;
  project_title text;
  notif_title text;
  notif_body text;
  member uuid;
begin
  select count(*) into row_count from new_rows;

  if row_count is null or row_count = 0 then
    return null;
  end if;

  -- The first line of the batch as the document orders it, which for a
  -- one-row insert is simply the line that was just written. `id` breaks the
  -- tie so a bulk import with identical positions still picks deterministically.
  select project_id, author_id, author_name, body
    into first_project_id, first_author_id, first_author_name, first_body
    from new_rows
    order by new_rows."position", new_rows.created_at, new_rows.id
    limit 1;

  select room_id, title into target_room, project_title
  from public.projects where id = first_project_id;

  if row_count = 1 then
    notif_title := coalesce(first_author_name, 'Someone') || ' added to ' || coalesce(project_title, 'a song');
    notif_body := left(coalesce(first_body, ''), 140);
  else
    notif_title := coalesce(first_author_name, 'Someone') || ' added ' || row_count || ' lines to '
      || coalesce(project_title, 'a song');
    notif_body := '';
  end if;

  for member in
    select user_id from public.room_members
    where room_id = target_room and user_id <> first_author_id
    union
    select user_id from public.project_members
    where project_id = first_project_id and user_id <> first_author_id
  loop
    perform private.notify_user(
      member,
      'project_update',
      notif_title,
      notif_body,
      target_room,
      first_project_id,
      null,
      first_author_id
    );
  end loop;

  return null;
end;
$$;

revoke all on function public.notify_project_update() from public, anon, authenticated;
