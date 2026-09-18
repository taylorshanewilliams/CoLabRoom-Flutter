-- This is the 1.
--
-- The analyser decides a key with Krumhansl-Schmuckler, which knows two
-- shapes: major and minor. A Mixolydian rock song reads as the major key a
-- fourth above its home chord, a song that opens on the IV gets called by that
-- chord, and a modal song gets whichever of the two fits least badly. The
-- app then draws everything downstream off that answer -- the scale, the
-- diatonic chords, the capo chart, the spelling of every chord, and now the
-- numbers, which are meaningless if the 1 is in the wrong place (Every
-- Musician, Same Song, 17 September 2026).
--
-- **A shared fact, not a reading.** A person's transpose, their capo and
-- their instrument's part are personal and live on their own device. Where
-- the 1 is is not one of those: it changes what everybody's numbers mean, so
-- it belongs to the song and everybody in the room sees it. Mixing the two up
-- is the trap the genre design names.
--
-- **Null is the honest default.** It means nobody has corrected anything,
-- which is true of every song now and will stay true of most of them. The
-- detected key is still there in the analysis, so clearing this column hands
-- the song back to the analyser rather than emptying it.
--
-- **It survives re-analysis** because it is a column on projects rather than
-- on the reference recording. Analysing again rewrites
-- `project_audio_references.musical_key`; it does not touch this.

alter table public.projects
  add column if not exists key_override text
  -- The same shape the analyser writes: a root, an optional accidental, and
  -- optionally which of the two it is. A bare root is read as major, which is
  -- what a bare letter means on a chart.
  check (key_override is null
         or key_override ~ '^[A-G][#b]?( (major|minor))?$');

comment on column public.projects.key_override is
  'The key the band says this song is in, when the analyser got it wrong. '
  'Null means nobody has said, and the detected key stands. Set through '
  'set_song_key by the room''s owner or an editor; survives re-analysis.';

-- ---------------------------------------------------------------------
-- Saying where the 1 is
-- ---------------------------------------------------------------------

-- Owner or editor, the same people who can say whose song it is (0142).
-- This is a fact about the song rather than a decision about who may hear
-- it, and anybody trusted to write on a song is trusted to say what key it
-- is in -- it is usually the player who noticed, not the person who owns the
-- catalog. Somebody who can only look cannot move everybody else's numbers.
--
-- A null `in_key` clears it, which is how "Use the detected key" is spelled.
-- That is a real answer and not a missing argument, so it is not an error.
create or replace function public.set_song_key(
  target_project uuid,
  in_key text
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
begin
  cleaned := nullif(btrim(coalesce(in_key, '')), '');

  if cleaned is not null and cleaned !~ '^[A-G][#b]?( (major|minor))?$' then
    raise exception 'That is not a key this app can read.'
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
    raise exception 'Only somebody who can edit this song can say its key.'
      using errcode = '42501';
  end if;

  update public.projects
  set key_override = cleaned
  where id = target_project and deleted_at is null;
end;
$fn$;

revoke all on function public.set_song_key(uuid, text) from public, anon;
grant execute on function public.set_song_key(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- Tonight names its chord in the key the band said
-- ---------------------------------------------------------------------

-- Restated from 0121, which is still its latest definition, with one change:
-- the song's key is `coalesce(pr.key_override, par.musical_key)` in the two
-- places it was `par.musical_key`. The Tonight card suggests "a chord of the
-- key this song has never reached for", so on a Mixolydian song the analyser
-- called by the wrong chord it was suggesting a chord out of the key the band
-- actually plays in. Everything else -- the prompt rotation, the one song a
-- day, the returned shape -- is 0121's, so `create or replace` is enough.
create or replace function public.tonight()
returns table (
  prompt_id integer,
  kind text,
  title text,
  body text,
  cta text,
  song_id uuid,
  song_title text,
  song_key text,
  song_chords text[]
)
language plpgsql
security definer set search_path = ''
as $$
declare
  me uuid := auth.uid();
  chosen integer;
  song record;
begin
  if me is null then
    return;
  end if;

  select ts.prompt_id into chosen
  from public.tonight_seen ts
  where ts.user_id = me and ts.day = current_date;

  if chosen is null then
    select p.id into chosen
    from public.tonight_prompts p
    where p.id not in (select ts.prompt_id from public.tonight_seen ts where ts.user_id = me)
    order by md5(p.id::text || me::text || current_date::text)
    limit 1;

    if chosen is null then
      -- Every prompt seen: start again from the one seen longest ago.
      select ts.prompt_id into chosen
      from public.tonight_seen ts
      where ts.user_id = me
      order by ts.day asc
      limit 1;
    end if;

    if chosen is not null then
      insert into public.tonight_seen (user_id, day, prompt_id)
      values (me, current_date, chosen)
      on conflict (user_id, day) do nothing;
    end if;
  end if;

  select pr.id, pr.title,
         coalesce(pr.key_override, par.musical_key) as musical_key,
         (select array_agg(distinct c.chord) from public.chord_cues c
          where c.project_id = pr.id and c.chord not in ('N', 'X')) as chords
  into song
  from public.projects pr
  join public.room_members rm on rm.room_id = pr.room_id and rm.user_id = me
  join public.project_audio_references par on par.project_id = pr.id
  where coalesce(pr.key_override, par.musical_key) is not null
    and exists (select 1 from public.chord_cues c where c.project_id = pr.id)
  order by md5(pr.id::text || current_date::text)
  limit 1;

  return query
  select p.id, p.kind, p.title, p.body, p.cta,
         song.id, song.title, song.musical_key, song.chords
  from public.tonight_prompts p
  where p.id = chosen
  union all
  select null, null, null, null, null, song.id, song.title, song.musical_key, song.chords
  where chosen is null and song.id is not null;
end;
$$;

revoke all on function public.tonight() from public, anon;
grant execute on function public.tonight() to authenticated;
