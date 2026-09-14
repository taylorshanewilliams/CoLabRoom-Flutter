-- Something to say back.
--
-- An ask has had two possible answers: a take, which costs an evening, and
-- silence. Production on 14 Sep 2026: one ask ever sent, four nods, and not
-- one typed word anywhere in the app -- no comment on a lyric, no message on
-- a song. Everything a band would actually say about a request ("I hear
-- pedal steel on the chorus", "Thursday, if that's soon enough", "what key
-- is it in?") had nowhere to go, so it went nowhere, and an ask that cannot
-- be talked about is a form.
--
-- So: replies on an ask. Short, in order, readable by exactly the people who
-- can already see the ask -- the room for a room ask, the one person for a
-- direct one -- and by whoever asked. Nothing here grants anything: the song
-- rides along under the consent rule from 0094 (an open ask lets the person
-- asked hear it), and a reply is only words about it.

create table public.ask_replies (
  id uuid primary key default gen_random_uuid(),
  ask_id uuid not null references public.project_asks(id) on delete cascade,
  author_id uuid not null default auth.uid()
    references public.profiles(id) on delete cascade,
  body text not null check (char_length(trim(body)) between 1 and 500),
  created_at timestamptz not null default now()
);

create index ask_replies_ask_idx on public.ask_replies (ask_id, created_at);

alter table public.ask_replies enable row level security;

-- Who is in the conversation: the same people who can see the ask. One
-- function, because the read policy, the write policy and the trigger below
-- all need the same answer and three copies of it would drift.
create or replace function private.can_see_ask(target_ask uuid)
returns boolean
language sql
security definer set search_path = ''
stable
as $$
  select exists (
    select 1
    from public.project_asks a
    join public.projects p on p.id = a.project_id
    where a.id = target_ask
      and (
        a.asked_of = auth.uid()
        or a.asked_by = auth.uid()
        or private.is_room_member(p.room_id)
        or private.is_project_member(p.id)
      )
      and (
        a.asked_by is null
        or not private.blocked_between(auth.uid(), a.asked_by)
      )
  );
$$;

-- Callable from the policies below, which run as the person asking. The
-- block check inside runs with the function owner's rights, the way 0063
-- intended blocked_between to be reached.
revoke all on function private.can_see_ask(uuid) from public, anon;
grant execute on function private.can_see_ask(uuid) to authenticated;

create policy ask_replies_read on public.ask_replies
for select to authenticated using (private.can_see_ask(ask_id));

create policy ask_replies_write on public.ask_replies
for insert to authenticated with check (
  author_id = (select auth.uid()) and private.can_see_ask(ask_id)
);

-- Your own words, takeable back. No edits: a thread that can be rewritten
-- after somebody has answered it is not a record of what was said.
create policy ask_replies_delete_own on public.ask_replies
for delete to authenticated using (author_id = (select auth.uid()));

-- ---------------------------------------------------------------------
-- Telling the people in the conversation, and nobody else.
-- ---------------------------------------------------------------------

-- The asker, the person asked, and anyone who has already replied. Not the
-- room: the ask told the room once, and a room ask with a long thread on it
-- must not become a notification per sentence for people who never joined
-- in. The notification is of type song_ask rather than a new type on
-- purpose -- builds in the field from before #235 lock their owner out of
-- the app at start-up on a type they have not met.
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

  select p.title, p.room_id into song_title, song_room
  from public.projects p
  where p.id = the_ask.project_id;

  select pr.display_name into author_name
  from public.profiles pr
  where pr.id = new.author_id;

  said := coalesce(author_name, 'Somebody') || ' replied about ' ||
          coalesce(song_title, 'a song');

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
