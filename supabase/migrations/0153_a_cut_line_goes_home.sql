-- A line you cut goes back to whoever wrote it.
--
-- Until now a line taken out of a song was deleted, and its voice note with
-- it. In a song two people wrote that is one person's words disappearing at
-- another person's hand, with nothing to show they were ever there. #343
-- made a new line in the middle keep every line with its writer; this is the
-- other half of "nobody's words disappear" (Every Musician, Same Song,
-- 17 September 2026): a line is cut, never deleted, and its writer can find
-- it again.
--
-- **The shape: the row stays, marked cut.** contributions has carried a
-- deleted_at column since 0001 that nothing ever set. A cut sets it. The
-- line keeps its id, its writer, its colour, its place and its voice note,
-- and it stops being part of the song. The plan offered two places for the
-- writer to find it -- a note in their own Ideas room, or a list on the song
-- -- and this is the list, because it is the smaller thing by a wide margin.
-- A copy in the Ideas room means a security-definer function making a room
-- and a song in somebody else's catalogue (ideas_catalog runs for auth.uid()
-- alone, behind an advisory lock), a title for every cut that the account's
-- title index refuses the second time, and a new row that has lost its voice
-- note and its place in the song. The list keeps the row itself.
--
-- **Who reads a cut line.** Nobody, through the table: the read policy now
-- shows a song's live lines to its members and nothing else, so no select
-- the app makes -- today's or a later one -- can put a cut line back in the
-- song by mistake. The writer reads their own cut lines through
-- lines_you_cut, which answers for auth.uid() and nobody else. The person
-- who cut the line is not the writer, and gets nothing.
--
-- **Who cuts.** The same people who could delete: an editor or owner of the
-- room, or of the song when it was shared on its own (0013). Cutting is
-- editing, and somebody who can only look cannot take a line out. Through
-- cut_line rather than an update, because 0006 limits direct updates to body
-- and position and that limit is worth keeping.
--
-- **The delete policy goes.** With it, a client could still remove a line
-- for good. The app no longer asks to, and a rule that lives only in the app
-- is one request away from nothing. Cascades are untouched: deleting a song
-- still takes its lines with it, and 0065 still empties an account.

begin;

-- ---------------------------------------------------------------------
-- Cutting a line
-- ---------------------------------------------------------------------

create or replace function public.cut_line(target_line uuid)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  line record;
  may_cut boolean;
begin
  select c.id, c.project_id, p.room_id
  into line
  from public.contributions c
  join public.projects p on p.id = c.project_id and p.deleted_at is null
  where c.id = target_line;

  -- Not there at all is not an error either. The delete this replaces was
  -- quiet about a row that had already gone, and the editor's save loop,
  -- which is what calls this, must not fail over a line that is already
  -- out of the song.
  if not found then
    return;
  end if;

  -- coalesce, because somebody in neither the room nor the song has no role
  -- at all, `null in (...)` is null, and `if not null then` does not fire:
  -- the plain form would wave through the exact person this check exists
  -- to stop. 0068 is the migration that learned this the hard way.
  may_cut := coalesce(private.project_role_for(line.project_id) in ('owner', 'editor'), false)
          or coalesce(private.room_role_for(line.room_id) in ('owner', 'editor'), false);

  if not may_cut then
    raise exception 'Only somebody who can edit this song can cut a line.'
      using errcode = '42501';
  end if;

  -- Already cut is not an error. Two editors can take the same line out in
  -- the same minute, and the second save must not fail over it; the first
  -- cut's time stands.
  update public.contributions
  set deleted_at = now()
  where id = target_line and deleted_at is null;

  if found then
    -- The song changed, and the song's row is how the rest of the room hears
    -- about it. The line's own change cannot reach anybody: phones listen to
    -- contributions through the read policy, and a row it now hides is a
    -- change the live channel does not deliver. A deleted row used to reach
    -- every phone in the room; the song's row still does.
    update public.projects
    set updated_at = now()
    where id = line.project_id;
  end if;
end;
$fn$;

revoke all on function public.cut_line(uuid) from public, anon;
grant execute on function public.cut_line(uuid) to authenticated;

comment on function public.cut_line(uuid) is
  'Takes a line out of its song without deleting it. The row keeps its '
  'writer, its place and its voice note, and only its writer can read it '
  'again, through lines_you_cut.';

-- ---------------------------------------------------------------------
-- Finding your own cut lines
-- ---------------------------------------------------------------------

-- Your own, and only your own: the writer is the one person a cut line is
-- kept for, whoever cut it. No membership check on purpose. Somebody who has
-- left the room can no longer open the song, but the words are still theirs.
create or replace function public.lines_you_cut(target_project uuid)
returns setof public.contributions
language sql
stable
security definer
set search_path = public
as $$
  select c.*
  from public.contributions c
  where c.project_id = target_project
    and c.author_id = auth.uid()
    and c.deleted_at is not null
  order by c.deleted_at desc, c.position asc, c.created_at asc;
$$;

revoke all on function public.lines_you_cut(uuid) from public, anon;
grant execute on function public.lines_you_cut(uuid) to authenticated;

comment on function public.lines_you_cut(uuid) is
  'The lines of yours that have been cut from a song, whoever cut them, '
  'newest cut first. Answers for auth.uid() and nobody else.';

-- ---------------------------------------------------------------------
-- A cut line is not part of the song
-- ---------------------------------------------------------------------

-- Restated from 0013, which was its latest definition, with one change: only
-- a line that is still in the song. Everything the app reads of a song comes
-- through this policy, so a cut line cannot come back through any of it.
drop policy if exists contributions_read_members on public.contributions;
create policy contributions_read_members on public.contributions
for select to authenticated using (
  deleted_at is null
  and (
    private.is_project_member(project_id)
    or exists (select 1 from public.projects p where p.id = project_id and private.is_room_member(p.room_id))
  )
);

-- A line is cut, never deleted.
drop policy if exists contributions_delete_room_editors on public.contributions;

commit;
