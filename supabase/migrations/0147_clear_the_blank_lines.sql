-- Clear the lines that were never written.
--
-- A lyric line with nothing in it is stored as a zero-width space, because
-- contributions.body has a non-empty check. Until #328 a cursor move counted
-- as an edit, so opening a song and touching the writing space saved one of
-- those lines without anybody typing a word.
--
-- Five songs in one real room carried exactly one each, made between
-- 15 August and 17 September 2026. The cost was not the invisible character:
-- a song with one blank line is a song with lines, so the app treated it as
-- written. "The words are on the song sheet" (#337) never drew on Dakota,
-- the song it was written for, because of it. #347 makes the app ignore such
-- lines; this removes them.
--
-- Scope, and the whole care of this file: only a song whose lines are ALL
-- blank. A blank line between two verses is deliberate, and stays.
--
-- Nothing else goes with them. A line can carry a voice note (0003) and a
-- lyric cue (0007), both of which cascade; the rows here have neither, and
-- the check below refuses to run if that ever stops being true.

begin;

do $$
declare
  songs integer;
  lines integer;
  attached integer;
begin
  create temporary table unwritten_songs on commit drop as
  select c.project_id
  from public.contributions c
  where c.deleted_at is null
  group by c.project_id
  having count(*) filter (
    -- Zero-width space, non-joiner, joiner and byte-order mark: every way an
    -- invisible character has reached this column. Then the whitespace a
    -- paste can leave behind, named explicitly because btrim on its own only
    -- takes ordinary spaces: tab, newline, carriage return, non-breaking
    -- space.
    where length(btrim(
      translate(c.body, chr(8203) || chr(8204) || chr(8205) || chr(65279), ''),
      chr(32) || chr(9) || chr(10) || chr(13) || chr(160)
    )) > 0
  ) = 0;

  select count(*) into songs from unwritten_songs;

  select count(*) into attached
  from public.contributions c
  join unwritten_songs u on u.project_id = c.project_id
  where exists (select 1 from public.files f where f.contribution_id = c.id)
     or exists (select 1 from public.lyric_sync_cues q where q.contribution_id = c.id);

  if attached > 0 then
    raise exception
      'A blank line with a voice note or a lyric cue on it is not the artefact this migration is for (% of them).',
      attached;
  end if;

  delete from public.contributions c
  using unwritten_songs u
  where c.project_id = u.project_id
    and c.deleted_at is null;
  get diagnostics lines = row_count;

  raise notice 'Cleared % blank line(s) from % song(s) that had nothing else written in them.', lines, songs;
end;
$$;

commit;
