-- Say what language the song is sung in.
--
-- Every Musician, Same Song, 17 September 2026, world traditions item 3. The
-- sheet had one idea of how words are written down: left to right, with
-- spaces between them. A song in Arabic came out left-aligned with its
-- chords over the wrong end of every line, and a song in Chinese put every
-- chord in a line over its first character, because a line with no spaces in
-- it is one word to anything that splits on white space. Both are the same
-- assumption, and neither can be fixed by looking harder at the words: which
-- way a line runs and what a chord sits over are decided by the language,
-- and the language is something a person says.
--
-- **Declared, never inferred.** Not from the characters, not from the
-- recording, and not from anybody's profile. The plan rules out guessing
-- somebody's language, and guessing a song's is the same guess one step
-- removed -- a band that sings in Arabic and writes its lyrics in Latin
-- letters would be told what it sings in by a regular expression. So this is
-- a field somebody fills in, and an empty one means only that nobody has
-- said. A song nobody has answered for is laid out exactly the way this app
-- laid out every song before this column existed.
--
-- **A shared fact, not a reading.** The same distinction 0144 drew for the
-- key and 0161 for bar 1. A person's transpose, their capo, their horn part
-- and which script they read numbers in are personal and live on their own
-- device. This one is not: it turns the page around for everybody, so two
-- people in one room cannot be reading it two ways.
--
-- **A tag rather than a word.** It goes to the transcriber as a hint as well
-- as to the page, and a transcriber takes an ISO code rather than the word
-- "Arabic" -- so it is stored as a BCP-47 tag. The app names the languages it
-- can name and takes a typed tag for the ones it cannot, so nothing is
-- excluded by not being on a list.

alter table public.projects
  add column if not exists language text
  -- A BCP-47 tag in one spelling: language lower case, an optional script
  -- capitalised, an optional region upper case -- 'ar', 'pt-BR', 'zh-Hans'.
  -- One spelling because the app looks the tag up to decide which way the
  -- page runs, and 'ZH-hans' would find nothing and lay a Chinese song out
  -- like an English one. The same expression as `_tagShape` in
  -- lib/services/song_language.dart.
  check (language is null
         or language ~ '^[a-z]{2,3}(-[A-Z][a-z]{3})?(-([A-Z]{2}|[0-9]{3}))?$');

comment on column public.projects.language is
  'The language this song is sung in, as a BCP-47 tag. Null means nobody '
  'has said, and the sheet is laid out as it always was. Declared by the '
  'room''s owner or an editor through set_song_language, never inferred '
  'from the words, the recording or a profile.';

-- ---------------------------------------------------------------------
-- Saying what it is sung in
-- ---------------------------------------------------------------------

-- Owner or editor: the same two who can say what key the song is in (0144),
-- where bar 1 is (0161) and whose song it is (0142). Anybody trusted to
-- write on a song is trusted to say what language it is sung in -- it is
-- usually the singer who noticed, not the person who owns the catalog.
-- Somebody who can only look cannot turn everybody else's page around.
--
-- A null `in_language` takes the answer away, which is how "Not said" is
-- spelled. That is a real answer and not a missing argument, so it is not an
-- error.
--
-- The tag is folded to the one spelling the check takes before it is looked
-- at, so a caller sending 'AR' or 'zh-hans' is storing the same language as
-- one sending 'ar' or 'zh-Hans' rather than being refused for typing.
create or replace function public.set_song_language(
  target_project uuid,
  in_language text
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  song record;
  role_here public.room_role;
  cleaned text;
  parts text[];
begin
  cleaned := nullif(btrim(coalesce(in_language, '')), '');

  if cleaned is not null then
    parts := regexp_match(
      cleaned,
      '^([A-Za-z]{2,3})(?:-([A-Za-z]{4}))?(?:-([A-Za-z]{2}|[0-9]{3}))?$'
    );
    if parts is null then
      raise exception 'That is not a language tag this app can read.'
        using errcode = '22023';
    end if;
    cleaned := lower(parts[1])
      || coalesce('-' || upper(left(parts[2], 1)) || lower(right(parts[2], 3)), '')
      || coalesce('-' || upper(parts[3]), '');
  end if;

  select p.id, p.room_id into song
  from public.projects p
  where p.id = target_project and p.deleted_at is null;

  if song.id is null then
    raise exception 'That song does not exist.' using errcode = '22023';
  end if;

  role_here := private.room_role_for(song.room_id);

  -- `is distinct from` twice, not `not in`. room_role_for is null for
  -- somebody who is not in the room, `null not in ('owner', 'editor')` is
  -- null, and `if null then` does not fire -- so the plain form waves through
  -- the exact person the check exists to stop. See 0068.
  if role_here is distinct from 'owner' and role_here is distinct from 'editor'
  then
    raise exception
      'Only somebody who can edit this song can say what it is sung in.'
      using errcode = '42501';
  end if;

  update public.projects
  set language = cleaned
  where id = target_project and deleted_at is null;
end;
$fn$;

revoke all on function public.set_song_language(uuid, text) from public, anon;
grant execute on function public.set_song_language(uuid, text) to authenticated;
