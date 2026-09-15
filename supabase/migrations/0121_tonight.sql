-- Tonight.
--
-- Taylor, 15 Sep 2026: a welcome that is "consistently new, and fresh, so
-- every time you come back to the app, you see something new". Not streaks
-- or badges -- this app has ruled those out -- but content, and the
-- person's own work. One card a day on Home, drawn from three places: a
-- release they have not seen, a chord move on a song of theirs, or a
-- prompt from this table. The table is what makes it true on day one with
-- four users and still true at a million: ninety prompts, nobody's, and
-- the same rows drawn on the website, so the front door is alive too.
--
-- Three pieces:
--
--   tonight_prompts   a first line to record, or a practice challenge
--   tonight_seen      which prompt a person was given on which day
--   releases          what changed, written at merge time from the title
--
-- and three functions: tonight() for a signed-in person (their prompt for
-- today, kept for the day, and one song of theirs with a key and chords),
-- tonight_for_everyone() for the website, and release_notes().

-- ---------------------------------------------------------------------
-- The prompts.
-- ---------------------------------------------------------------------

create table public.tonight_prompts (
  id integer generated always as identity primary key,
  kind text not null check (kind in ('first_line', 'challenge')),
  title text not null check (char_length(title) between 1 and 80),
  body text not null check (char_length(body) between 1 and 240),
  cta text not null check (char_length(cta) between 1 and 24)
);

alter table public.tonight_prompts enable row level security;

create policy tonight_prompts_read on public.tonight_prompts
for select to authenticated using (true);

-- Which prompt a person was handed on which day. One per day, so the card
-- does not change under them between breakfast and lunch, and never the
-- same one twice until every other one has been.
create table public.tonight_seen (
  user_id uuid not null references public.profiles(id) on delete cascade,
  day date not null,
  prompt_id integer not null references public.tonight_prompts(id) on delete cascade,
  primary key (user_id, day)
);

alter table public.tonight_seen enable row level security;

create policy tonight_seen_own on public.tonight_seen
for select to authenticated using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------
-- What changed.
-- ---------------------------------------------------------------------

-- Written by a workflow at merge time, with the service key. Every pull
-- request title in this repository is already a sentence a person can
-- read, so the app can announce itself without anybody writing a changelog.
create table public.releases (
  sha text primary key check (sha ~ '^[0-9a-f]{7,40}$'),
  title text not null check (char_length(title) between 1 and 120),
  body text not null default '' check (char_length(body) <= 400),
  merged_at timestamptz not null default now()
);

alter table public.releases enable row level security;

create policy releases_read on public.releases
for select to authenticated using (true);

create or replace function public.release_notes(within_days integer default 14)
returns table (sha text, title text, body text, merged_at timestamptz)
language sql
security invoker
stable
as $$
  select r.sha, r.title, r.body, r.merged_at
  from public.releases r
  where r.merged_at > now() - make_interval(days => greatest(within_days, 1))
  order by r.merged_at desc
  limit 5;
$$;

revoke all on function public.release_notes(integer) from public, anon;
grant execute on function public.release_notes(integer) to authenticated;

-- ---------------------------------------------------------------------
-- Tonight, for one person.
-- ---------------------------------------------------------------------

-- The prompt for today: the one already handed out today, or else one
-- this person has never been given, chosen by a hash of who and when so
-- two people do not get the same one on the same day, or the least recent
-- once every prompt has been seen. Plus one of their songs with a key and
-- chords, chosen by the same hash, for the chord move.
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

  select pr.id, pr.title, par.musical_key,
         (select array_agg(distinct c.chord) from public.chord_cues c
          where c.project_id = pr.id and c.chord not in ('N', 'X')) as chords
  into song
  from public.projects pr
  join public.room_members rm on rm.room_id = pr.room_id and rm.user_id = me
  join public.project_audio_references par on par.project_id = pr.id
  where par.musical_key is not null
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

-- ---------------------------------------------------------------------
-- Tonight, for the website.
-- ---------------------------------------------------------------------

-- The same table, one row for everybody, by the day. Service role only:
-- the website reaches it through the public tool's function, so the pages
-- keep shipping no credentials.
create or replace function public.tonight_for_everyone()
returns table (kind text, title text, body text, cta text)
language sql
security definer set search_path = ''
stable
as $$
  select p.kind, p.title, p.body, p.cta
  from public.tonight_prompts p
  order by md5(p.id::text || current_date::text)
  limit 1;
$$;

revoke all on function public.tonight_for_everyone() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Ninety days, so there is no day it is empty.
-- ---------------------------------------------------------------------

insert into public.tonight_prompts (kind, title, body, cta) values
  ('first_line', 'Write the first line', 'The thing you should have said in the car. One breath, into the phone.', 'Record'),
  ('first_line', 'Write the first line', 'A room you have not been back to since. Start with what it smelled like.', 'Record'),
  ('first_line', 'Write the first line', 'The last text you did not send. Sing it instead.', 'Record'),
  ('first_line', 'Write the first line', 'A street name that sounds like a person. Give them one thing they want.', 'Record'),
  ('first_line', 'Write the first line', 'What the kitchen looks like at 4 a.m. Nothing about how you feel.', 'Record'),
  ('first_line', 'Write the first line', 'Somebody who is always late. Their side of it.', 'Record'),
  ('first_line', 'Write the first line', 'A weather forecast for a person.', 'Record'),
  ('first_line', 'Write the first line', 'The first line is a question you already know the answer to.', 'Record'),
  ('first_line', 'Write the first line', 'A promise made at a petrol station.', 'Record'),
  ('first_line', 'Write the first line', 'The song your dad played too loud. Not the song; the loudness.', 'Record'),
  ('first_line', 'Write the first line', 'Describe the view from a window you cannot go back to.', 'Record'),
  ('first_line', 'Write the first line', 'Start with a number. A price, a year, a room.', 'Record'),
  ('first_line', 'Write the first line', 'The last thing your hands did before you sat down.', 'Record'),
  ('first_line', 'Write the first line', 'An apology that is mostly an excuse.', 'Record'),
  ('first_line', 'Write the first line', 'A bar you were too young for. What was on the walls.', 'Record'),
  ('first_line', 'Write the first line', 'Two people waiting for the same bus, going different ways.', 'Record'),
  ('first_line', 'Write the first line', 'Something you keep in the glovebox and why.', 'Record'),
  ('first_line', 'Write the first line', 'The name of a dog that is gone.', 'Record'),
  ('first_line', 'Write the first line', 'The chorus is one word. Find the word first.', 'Record'),
  ('first_line', 'Write the first line', 'A phone that rings in an empty house.', 'Record'),
  ('first_line', 'Write the first line', 'Write it to one person. Use their name in the first line, then cut it.', 'Record'),
  ('first_line', 'Write the first line', 'The town from the highway, at night, from the passenger seat.', 'Record'),
  ('first_line', 'Write the first line', 'Something you were wrong about for years.', 'Record'),
  ('first_line', 'Write the first line', 'A receipt you found in a coat. What it was for.', 'Record'),
  ('first_line', 'Write the first line', 'Start in the middle of an argument. Nobody explains.', 'Record'),
  ('first_line', 'Write the first line', 'The sound the house makes when everybody has left.', 'Record'),
  ('first_line', 'Write the first line', 'A lie you told to be kind.', 'Record'),
  ('first_line', 'Write the first line', 'The last day of a job. The drive home.', 'Record'),
  ('first_line', 'Write the first line', 'Someone teaching you to drive. Their hands, not yours.', 'Record'),
  ('first_line', 'Write the first line', 'A letter never posted, read out loud by the wrong person.', 'Record'),
  ('first_line', 'Write the first line', 'The song is a list. Three things, then the thing that is missing.', 'Record'),
  ('first_line', 'Write the first line', 'What you would take from the house if you had one minute.', 'Record'),
  ('first_line', 'Write the first line', 'A river town in a drought.', 'Record'),
  ('first_line', 'Write the first line', 'The first line is the last line of a story you know. Start there.', 'Record'),
  ('first_line', 'Write the first line', 'Someone counting money at a table. What they are counting toward.', 'Record'),
  ('first_line', 'Write the first line', 'A radio station that only comes in after dark.', 'Record'),
  ('first_line', 'Write the first line', 'The one photograph on the fridge.', 'Record'),
  ('first_line', 'Write the first line', 'Hold one note and say the place you were happiest. Do not rhyme.', 'Record'),
  ('first_line', 'Write the first line', 'A stranger on a porch, waving as if they know you.', 'Record'),
  ('first_line', 'Write the first line', 'The last snow of the year, and who you were with.', 'Record'),
  ('first_line', 'Write the first line', 'Something borrowed and never returned. Say what it was.', 'Record'),
  ('first_line', 'Write the first line', 'A birthday nobody remembered. Make it funny.', 'Record'),
  ('first_line', 'Write the first line', 'The first line is an address.', 'Record'),
  ('first_line', 'Write the first line', 'A night shift. The hour when the clock stops moving.', 'Record'),
  ('first_line', 'Write the first line', 'What you say to the dog when nobody else is home.', 'Record'),
  ('first_line', 'Write the first line', 'Two chords and the name of a boat.', 'Record'),
  ('first_line', 'Write the first line', 'A wedding you were not sure about, from the back row.', 'Record'),
  ('first_line', 'Write the first line', 'Write the bridge first. A key change, or a change of mind.', 'Record'),
  ('first_line', 'Write the first line', 'The thing in the attic. Everybody knows what it is.', 'Record'),
  ('first_line', 'Write the first line', 'A goodbye at a gate, in the present tense.', 'Record'),
  ('first_line', 'Write the first line', 'A town called after somebody nobody remembers.', 'Record'),
  ('first_line', 'Write the first line', 'Say the thing plainly, then say it again slower. That is the hook.', 'Record'),
  ('first_line', 'Write the first line', 'A car that would not start on the one morning it mattered.', 'Record'),
  ('first_line', 'Write the first line', 'The smell of a gym. A person you met there.', 'Record'),
  ('first_line', 'Write the first line', 'The day the river came up to the road.', 'Record'),
  ('first_line', 'Write the first line', 'A sentence somebody said that you have carried for years.', 'Record'),
  ('first_line', 'Write the first line', 'A late train, and the person who was not on it.', 'Record'),
  ('first_line', 'Write the first line', 'An old man singing along wrong. Keep his words.', 'Record'),
  ('first_line', 'Write the first line', 'The last light in a stadium. Who turns it off.', 'Record'),
  ('first_line', 'Write the first line', 'The first line is the truth. The second line takes it back.', 'Record'),
  ('challenge', 'Eight bars, one take', 'Loop a section at three-quarter speed, play it four times, keep the fourth. Ninety seconds.', 'Open a song'),
  ('challenge', 'Mute your part', 'Play a song sheet with your own part muted and play it live over the rest. Once through.', 'Open a song'),
  ('challenge', 'The bridge, slowly', 'Take the hardest eight bars you have and loop them at half speed until they are boring.', 'Open a song'),
  ('challenge', 'Sing the chords', 'Pick a song and sing the root of every chord as it goes by. Nothing else.', 'Open a song'),
  ('challenge', 'One chord, one minute', 'A tuner and a metronome at sixty. Hold one clean chord, change on the bar, for a minute.', 'Open a song'),
  ('challenge', 'Capo up two', 'Play a song you know two frets higher than usual. Notice what the voice does.', 'Open a song'),
  ('challenge', 'A take with no second try', 'Record one pass of anything. Do not listen back tonight.', 'Record'),
  ('challenge', 'The verse as a whisper', 'Record a verse at a quarter of the volume. Keep the words, lose the push.', 'Record'),
  ('challenge', 'Tempo down ten', 'Play a fast song ten beats slower than the sheet says. Find the note you always rush.', 'Open a song'),
  ('challenge', 'Just the chorus', 'Loop a chorus and play it until you can do it with your eyes shut. Then shut them.', 'Open a song'),
  ('challenge', 'Swap the order', 'Play a song with the second verse first. Find out whether it still works.', 'Open a song'),
  ('challenge', 'The turnaround', 'Loop the last two bars before a chorus. That is where the song lives. Ten times.', 'Open a song'),
  ('challenge', 'Half time', 'Play the whole thing in half time. Hear where the space was.', 'Open a song'),
  ('challenge', 'Hum the lead', 'Where a lead would go, hum one. Record it over the sheet. It counts.', 'Record'),
  ('challenge', 'Tune first', 'Tune every string with the tuner, then play the quietest thing you know.', 'Open a song'),
  ('challenge', 'The count-in', 'Set the metronome to the song and count four bars out loud before you play a note.', 'Open a song'),
  ('challenge', 'The other person''s part', 'Play a part somebody else recorded on your song. Learn what they heard.', 'Open a song'),
  ('challenge', 'Two minutes, one idea', 'Loop four bars and change one note each time around. Stop at two minutes.', 'Open a song'),
  ('challenge', 'Sing it in the key', 'Check the song sheet for the key, find the lowest note you can sing in it, and start there.', 'Open a song'),
  ('challenge', 'Play it for the room', 'Play a whole song through without stopping to fix anything. Fixing is for tomorrow.', 'Open a song'),
  ('challenge', 'The strum you never use', 'Pick a song and play every chord with a strum you never use. Keep one bar of it.', 'Open a song'),
  ('challenge', 'Fret hand only', 'Mute the strings and play the chord changes of a song in time, silent. Feel the changes.', 'Open a song'),
  ('challenge', 'The ending', 'Loop the last eight bars. Decide how the song actually ends.', 'Open a song'),
  ('challenge', 'Left hand, right hand', 'Play the bass notes of a song alone, then only the top strings. Then together.', 'Open a song'),
  ('challenge', 'A verse in the dark', 'Lights off. Play a verse from memory. Record it if it survives.', 'Record'),
  ('challenge', 'Six words', 'Write a chorus of six words. Sing it over a chord you already have. Record thirty seconds.', 'Record'),
  ('challenge', 'The metronome lies', 'Set the click ten beats faster than comfortable and stay with it for one verse.', 'Open a song'),
  ('challenge', 'One more time', 'The take you like least: play its part once more, slower, and listen to it kindly.', 'Open a song'),
  ('challenge', 'Match the range', 'Find the highest note on your song sheet''s range and sing up to it three times. No further.', 'Open a song'),
  ('challenge', 'Tonight, nothing', 'Do not play. Listen to one song of yours the whole way through and write one line about it.', 'Open a song');
