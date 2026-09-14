-- Between the two of you.
--
-- 0101 made a connection: two people who can find each other again. 0102
-- let one of them tell the other about a song. Neither gave them anywhere
-- to talk. The bass player you met here and would work with again could be
-- found, told, and asked -- and could not be answered with a sentence.
--
-- So: a thread between two people. Plain lines, in order, nothing else.
-- Who may write is the rule 0102 already settled for telling somebody
-- anything: connected, or in a room together, and no block either way.
-- Who may read is the pair, and only while neither has blocked the other
-- -- the thread goes quiet in both directions at once, so a block cannot be
-- detected from the far side by what stops arriving.
--
-- The pair is stored ordered (low, high) so one thread has one key whichever
-- of them opens it.

create table public.direct_messages (
  id uuid primary key default gen_random_uuid(),
  pair_low uuid not null references public.profiles(id) on delete cascade,
  pair_high uuid not null references public.profiles(id) on delete cascade,
  author_id uuid not null default auth.uid()
    references public.profiles(id) on delete cascade,
  body text not null check (char_length(trim(body)) between 1 and 500),
  created_at timestamptz not null default now(),
  constraint direct_messages_pair_ordered check (pair_low < pair_high),
  constraint direct_messages_author_in_pair
    check (author_id in (pair_low, pair_high))
);

create index direct_messages_pair_idx
  on public.direct_messages (pair_low, pair_high, created_at);

alter table public.direct_messages enable row level security;

-- The pair, unless one of them has blocked the other. Definer, because
-- blocked_between (0063) is deliberately not callable by the person asking.
create or replace function private.can_read_pair(low uuid, high uuid)
returns boolean
language sql
security definer set search_path = ''
stable
as $$
  select auth.uid() in (low, high)
     and not private.blocked_between(low, high);
$$;

revoke all on function private.can_read_pair(uuid, uuid) from public, anon;
grant execute on function private.can_read_pair(uuid, uuid) to authenticated;

create policy direct_messages_read on public.direct_messages
for select to authenticated using (private.can_read_pair(pair_low, pair_high));

-- Writing: you, to somebody you may tell. may_tell (0102) is connected or
-- sharing a room, not yourself, and no block either way.
create policy direct_messages_write on public.direct_messages
for insert to authenticated with check (
  author_id = (select auth.uid())
  and public.may_tell(
    case when pair_low = (select auth.uid()) then pair_high else pair_low end
  )
);

-- Your own words, takeable back. No edits, for the reason 0110 gave.
create policy direct_messages_delete_own on public.direct_messages
for delete to authenticated using (author_id = (select auth.uid()));

-- ---------------------------------------------------------------------
-- Telling the other person.
-- ---------------------------------------------------------------------

-- One notification, to the one other person, titled with the sender's name
-- and carrying the first two hundred characters. actor_id is the sender so
-- the app can open the thread from the notification.
create or replace function private.announce_direct_message()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
declare
  other uuid;
  author_name text;
begin
  other := case when new.author_id = new.pair_low
                then new.pair_high else new.pair_low end;

  select pr.display_name into author_name
  from public.profiles pr
  where pr.id = new.author_id;

  perform private.notify_user(
    other,
    'direct_message',
    coalesce(author_name, 'Somebody'),
    left(trim(new.body), 200),
    null,
    null,
    null,
    new.author_id
  );

  return new;
end;
$$;

drop trigger if exists direct_messages_announce on public.direct_messages;
create trigger direct_messages_announce
after insert on public.direct_messages
for each row execute function private.announce_direct_message();
