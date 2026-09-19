-- Count your own cycle.
--
-- Bars in this app are the analysis downbeats (#362), numbered from wherever
-- the band says bar 1 is (0161). That is a bar of four, or of three, or of
-- whatever the beat tracker heard -- and for a great deal of the music people
-- actually play it is the wrong unit entirely. A seven counted 3+2+2, a
-- sixteen, a twelve with its own inner shape: none of them is a run of
-- four-beat bars, and asking somebody to find "bars nine to twelve" in a
-- count they do not use is asking them to do arithmetic on a music stand
-- (Every Musician, Same Song, 17 September 2026, section 4).
--
-- **No library of names.** Decision 20. The obvious build was a table of
-- talas, compases, iqa'at and usul shipped with the app, and the obvious
-- build would have put somebody's transcription of somebody else's tradition
-- in front of a player with nobody here able to check a line of it. What a
-- musician needs is smaller and truer, and they already know it: a count and
-- its stresses. "7: 3+2+2" is a whole cycle and claims to be nothing else.
--
-- **A shared fact, not a reading.** The fourth one, after the band's key
-- (0144), where bar 1 is (0161) and what the song is sung in (0163), and
-- shared for the same reason as all three: a person's numbers, capo, horn
-- part and transpose live on their own phone, but what the room counts
-- changes what everybody's numbers mean. "From cycle nine" has to be the
-- same nine on every phone in the room.
--
-- **Null is the honest default**, as it was for all of those: nobody has
-- counted a cycle, which is true of every song now and will stay true of
-- most, and it reads as the analysed bars -- exactly what the app did before
-- these columns existed. Clearing them is how "Use the detected bars" is
-- spelled here too.
--
-- **It survives re-analysis** because it lives on the song rather than on the
-- reference recording. Analysing again rewrites `beats_ms` and
-- `downbeats_ms`; it does not touch these. The app lays the count over
-- whatever beat grid it then has.

alter table public.projects
  add column if not exists cycle_beats integer
  -- How many beats go round before the count starts again. Two is the
  -- shortest thing that goes round at all; sixty-four is past any cycle a
  -- person counts and well inside what a row of taps can be read at. Null is
  -- nobody having counted one.
  check (cycle_beats is null or (cycle_beats >= 2 and cycle_beats <= 64));

alter table public.projects
  add column if not exists cycle_accents integer[]
  -- Which beats after the first are played heavy, ascending. The first beat
  -- is never in here: it is where the count comes back to, it is always the
  -- heaviest, and there is nothing to say about it.
  --
  -- The values themselves are ranged by set_song_cycle below and tidied
  -- again when the app reads them (SongCycle.of), not by a check constraint:
  -- Postgres will not take a subquery in a check, so unnesting the array to
  -- test every element is not available here. What a check can say without
  -- one is said: there is no stress list without a count to put it in, and
  -- never more stresses than the cycle has beats after its first.
  check (
    cycle_accents is null
    or (
      cycle_beats is not null
      and coalesce(array_length(cycle_accents, 1), 0) < cycle_beats
    )
  );

comment on column public.projects.cycle_beats is
  'How many beats the cycle this song goes round in has. Null means nobody '
  'has counted one and the analysed bars stand. Set through set_song_cycle '
  'by the room''s owner or an editor; survives re-analysis.';

comment on column public.projects.cycle_accents is
  'Which beats of the cycle after the first are played heavy, ascending. '
  'Null or empty is a cycle nobody has said anything inside.';

-- ---------------------------------------------------------------------
-- Counting the cycle
-- ---------------------------------------------------------------------

-- Owner or editor: the same two who may say what key the song is in (0144),
-- whose song it is (0142) and where bar 1 is (0161). Anybody trusted to write
-- on a song is trusted to say what it is counted in -- it is usually the
-- person playing the thing who knows, not the person who owns the catalog.
-- Somebody who can only look cannot move everybody else's numbers.
--
-- A null `in_beats` clears it, which is how "Use the detected bars" is spelled
-- here. That is a real answer and not a missing argument, so it is not an
-- error, and it takes the stresses with it: a stress list with no count to sit
-- in is not a cycle.
--
-- The stresses are tidied rather than refused. A number outside the count, a
-- repeat, a null in the array, the first beat named explicitly: each of those
-- is somebody tapping, or a build that counted differently, and none of them
-- is worth a sentence on a music stand. What comes out is ascending, without
-- repeats, with no nulls, every value between 2 and the count.
create or replace function public.set_song_cycle(
  target_project uuid,
  in_beats integer,
  in_accents integer[] default null
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  song record;
  role_here public.room_role;
  clean integer[];
begin
  if in_beats is not null and (in_beats < 2 or in_beats > 64) then
    raise exception 'A cycle goes round in between 2 and 64 beats.'
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
    raise exception 'Only somebody who can edit this song can count its cycle.'
      using errcode = '42501';
  end if;

  if in_beats is null then
    update public.projects
    set cycle_beats = null, cycle_accents = null
    where id = target_project and deleted_at is null;
    return;
  end if;

  -- A null element of the array fails `a >= 2`, which is null rather than
  -- true, so the where clause drops it along with everything out of range.
  select coalesce(array_agg(distinct a order by a), '{}'::integer[])
    into clean
  from unnest(coalesce(in_accents, '{}'::integer[])) as a
  where a >= 2 and a <= in_beats;

  update public.projects
  set cycle_beats = in_beats, cycle_accents = clean
  where id = target_project and deleted_at is null;
end;
$fn$;

revoke all on function public.set_song_cycle(uuid, integer, integer[])
  from public, anon;
grant execute on function public.set_song_cycle(uuid, integer, integer[])
  to authenticated;
