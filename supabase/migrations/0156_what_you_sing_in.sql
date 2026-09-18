-- Say what you sing in.
--
-- Every Musician, Same Song, 17 September 2026, from the world-traditions
-- research: a singer in Portuguese and a singer in Hindi were the same
-- person to this app, and so were a Carnatic violinist and a bluegrass
-- fiddler who had not picked a genre chip. The language somebody sings in
-- and the tradition they work in are two of the first things one musician
-- asks another, and the app had nowhere to put either.
--
-- **Declared, never inferred.** Not from a recording, a name or a city.
-- Guessing somebody's language or tradition is profiling, and the plan
-- rules it out by name. So this is a field a person fills in, in their own
-- words, and an empty one means only that they have not said.
--
-- **A closeness reason, never a filter and never an order.** It is kept the
-- way `sounds_like` is (0076): self-declared, five at most, folded to one
-- spelling. A word you and somebody both wrote down is one more sentence
-- the feed can say on a card ("Also sings in Portuguese"), and that is all
-- it is. It does not move a song up or down. A shared sound can do that
-- because no one sound is most people's; a language is different, because
-- one of them is most people's, and a tier built on it would put everybody
-- who typed "english" above a neighbour who typed nothing. So nobody is
-- hidden by it, nobody is ranked by it, and somebody who declares nothing
-- is exactly where they were, in every reader's feed.
--
-- One list rather than two. Languages and traditions sit together because
-- which is which is the person's to say, and one cap of five keeps each
-- word meaning something.
--
-- Asks carry it too, as one free line ("Sa = C#, Rupak, Hindi"), so
-- somebody answering knows what they are joining before they say yes.

alter table public.profiles
  add column if not exists sings_in text[] not null default '{}';

comment on column public.profiles.sings_in is
  'The languages this person sings in and the traditions they work in, in '
  'their own words. Declared, never inferred. A shared word is a sentence '
  'open_mic_feed can say on a card; it is never a filter and never an order.';

-- ---------------------------------------------------------------------
-- One spelling for one word
-- ---------------------------------------------------------------------
--
-- The idea of 0135, for the same reason: words are matched whole, so
-- "Português" on one page and "Portuguese" on another would never count as
-- the same language. A short table of spellings and of the names a language
-- has for itself, not a vocabulary and not varieties: anything not in it is
-- kept as typed, lower-cased and single-spaced, and "brazilian portuguese"
-- stays what somebody wrote. The same table is `_sameWord` in
-- lib/domain/sung_in.dart.

create or replace function private.sung_in_word(raw text)
returns text
language sql
immutable
as $fn$
  select case w
    when 'português' then 'portuguese'
    when 'portugues' then 'portuguese'
    when 'español' then 'spanish'
    when 'espanol' then 'spanish'
    when 'castellano' then 'spanish'
    when 'français' then 'french'
    when 'francais' then 'french'
    when 'deutsch' then 'german'
    when 'italiano' then 'italian'
    when 'nederlands' then 'dutch'
    when 'gaeilge' then 'irish'
    when 'cymraeg' then 'welsh'
    when 'kiswahili' then 'swahili'
    when 'isizulu' then 'zulu'
    when 'isixhosa' then 'xhosa'
    when 'mandarin chinese' then 'mandarin'
    when 'putonghua' then 'mandarin'
    when 'hindustani classical' then 'hindustani'
    when 'north indian classical' then 'hindustani'
    when 'carnatic classical' then 'carnatic'
    when 'karnatic' then 'carnatic'
    when 'karnatak' then 'carnatic'
    when 'south indian classical' then 'carnatic'
    else w
  end
  -- Collapsed first and trimmed after. `trim` takes off spaces and nothing
  -- else, so a word pasted with a tab or a line end on it would have been
  -- kept as " portuguese" and never matched anybody's. Dart's `trim()` in
  -- lib/domain/sung_in.dart takes off every kind of white space, and the
  -- two have to agree for one word to be one word.
  from (
    select btrim(regexp_replace(lower(coalesce(raw, '')), '\s+', ' ', 'g')) as w
  ) typed;
$fn$;

-- As tidy_sounds_like (0135): folded, deduplicated, kept in the order
-- somebody chose them, five at most, nothing over forty characters. The
-- length is read off the folded word, so something that was only white
-- space is dropped rather than kept as an empty word.
create or replace function private.tidy_sings_in(raw text[])
returns text[]
language sql
immutable
as $fn$
  select coalesce(
    (select array_agg(word order by ord)
     from (
       select word, min(ord) as ord
       from (
         select private.sung_in_word(t) as word, ord
         from unnest(coalesce(raw, '{}'::text[])) with ordinality as u(t, ord)
       ) cleaned
       where char_length(word) between 1 and 40
       group by word
       order by min(ord)
       limit 5
     ) kept),
    '{}'::text[]
  );
$fn$;

-- Executable by authenticated, on purpose. set_open_mic_presence below is
-- security invoker, so these run as the person saving their settings, and
-- a helper revoked from them fails the whole save with "permission denied
-- for function". Nothing here reads a table, so there is nothing to guard.
revoke all on function private.sung_in_word(text) from public, anon;
revoke all on function private.tidy_sings_in(text[]) from public, anon;
grant execute on function private.sung_in_word(text) to authenticated;
grant execute on function private.tidy_sings_in(text[]) to authenticated;

-- The same sentence, for the helper 0135 added. It revoked one_sound_word
-- from authenticated, and tidy_sounds_like calls it from the same security
-- invoker function, so a save that carried a sound was refused. Every smoke
-- call of that function ran as the superuser, which is why nothing caught
-- it. The Open Mic settings sheet sends sounds and languages in one call,
-- so what somebody sings in could not be saved without this either. The
-- block for this migration in supabase/smoke/10_scenario.sql saves both as
-- authenticated.
grant execute on function private.one_sound_word(text) to authenticated;

-- ---------------------------------------------------------------------
-- Saying it
-- ---------------------------------------------------------------------
--
-- With the rest of what Open Mic knows about somebody, in the call the
-- settings sheet already makes. Restated from 0076, which is still its
-- latest definition; the only change is the sixth parameter and the column
-- it writes. Null leaves what is stored alone, as it does for the others,
-- so the first-run tour (which does not ask this) cannot clear it.

create or replace function public.set_open_mic_presence(
  in_discoverable boolean,
  in_city text default null,
  in_location_visibility text default null,
  in_plays text[] default null,
  in_sounds_like text[] default null,
  in_sings_in text[] default null
)
returns void
language plpgsql
security invoker
set search_path = public
as $fn$
begin
  if in_location_visibility is not null
     and in_location_visibility not in ('nobody', 'collaborators', 'public') then
    raise exception 'Location can be shown to nobody, collaborators or everyone.'
      using errcode = '22023';
  end if;

  update public.profiles
  set discoverable = in_discoverable,
      -- Null means "leave it alone"; an empty string means "take it off my
      -- profile". A setting you can turn on and not off is not a setting.
      city = case
        when in_city is null then city
        else nullif(trim(in_city), '')
      end,
      location_visibility =
        coalesce(in_location_visibility, location_visibility),
      plays = coalesce(in_plays, plays),
      sounds_like = case
        when in_sounds_like is null then sounds_like
        else private.tidy_sounds_like(in_sounds_like)
      end,
      sings_in = case
        when in_sings_in is null then sings_in
        else private.tidy_sings_in(in_sings_in)
      end
  where id = auth.uid();
end;
$fn$;

revoke all on function public.set_open_mic_presence(boolean, text, text, text[], text[], text[])
  from public, anon;
grant execute on function public.set_open_mic_presence(boolean, text, text, text[], text[], text[])
  to authenticated;

-- The five-argument form would otherwise sit alongside the new one and take
-- every call that does not name the sixth parameter, as 0076 found with the
-- four-argument one. An app that has not updated names five and lands here
-- with the sixth defaulted, which leaves sings_in alone.
drop function if exists public.set_open_mic_presence(boolean, text, text, text[], text[]);

-- ---------------------------------------------------------------------
-- Showing it
-- ---------------------------------------------------------------------
--
-- On the page, to the same people who can see the page. Restated from 0137,
-- which is still its latest definition: everything except the sings_in
-- column is exactly as it was. Dropped first because `create or replace`
-- cannot change the shape of a `returns table`.

drop function if exists public.musician_profile(uuid);

create function public.musician_profile(target uuid)
returns table (
  id uuid,
  display_name text,
  avatar_path text,
  city text,
  plays text[],
  sounds_like text[],
  sings_in text[],
  bio text,
  parts_recorded jsonb,
  songs_played_on bigint,
  people_worked_with bigint,
  discoverable boolean,
  location_visibility text,
  vocal_low_midi integer,
  vocal_high_midi integer,
  vocal_range_songs integer
)
language sql
stable
security definer
set search_path = public
as $$
  select
    p.id,
    p.display_name,
    p.avatar_path,
    case
      when p.id = (select auth.uid()) then p.city
      when p.location_visibility = 'public' then p.city
      else null
    end,
    p.plays,
    p.sounds_like,
    p.sings_in,
    p.bio,
    public.parts_recorded_by(p.id),
    (select count(distinct l.project_id) from public.song_layers l
      where l.recorded_by = p.id and l.shared_at is not null),
    (select count(distinct other.recorded_by)
       from public.song_layers mine
       join public.song_layers other on other.project_id = mine.project_id
      where mine.recorded_by = p.id
        and mine.shared_at is not null
        and other.shared_at is not null
        and other.recorded_by <> p.id),
    case when p.id = (select auth.uid()) then p.discoverable else null end,
    case when p.id = (select auth.uid()) then p.location_visibility else null end,
    case when sings.yes then sung.low end,
    case when sings.yes then sung.high end,
    case when sings.yes then sung.songs else 0 end
  from public.profiles p
  cross join lateral (
    select coalesce(p.plays, array[]::text[]) && array['vocal', 'harmony', 'rap']::text[] as yes
  ) sings
  cross join lateral (
    select
      min(r.melody_low_midi)::integer as low,
      max(r.melody_high_midi)::integer as high,
      count(*)::integer as songs
    from public.project_audio_references r
    join public.projects pj on pj.id = r.project_id and pj.deleted_at is null
    where r.uploaded_by = p.id
      and r.melody_low_midi is not null
      and r.melody_high_midi is not null
  ) sung
  where p.id = target
    -- A blocked profile has no page, the same way a profile that never opted
    -- in has no page. Returning nothing is the honest answer and it is also
    -- the one that says least.
    and not private.blocked_between((select auth.uid()), p.id)
    and (
      p.id = (select auth.uid())
      or p.discoverable
      or exists (
        select 1 from public.room_members rm
        where rm.user_id = p.id and private.is_room_member(rm.room_id)
      )
      -- 0137: one of your people, or somebody asking to be, either way round.
      or exists (
        select 1 from public.connections c
        where (c.requester_id = (select auth.uid()) and c.addressee_id = p.id)
           or (c.requester_id = p.id and c.addressee_id = (select auth.uid()))
      )
    );
$$;

revoke all on function public.musician_profile(uuid) from public, anon;
grant execute on function public.musician_profile(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- What an ask is in
-- ---------------------------------------------------------------------
--
-- "Sa = C#, Rupak, Hindi": the tonic, the cycle, the language, or whatever
-- of those somebody joining needs. One short free line in the asker's own
-- words. The app never fills it in, not from the analysis and not from
-- either profile, and empty is the normal case. Its own column rather than
-- a convention inside `note`, so a card can show it as a fact about the
-- song next to the key and the tempo, not as something said in passing.

alter table public.project_asks
  add column if not exists sung_in text not null default '';

-- The field on the ask sheets stops at eighty characters as a person counts
-- them. Postgres counts code points, and in Devanagari, Tamil or Bengali
-- one written character is often two or three of those, so a check of
-- eighty here would have refused a Hindi line the field had just accepted,
-- and taken the whole ask down with it. The check is three times the
-- field, so the same visible length fits in every script, and both ways in
-- cut to it rather than fail: `sungInLine` in lib/domain/sung_in.dart for
-- the room's plain insert, and `left` in ask_musician below.
alter table public.project_asks
  drop constraint if exists project_asks_sung_in_check;
alter table public.project_asks
  add constraint project_asks_sung_in_check check (char_length(sung_in) <= 240);

comment on column public.project_asks.sung_in is
  'What somebody answering would be joining, in the asker''s own words: '
  '"Sa = C#, Rupak, Hindi". Free text, never inferred, usually empty.';

-- The room's ask is a plain insert (0049's policy), so the column is all it
-- needs. An ask sent to one person goes through ask_musician, which has to
-- be told. Dropped first for the reason 0145 gives: a sixth parameter with
-- a default joins the five-parameter function rather than replacing it, and
-- a five-argument call would then match both.
--
-- Restated from 0145, which is still its latest definition. The parameter,
-- and the column in the insert, are the only changes.
drop function if exists public.ask_musician(uuid, uuid, text, text, text);

create function public.ask_musician(
  target_project uuid,
  target_person uuid,
  in_part text default null,
  in_note text default '',
  in_terms text default 'play',
  in_sung_in text default ''
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  song record;
  asker_name text;
  cleaned_part text;
  cleaned_terms text;
  new_ask uuid;
begin
  if target_person = auth.uid() then
    raise exception 'You cannot ask yourself.' using errcode = '22023';
  end if;

  if private.blocked_between(auth.uid(), target_person) then
    raise exception 'That musician is not available.' using errcode = '22023';
  end if;

  select p.id, p.title, p.room_id into song
  from public.projects p
  where p.id = target_project;

  if song.id is null then
    raise exception 'That song does not exist.' using errcode = '22023';
  end if;

  if not (private.is_room_member(song.room_id)
          or private.is_project_member(song.id)) then
    raise exception 'That is not your song to offer.' using errcode = '42501';
  end if;

  cleaned_part := nullif(trim(coalesce(in_part, '')), '');

  -- An older client sends four arguments and means playing, which is what
  -- every ask in the table already is. `is distinct from` twice rather than
  -- `not in`, so a null that got past the coalesce is refused instead of
  -- waved through by a null comparison (see 0068).
  cleaned_terms := coalesce(nullif(trim(coalesce(in_terms, '')), ''), 'play');
  if cleaned_terms is distinct from 'play'
     and cleaned_terms is distinct from 'write' then
    raise exception 'An ask is either played on or written on.'
      using errcode = '22023';
  end if;

  insert into public.project_asks
    (project_id, asked_by, asked_of, part, note, audience, terms, sung_in)
  values
    (target_project, auth.uid(), target_person, cleaned_part,
     left(trim(coalesce(in_note, '')), 280), 'collaborators', cleaned_terms,
     -- Cut to the column's length rather than refused: a line that ran long
     -- is not a reason to lose the ask.
     left(trim(coalesce(in_sung_in, '')), 240))
  returning id into new_ask;

  select display_name into asker_name
  from public.profiles where id = auth.uid();

  -- The push is the first thing said about this ask and the one surface the
  -- sentence cannot be scrolled into view on, so the title cannot say "play"
  -- about a write ask. This row is also drawn in the inbox's Activity list
  -- underneath the ask's own card, where "asked you to play" sitting below
  -- "if your part is used, you're a writer" is the contradiction in one
  -- screen. The playing wording is 0063's, untouched, including its "on a
  -- song" for an ask that never named a part.
  perform private.notify_user(
    target_person,
    'song_ask',
    case
      when cleaned_terms = 'write' then
        coalesce(asker_name, 'Somebody') || ' asked you to write on ' ||
          coalesce(cleaned_part, 'a song')
      else
        coalesce(asker_name, 'Somebody') || ' asked you to play ' ||
          coalesce(cleaned_part, 'on a song')
    end,
    coalesce(song.title, 'A song') ||
      case
        when nullif(trim(coalesce(in_note, '')), '') is null then ''
        else ' — ' || left(trim(in_note), 200)
      end,
    song.room_id,
    target_project,
    null,
    auth.uid()
  );

  return new_ask;
end;
$$;

revoke all on function public.ask_musician(uuid, uuid, text, text, text, text)
  from public, anon;
grant execute on function public.ask_musician(uuid, uuid, text, text, text, text)
  to authenticated;

-- The inbox card carries it, with the rest of the brief. Restated from
-- 0145, which is still its latest definition; sung_in is the only change.
-- Dropped first: the shape of a `returns table` cannot be replaced.
drop function if exists public.asks_for_me();

create function public.asks_for_me()
returns table (
  id uuid,
  project_id uuid,
  song_title text,
  asked_by uuid,
  asked_by_name text,
  part text,
  note text,
  created_at timestamptz,

  -- What answering it means. 'play' on every ask this app has ever made
  -- before now, and the app shows nothing for it.
  terms text,

  -- Everything below is the brief, and every field of it already existed
  -- somewhere else in the database.
  storage_path text,
  duration_ms integer,
  musical_key text,
  bpm double precision,

  -- What is already on it, as words. "Guitar and a vocal on it" tells
  -- somebody whether there is a hole shaped like them; a number of takes
  -- tells them nothing and would be a count of somebody's work, which this
  -- app does not put on screens.
  parts_on_it text[],

  -- Whether the chords and words are already worked out. For the person
  -- answering this is the difference between ten minutes and an evening.
  has_song_sheet boolean,

  -- What they would be joining, in the asker's words (0156). Last, so the
  -- columns before it keep the places they had.
  sung_in text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    a.id,
    a.project_id,
    p.title,
    a.asked_by,
    pr.display_name,
    a.part,
    a.note,
    a.created_at,
    a.terms,
    audio.storage_path,
    audio.duration_ms,
    r.musical_key,
    r.bpm,
    coalesce(
      (select array_agg(distinct l.part::text)
         from public.song_layers l
        where l.project_id = p.id
          and l.shared_at is not null
          and l.part is not null),
      '{}'::text[]
    ),
    coalesce(r.analysis_state = 'ready', false),
    a.sung_in
  from public.project_asks a
  join public.projects p on p.id = a.project_id
  left join public.profiles pr on pr.id = a.asked_by
  left join public.project_audio_references r on r.project_id = p.id
  left join lateral private.song_audio(p.id) audio on true
  where a.asked_of = (select auth.uid())
    and a.status = 'open'
  order by a.created_at desc;
$$;

revoke all on function public.asks_for_me() from public, anon;
grant execute on function public.asks_for_me() to authenticated;

-- ---------------------------------------------------------------------
-- The feed can say so
-- ---------------------------------------------------------------------
--
-- Restated from 0076, which is still its latest definition. Two changes,
-- and neither moves a row:
--
--   * The reason line can say "Also sings in Portuguese" when you and the
--     song's owner both wrote the word. It comes after every reason that
--     placed the card ("Needs a", "You have played together", "Both into",
--     "Nearby"), because those are why the card is where it is and this is
--     not: it is said on a card that would otherwise have had nothing to
--     say, or "Nothing like what you play". The word is stored lower case;
--     the first letter comes up here because a language is a proper noun
--     in English.
--   * The row carries the sung_in of the song's latest open ask to
--     everybody, beside its note.
--
-- The tiers, the strangers and every fourth card are 0076's, untouched. A
-- language is most people's in a way a sound is not: once the field is
-- filled in honestly, "english" is shared by most pairs, and a tier built
-- on it would lift everybody who typed it over a neighbour who typed
-- nothing. The plan says a person who declares nothing is not pushed down,
-- so the word is a sentence and never an order (Every Musician, Same Song,
-- 17 September 2026). `knows_me` is untouched as well: having said what you
-- sing in is not having said what you play, and "Nothing like what you
-- play" should not start appearing because of it.
--
-- Never a filter: nothing in the `where` reads sings_in, so nobody is
-- hidden by what they did or did not declare.

drop function if exists public.open_mic_feed(integer, text);

create function public.open_mic_feed(
  in_limit integer default 12,
  in_part text default null
)
returns table (
  id uuid,
  title text,
  owner_id uuid,
  owner_name text,
  owner_avatar text,
  open_mic_at timestamptz,
  asking_for text[],
  ask_note text,
  musical_key text,
  bpm double precision,
  duration_ms integer,
  storage_path text,
  reason text,
  ask_sung_in text
)
language sql
stable
security definer
set search_path = public
as $fn$
  with me as (
    select
      p.id,
      p.plays,
      p.sounds_like,
      p.sings_in,
      case when p.location_visibility = 'public' then lower(trim(p.city)) end
        as city
    from public.profiles p
    where p.id = (select auth.uid())
  ),
  played_with as (
    select distinct other.recorded_by as id
    from public.song_layers mine
    join public.song_layers other on other.project_id = mine.project_id
    where mine.recorded_by = (select auth.uid())
      and mine.shared_at is not null
      and other.shared_at is not null
      and other.recorded_by <> (select auth.uid())
  ),
  knows_me as (
    select
      coalesce(array_length((select plays from me), 1), 0) > 0
      or coalesce(array_length((select sounds_like from me), 1), 0) > 0
      or exists (select 1 from played_with)
      or (select city from me) is not null as yes
  ),
  candidates as (
    select
      p.id,
      p.title,
      p.created_by,
      pr.display_name as owner_name,
      pr.avatar_path as owner_avatar,
      p.open_mic_at,
      coalesce(
        (select array_agg(distinct a.part)
           from public.project_asks a
          where a.project_id = p.id and a.status = 'open'
            and a.part is not null),
        '{}'::text[]
      ) as asking_for,
      coalesce(
        (select a.note from public.project_asks a
          where a.project_id = p.id and a.status = 'open'
            and char_length(trim(a.note)) > 0
          order by a.created_at desc limit 1),
        ''
      ) as ask_note,
      -- From an ask made to everybody, never one sent to a person by name:
      -- that line was written for them, and this card is read by strangers.
      coalesce(
        (select a.sung_in from public.project_asks a
          where a.project_id = p.id and a.status = 'open'
            and a.asked_of is null
            and char_length(trim(a.sung_in)) > 0
          order by a.created_at desc limit 1),
        ''
      ) as ask_sung_in,
      r.musical_key,
      r.bpm,
      audio.duration_ms,
      audio.storage_path,
      fit.needs_you,
      fit.shared_sound,
      fit.shared_sung_in,
      case
        when fit.needs_you is not null then 0
        when fit.known then 1
        when fit.shared_sound is not null then 2
        when fit.same_city then 3
        else 4
      end as tier
    from public.projects p
    left join public.project_audio_references r on r.project_id = p.id
    left join public.profiles pr on pr.id = p.created_by
    left join lateral private.song_audio(p.id) audio on true
    cross join lateral (
      select
        (select a.part
           from public.project_asks a
          where a.project_id = p.id
            and a.status = 'open'
            and a.part is not null
            and a.part = any(
              coalesce((select m.plays from me m), '{}'::text[])
            )
          limit 1) as needs_you,
        exists (select 1 from played_with w where w.id = p.created_by)
          as known,
        -- The first thing you and the person who wrote it both make.
        (select t
           from unnest(coalesce(pr.sounds_like, '{}'::text[])) as t
          where t = any(
            coalesce((select m.sounds_like from me m), '{}'::text[])
          )
          limit 1) as shared_sound,
        -- The first word you and they both sing in, in the order they
        -- wrote theirs. Both sides declared it; nothing here is guessed.
        (select t
           from unnest(coalesce(pr.sings_in, '{}'::text[]))
             with ordinality as u(t, ord)
          where t = any(
            coalesce((select m.sings_in from me m), '{}'::text[])
          )
          order by ord
          limit 1) as shared_sung_in,
        (select city from me) is not null
          and (select city from me) = (
            select lower(trim(pr2.city)) from public.profiles pr2
            where pr2.id = p.created_by
              and pr2.location_visibility = 'public'
          ) as same_city
    ) fit
    where p.open_mic_at is not null
      and p.deleted_at is null
      and audio.storage_path is not null
      and not private.blocked_between((select auth.uid()), p.created_by)
      and p.created_by is distinct from (select auth.uid())
      and (
        in_part is null
        or exists (
          select 1 from public.project_asks a
          where a.project_id = p.id and a.status = 'open' and a.part = in_part
        )
      )
  ),
  -- Named rather than compared against a literal, so adding a tier above
  -- cannot quietly turn the strangers into ordinary rows.
  sorted as (
    select c.*, (c.tier = 4) as is_stranger from candidates c
  ),
  ranked as (
    select
      s.*,
      row_number() over (
        partition by s.is_stranger
        order by s.tier, s.open_mic_at desc
      ) as fit_rank,
      row_number() over (
        partition by s.is_stranger
        order by md5(s.id::text || current_date::text)
      ) as wild_rank
    from sorted s
  )
  select
    rk.id,
    rk.title,
    rk.created_by,
    rk.owner_name,
    rk.owner_avatar,
    rk.open_mic_at,
    rk.asking_for,
    rk.ask_note,
    rk.musical_key,
    rk.bpm,
    rk.duration_ms,
    rk.storage_path,
    case
      when rk.needs_you is not null then 'Needs a ' || rk.needs_you
      when rk.tier = 1 then 'You have played together'
      when rk.shared_sound is not null then 'Both into ' || rk.shared_sound
      when rk.tier = 3 then 'Nearby'
      -- After everything that placed the card, and before the line that
      -- admits a card is a stranger's: a word you both wrote is a truer
      -- thing to say about it than "Nothing like what you play".
      when rk.shared_sung_in is not null then
        'Also sings in ' || upper(left(rk.shared_sung_in, 1)) ||
          substr(rk.shared_sung_in, 2)
      when (select yes from knows_me) then 'Nothing like what you play'
      else ''
    end,
    rk.ask_sung_in
  from ranked rk
  order by
    case
      when not rk.is_stranger
        then rk.fit_rank + ((rk.fit_rank - 1) / 3)
      else rk.wild_rank * 4
    end,
    rk.open_mic_at desc
  limit greatest(least(in_limit, 24), 1);
$fn$;

revoke all on function public.open_mic_feed(integer, text) from public, anon;
grant execute on function public.open_mic_feed(integer, text) to authenticated;
