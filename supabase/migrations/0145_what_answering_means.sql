-- An ask says whether answering means playing or writing.
--
-- Every Musician, Same Song, 17 September 2026: co-writing fights are two
-- honest memories of a session nobody wrote down. Somebody plays a line into
-- a stranger's chorus, the song gets used, and a year later one of them
-- remembers a favour and the other remembers a co-write. Neither is lying.
-- The disagreement was made the moment the ask was sent, because the ask
-- never said what answering it meant.
--
-- So an ask states its terms before anybody records. Two words, chosen once,
-- by the only person who has standing to choose them — whoever is asking for
-- something on their own song — and carried all the way to the person
-- deciding whether to spend an evening on it.
--
-- **Playing is the default and says nothing.** Nearly every ask in this app
-- is somebody wanting bass under a chorus, and a line of small print on all
-- of those would make the normal case read like a contract. 'write' is the
-- one that has to be said out loud, because it is the one that changes what
-- the person answering walks away with.
--
-- **No legal claim is made or recorded.** This is a sentence two people can
-- both point at afterwards, not a licence and not a split. Shares are their
-- own thing, typed by people rather than counted by an app, and they are not
-- in this migration.

alter table public.project_asks
  add column if not exists terms text not null default 'play';

alter table public.project_asks
  drop constraint if exists project_asks_terms_check;
alter table public.project_asks
  add constraint project_asks_terms_check check (terms in ('play', 'write'));

comment on column public.project_asks.terms is
  'What answering this ask means: play (the default, and what every ask made '
  'before this migration was) or write. Set when the ask is made and refused '
  'afterwards by project_asks_terms_are_fixed.';

-- ---------------------------------------------------------------------
-- Chosen once
-- ---------------------------------------------------------------------
--
-- The whole value of the sentence is that it was there before the work was.
-- Terms that can be edited afterwards are the argument again with an audit
-- trail: whoever changed them is right, and the other person's memory is
-- wrong in writing.
--
-- At the table rather than only in a function, because `project_asks_close`
-- (0049) lets the asker and the room owner update this row directly through
-- PostgREST, columns and all — so a rule that lived only in an RPC is a rule
-- somebody walks around with one request.
--
-- `is distinct from`, so an update that names the same value it already has
-- is left alone. Closing an ask sends status and closed_at and never
-- mentions terms, which is the update this trigger sees most.
create or replace function private.ask_terms_are_fixed()
returns trigger
language plpgsql
security definer set search_path = ''
as $fn$
begin
  if new.terms is distinct from old.terms then
    raise exception 'What an ask means was settled when it was sent.'
      using errcode = '42501';
  end if;
  return new;
end;
$fn$;

revoke all on function private.ask_terms_are_fixed()
  from public, anon, authenticated;

drop trigger if exists project_asks_terms_are_fixed on public.project_asks;
create trigger project_asks_terms_are_fixed
before update on public.project_asks
for each row execute function private.ask_terms_are_fixed();

-- ---------------------------------------------------------------------
-- Asking one musician, with terms
-- ---------------------------------------------------------------------
--
-- Restated from 0063, which is still its latest definition, with one
-- parameter and one cleaned value added. Everything else — the block check,
-- the "not your song to offer" refusal, the notification — is 0063's.
--
-- Dropped first because a fifth parameter with a default does not replace
-- the four-parameter function, it joins it, and a four-argument call would
-- then match both and fail as ambiguous.
drop function if exists public.ask_musician(uuid, uuid, text, text);

create function public.ask_musician(
  target_project uuid,
  target_person uuid,
  in_part text default null,
  in_note text default '',
  in_terms text default 'play'
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
    (project_id, asked_by, asked_of, part, note, audience, terms)
  values
    (target_project, auth.uid(), target_person, cleaned_part,
     left(trim(coalesce(in_note, '')), 280), 'collaborators', cleaned_terms)
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

revoke all on function public.ask_musician(uuid, uuid, text, text, text)
  from public, anon;
grant execute on function public.ask_musician(uuid, uuid, text, text, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- The brief carries it
-- ---------------------------------------------------------------------
--
-- The terms belong with the key, the tempo and what is already on the song,
-- for the same reason all of those are there: everything the person deciding
-- needs has to arrive with the ask, or the only honest answer is "let me go
-- and look" (0094).
--
-- Dropped first, and this is the sixth migration in this repo to need that
-- sentence: `create or replace` cannot change the shape of a `returns table`
-- and fails with "cannot change return type of existing function".
--
-- Restated from 0094, which is still its latest definition.
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
  has_song_sheet boolean
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
    coalesce(r.analysis_state = 'ready', false)
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
