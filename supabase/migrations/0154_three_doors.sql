-- Three ways to answer a song.
--
-- Every Musician, Same Song, 17 September 2026: feedback without scores.
-- Somebody who has heard a song they were asked about answers it through
-- one of three doors -- what stayed with me, a question, an opinion -- and
-- the third door is the one the whole idea turns on. An opinion waits until
-- the person who asked says they are ready to read it. The other two arrive
-- the way replies always have.
--
-- **Why hold opinions at all.** A song sent out with an ask on it is a song
-- somebody is still inside. "What stayed with me" and "a question" are
-- answers a writer can read on any evening; "the bridge drags" is one they
-- want to choose the evening for. Holding opinions until the writer taps
-- "I'm ready" is what turns critique from something that happens to a
-- person into something they open. There is no number anywhere in this: no
-- rating, no count of what arrived, no mark that a reply helped. A count of
-- replies used to ride on the ask's chip in the app; the app stops drawing
-- it with this migration, because a reply is a sentence and a sentence is
-- not a tally.
--
-- **The shape.** One column on ask_replies for the door, nullable: every
-- reply written before today, and every line the asker writes back in their
-- own thread, is a plain line through no door, and an older build that
-- sends no kind still writes one. One column on project_asks for the
-- readiness: the plan names the held state on the replies, but "held" is
-- one fact about the ask -- has the person who asked said they are ready --
-- not one fact per reply. Held per reply would make "I'm ready" a letterbox
-- the asker has to keep opening without being told whether anything is in
-- it, and telling them would be the badge this slice must not draw. Once
-- ready, opinions arrive normally, and the first time stands.
--
-- **Who reads an opinion.** Its writer, always, so they can take it back;
-- and the person who asked, once they are ready. Nobody else, ever -- not
-- the room, not the person a direct ask was sent to. An opinion is for the
-- person who asked for it. The read policy carries all of that, so no
-- select the app makes can show a held opinion by mistake.
--
-- **Who opens them.** Only the person who asked. project_asks_close (0049)
-- lets the room owner update the row too, so a rule that lived only in the
-- app would be one request away from an owner deciding for the asker; the
-- guard is a table trigger, the way 0145 fixed the terms.
--
-- **Telling people.** A held opinion tells nobody: a push saying "Somebody
-- replied about your song" with the first line of the opinion under it is
-- the opinion arriving. Once the asker is ready, an opinion tells the asker
-- and only the asker, because they are the only person who can read it.

alter table public.ask_replies
  add column if not exists kind text;

alter table public.ask_replies
  drop constraint if exists ask_replies_kind_check;
alter table public.ask_replies
  add constraint ask_replies_kind_check
  check (kind is null or kind in ('stayed', 'question', 'opinion'));

comment on column public.ask_replies.kind is
  'Which of the three doors this reply came through: stayed (what stayed '
  'with me), question, or opinion. Null is a plain line: every reply from '
  'before 0154, and the asker answering back in their own thread.';

alter table public.project_asks
  add column if not exists opinions_opened_at timestamptz;

comment on column public.project_asks.opinions_opened_at is
  'When the person who asked said they were ready to read opinions. Null '
  'holds every opinion on the ask from them; set, opinions arrive normally. '
  'Set once, by the asker only (project_asks_opinions_open).';

-- ---------------------------------------------------------------------
-- Who reads what
-- ---------------------------------------------------------------------
--
-- Restated from 0110, which is still its latest definition. The first line
-- is 0110's rule untouched; the rest is the door.

drop policy if exists ask_replies_read on public.ask_replies;
create policy ask_replies_read on public.ask_replies
for select to authenticated using (
  private.can_see_ask(ask_id)
  and (
    -- `is distinct from`, so a plain line (null) and the other two doors
    -- pass, and only an opinion goes on to the next two lines.
    kind is distinct from 'opinion'
    or author_id = (select auth.uid())
    or exists (
      select 1 from public.project_asks a
      where a.id = ask_id
        and a.asked_by = (select auth.uid())
        and a.opinions_opened_at is not null
    )
  )
);

-- ---------------------------------------------------------------------
-- Only the asker says when
-- ---------------------------------------------------------------------
--
-- The first "I'm ready" stands. A second tap -- two devices, a retry -- is
-- not an error and does not move the time, so the app never has to fail
-- over a decision that was already made.

create or replace function private.ask_opinions_open()
returns trigger
language plpgsql
security definer set search_path = ''
as $fn$
begin
  if new.opinions_opened_at is distinct from old.opinions_opened_at then
    if old.opinions_opened_at is not null then
      new.opinions_opened_at := old.opinions_opened_at;
    elsif old.asked_by is distinct from auth.uid() then
      raise exception 'Only the person who asked decides when to read opinions.'
        using errcode = '42501';
    end if;
  end if;
  return new;
end;
$fn$;

revoke all on function private.ask_opinions_open()
  from public, anon, authenticated;

drop trigger if exists project_asks_opinions_open on public.project_asks;
create trigger project_asks_opinions_open
before update on public.project_asks
for each row execute function private.ask_opinions_open();

-- ---------------------------------------------------------------------
-- Telling the people in the conversation, and nobody else
-- ---------------------------------------------------------------------
--
-- Restated from 0110, which is still its latest definition, with the two
-- opinion branches added. Everything else -- who hears about a plain line,
-- a question or what stayed, and that nobody hears about their own words --
-- is 0110's.

create or replace function private.announce_ask_reply()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
declare
  the_ask public.project_asks%rowtype;
  song_title text;
  song_room uuid;
  author_name text;
  said text;
  hearer uuid;
begin
  select * into the_ask from public.project_asks where id = new.ask_id;
  if the_ask.id is null then
    return new;
  end if;

  -- A held opinion is silent. The person who asked has not said they are
  -- ready, and a notification carrying its first line would be it arriving.
  if new.kind = 'opinion' and the_ask.opinions_opened_at is null then
    return new;
  end if;

  select p.title, p.room_id into song_title, song_room
  from public.projects p
  where p.id = the_ask.project_id;

  select pr.display_name into author_name
  from public.profiles pr
  where pr.id = new.author_id;

  said := coalesce(author_name, 'Somebody') || ' replied about ' ||
          coalesce(song_title, 'a song');

  -- An opinion the asker is ready for goes to the asker, and to nobody
  -- else: the person a direct ask was sent to and the earlier repliers
  -- cannot read it, and a notification about words you cannot read is a
  -- notification about nothing.
  if new.kind = 'opinion' then
    if the_ask.asked_by is not null
       and the_ask.asked_by is distinct from new.author_id then
      perform private.notify_user(
        the_ask.asked_by,
        'song_ask',
        said,
        left(trim(new.body), 200),
        song_room,
        the_ask.project_id,
        null,
        new.author_id
      );
    end if;
    return new;
  end if;

  for hearer in
    select distinct who
    from (
      select the_ask.asked_by as who
      union
      select the_ask.asked_of
      union
      select r.author_id from public.ask_replies r where r.ask_id = new.ask_id
    ) everyone
    where who is not null and who is distinct from new.author_id
  loop
    perform private.notify_user(
      hearer,
      'song_ask',
      said,
      left(trim(new.body), 200),
      song_room,
      the_ask.project_id,
      null,
      new.author_id
    );
  end loop;

  return new;
end;
$$;

drop trigger if exists ask_replies_announce on public.ask_replies;
create trigger ask_replies_announce
after insert on public.ask_replies
for each row execute function private.announce_ask_reply();
