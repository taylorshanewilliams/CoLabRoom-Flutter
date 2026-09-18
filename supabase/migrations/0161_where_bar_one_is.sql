-- Say where bar 1 is.
--
-- Bar numbers in this app come from the analysis downbeats, and bar 1 is the
-- first one of them (#362). That is right for a song that starts on its own
-- downbeat and wrong for every other kind: a song with a pickup phrase, or a
-- count-in left on the front of the recording, is then one bar off the
-- printed music the teacher is holding, and "bars nine to twelve" means two
-- different passages in the same room. The pickup itself could not be looped
-- at all, because everything ahead of the first downbeat had no number and
-- so could not be asked for (Every Musician, Same Song, 17 September 2026;
-- Taylor's default, decision 4 after wave 1).
--
-- **A shared fact, not a reading.** The same distinction 0144 drew for the
-- key. A person's transpose, their capo, their horn part and whether they
-- read numbers or letters are personal and live on their own device. Where
-- bar 1 is is not one of those: it changes what everybody's bar numbers
-- mean, so it belongs to the song and everybody in the room counts from it.
--
-- **Null is the honest default.** It means nobody has corrected anything,
-- which is true of every song now and will stay true of most of them, and it
-- reads as "bar 1 is the first downbeat" -- exactly what the app did before
-- this column existed. Clearing it is how "Use the detected bars" is spelled.
--
-- **It survives re-analysis** because it is a column on projects rather than
-- on the reference recording. Analysing again rewrites
-- `project_audio_references.downbeats_ms`; it does not touch this. The
-- number is an ordinal into that list, so a re-analysis that finds the same
-- grid keeps the same bar 1, and one that finds a different grid is a
-- different song's worth of downbeats either way.

alter table public.projects
  add column if not exists bar_one_downbeat integer
  -- Which downbeat is bar 1, counting from one. The app clamps it into the
  -- grid it actually has, so a number past the end of a shorter re-analysis
  -- is a stale answer rather than a broken song; a number below one is not
  -- an answer at all.
  check (bar_one_downbeat is null or bar_one_downbeat >= 1);

comment on column public.projects.bar_one_downbeat is
  'Which downbeat of the analysis is bar 1, counting from one. Null means '
  'nobody has said and the first downbeat stands. Set through set_bar_one '
  'by the room''s owner or an editor; survives re-analysis.';

-- ---------------------------------------------------------------------
-- Saying where bar 1 is
-- ---------------------------------------------------------------------

-- Owner or editor, the same people who can say what key the song is in
-- (0144) and whose song it is (0142). Anybody trusted to write on a song is
-- trusted to say where its bars start -- it is usually the player holding
-- the printed part who noticed, not the person who owns the catalog.
-- Somebody who can only look cannot move everybody else's bar numbers.
--
-- A null `in_downbeat` clears it, which is how "Use the detected bars" is
-- spelled. That is a real answer and not a missing argument, so it is not an
-- error.
create or replace function public.set_bar_one(
  target_project uuid,
  in_downbeat integer
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  song record;
  role_here public.room_role;
begin
  if in_downbeat is not null and in_downbeat < 1 then
    raise exception 'Bar 1 has to be one of the downbeats.'
      using errcode = '22023';
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
    raise exception 'Only somebody who can edit this song can say where bar 1 is.'
      using errcode = '42501';
  end if;

  update public.projects
  set bar_one_downbeat = in_downbeat
  where id = target_project and deleted_at is null;
end;
$fn$;

revoke all on function public.set_bar_one(uuid, integer) from public, anon;
grant execute on function public.set_bar_one(uuid, integer) to authenticated;
