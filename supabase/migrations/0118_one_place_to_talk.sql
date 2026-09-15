-- One place to talk.
--
-- Taylor, 14 Sep: "can we also add a chat inbox, or some way of seeing all
-- messages with users on the home page, in an intuitive way, so you don't
-- need to go to each user individually just to see your chat between them"
-- -- and: "the same way the colabroom handles rooms, for your projects and
-- bands and such, the chat could be similar, you can create rooms for your
-- band, or message people individually, but it's all in one place, seamless
-- and intuitive."
--
-- 0112 gave two people a thread. This gives a room one -- the band talking
-- in the room the band already has, with nobody to invite and nothing to
-- set up -- and gives one screen the list of every thread you are in, room
-- or person, newest first, with what was last said and how much of it you
-- have not seen.
--
-- Three pieces:
--
--   room_messages   a line said in a room, by a member, readable by members
--   thread_reads    when you last looked at a thread, one row per thread
--   my_threads()    every thread you are in, as the inbox lists them
--
-- A room message tells every other member the same way a direct message
-- tells its one reader: a direct_message notification, titled with the
-- sender's name, carrying the room so the app opens the room's thread and
-- not the sender's. No new enum value: to the person told, "somebody said
-- something to you" is one kind of thing whichever door it came through.

-- ---------------------------------------------------------------------
-- What a room says to itself.
-- ---------------------------------------------------------------------

create table public.room_messages (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  author_id uuid not null default auth.uid()
    references public.profiles(id) on delete cascade,
  body text not null check (char_length(trim(body)) between 1 and 500),
  created_at timestamptz not null default now()
);

create index room_messages_room_idx
  on public.room_messages (room_id, created_at);

alter table public.room_messages enable row level security;

-- Members read. is_room_member (0001) is the rule the rest of a room runs
-- on; a thread a member cannot read would be the first thing in a room
-- that worked differently.
create policy room_messages_read on public.room_messages
for select to authenticated using (private.is_room_member(room_id));

create policy room_messages_write on public.room_messages
for insert to authenticated with check (
  author_id = (select auth.uid())
  and private.is_room_member(room_id)
);

-- Your own words, takeable back. No edits, for the reason 0110 gave.
create policy room_messages_delete_own on public.room_messages
for delete to authenticated using (author_id = (select auth.uid()));

-- Telling the rest of the room. One notification per other member, so
-- everybody's phone hears about it the way it hears about a direct
-- message; notify_user drops the author and anybody who has blocked the
-- sender is not a member of a room with them in the first place (0063).
create or replace function private.announce_room_message()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
declare
  author_name text;
  room_name text;
  member record;
begin
  select pr.display_name into author_name
  from public.profiles pr where pr.id = new.author_id;
  select r.name into room_name
  from public.rooms r where r.id = new.room_id;

  for member in
    select rm.user_id from public.room_members rm
    where rm.room_id = new.room_id and rm.user_id <> new.author_id
  loop
    perform private.notify_user(
      member.user_id,
      'direct_message',
      coalesce(author_name, 'Somebody') || ' · ' || coalesce(room_name, 'your room'),
      left(trim(new.body), 200),
      new.room_id,
      null,
      null,
      new.author_id
    );
  end loop;

  return new;
end;
$$;

drop trigger if exists room_messages_announce on public.room_messages;
create trigger room_messages_announce
after insert on public.room_messages
for each row execute function private.announce_room_message();

-- ---------------------------------------------------------------------
-- When you last looked.
-- ---------------------------------------------------------------------

-- One row per thread you have opened. kind is 'room' or 'person'; target is
-- the room, or the other person. Missing means never, which counts as
-- everything unread -- a thread you have not opened is exactly that.
create table public.thread_reads (
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('room', 'person')),
  target uuid not null,
  read_at timestamptz not null default now(),
  primary key (user_id, kind, target)
);

alter table public.thread_reads enable row level security;

create policy thread_reads_own on public.thread_reads
for all to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

create or replace function public.mark_thread_read(thread_kind text, thread_target uuid)
returns void
language plpgsql
security definer set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;
  if thread_kind not in ('room', 'person') then
    raise exception 'Unknown kind of thread.' using errcode = '22023';
  end if;
  insert into public.thread_reads (user_id, kind, target, read_at)
  values (auth.uid(), thread_kind, thread_target, now())
  on conflict (user_id, kind, target) do update set read_at = now();
end;
$$;

revoke all on function public.mark_thread_read(text, uuid) from public, anon;
grant execute on function public.mark_thread_read(text, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Every thread you are in.
-- ---------------------------------------------------------------------

-- Rooms you are a member of, whether or not anybody has said anything in
-- them yet -- the band chat exists the moment the band does -- and every
-- person you have a thread with. Each with what was last said, by whom,
-- when, and how many lines from other people have arrived since you last
-- looked. Sorted by the caller: last_at is the order, nulls last.
--
-- Security definer because it reads room_members and direct_messages for
-- the caller across every room at once; every row it returns is one the
-- caller could already read under the policies on those tables (member of
-- the room; one of the pair, unblocked).
create or replace function public.my_threads()
returns table (
  kind text,
  target uuid,
  name text,
  icon text,
  avatar_path text,
  member_count integer,
  last_body text,
  last_author_id uuid,
  last_author_name text,
  last_at timestamptz,
  unread integer
)
language sql
security definer set search_path = ''
stable
as $$
  with me as (select auth.uid() as id),
  rooms as (
    select r.id, r.name, r.icon,
           (select count(*)::integer from public.room_members m2 where m2.room_id = r.id) as member_count
    from public.rooms r
    join public.room_members rm on rm.room_id = r.id
    where rm.user_id = (select id from me)
  ),
  room_last as (
    select distinct on (rmsg.room_id) rmsg.room_id, rmsg.body, rmsg.author_id, rmsg.created_at
    from public.room_messages rmsg
    where rmsg.room_id in (select id from rooms)
    order by rmsg.room_id, rmsg.created_at desc
  ),
  room_rows as (
    select 'room'::text as kind, r.id as target, r.name, r.icon,
           null::text as avatar_path, r.member_count,
           rl.body as last_body, rl.author_id as last_author_id,
           pr.display_name as last_author_name, rl.created_at as last_at,
           (select count(*)::integer from public.room_messages x
            where x.room_id = r.id
              and x.author_id <> (select id from me)
              and x.created_at > coalesce(
                (select tr.read_at from public.thread_reads tr
                 where tr.user_id = (select id from me)
                   and tr.kind = 'room' and tr.target = r.id),
                'epoch'::timestamptz)) as unread
    from rooms r
    left join room_last rl on rl.room_id = r.id
    left join public.profiles pr on pr.id = rl.author_id
  ),
  pairs as (
    select distinct
      case when d.pair_low = (select id from me) then d.pair_high else d.pair_low end as other
    from public.direct_messages d
    where (select id from me) in (d.pair_low, d.pair_high)
      and not private.blocked_between(d.pair_low, d.pair_high)
  ),
  person_last as (
    select distinct on (p.other) p.other, d.body, d.author_id, d.created_at
    from pairs p
    join public.direct_messages d
      on d.pair_low = least(p.other, (select id from me))
     and d.pair_high = greatest(p.other, (select id from me))
    order by p.other, d.created_at desc
  ),
  person_rows as (
    select 'person'::text as kind, p.other as target,
           coalesce(pr.display_name, 'Somebody') as name, null::text as icon,
           pr.avatar_path, 2 as member_count,
           pl.body as last_body, pl.author_id as last_author_id,
           coalesce(apr.display_name, 'Somebody') as last_author_name,
           pl.created_at as last_at,
           (select count(*)::integer from public.direct_messages x
            where x.pair_low = least(p.other, (select id from me))
              and x.pair_high = greatest(p.other, (select id from me))
              and x.author_id <> (select id from me)
              and x.created_at > coalesce(
                (select tr.read_at from public.thread_reads tr
                 where tr.user_id = (select id from me)
                   and tr.kind = 'person' and tr.target = p.other),
                'epoch'::timestamptz)) as unread
    from pairs p
    left join public.profiles pr on pr.id = p.other
    left join person_last pl on pl.other = p.other
    left join public.profiles apr on apr.id = pl.author_id
  )
  select * from room_rows
  union all
  select * from person_rows
  order by last_at desc nulls last, name;
$$;

revoke all on function public.my_threads() from public, anon;
grant execute on function public.my_threads() to authenticated;
