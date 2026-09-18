-- Take turns on the loop.
--
-- Every Musician, Same Song, 17 September 2026, slice 33: "A beat goes round
-- a room in 16-bar turns. 'Skip me' is always free. It plays back as one
-- conversation." Cyphers, trading fours, bluegrass breaks, jugalbandi by
-- post. It is the one way of playing together that fits the physics: phones
-- cannot play in time with each other over a network, and nobody has to,
-- because a turn is something you take after the last one and before the
-- next.
--
-- **What a turn is.** An ordinary take (0038) that starts on the passage
-- (0045's start_ms). Nothing about it is new: it has a level, the retention
-- sweep treats it like any other take, its player is asked before it goes
-- in front of strangers (0155) and can pull it afterwards. All this file
-- adds is whose turn it is and which take was whose turn, so every rule
-- about takes keeps holding without being restated here.
--
-- **What a round is.** A passage of one song, kept as two times and never
-- as a name (two phones cannot misread a number the way they can misread
-- "Chorus 2"), and an order of people. One round at a time on a song.
--
-- **Whose turn it is** is never stored. It is the first person in the order
-- who is still waiting and can still record in the room, worked out when
-- somebody asks. A pointer would be one more thing to fall out of step with
-- the seats it points at, and somebody who leaves the room mid-round would
-- hold it for ever.
--
-- **Skip me is free and silent.** A seat that is skipped goes quiet: nobody
-- is told, the next person gets the same two lines they would have got
-- anyway, and nobody but the person who skipped can read that seat again,
-- here or through the table. They can come back in at the end of the order
-- whenever they like. There is no score, no vote, no count and no winner
-- anywhere in this file, because there is nowhere to put one.
--
-- **The quiet pass.** The plan's test line is "turn passes silently on
-- expiry", and with one invitation in nine answered a strict order would
-- otherwise stop at the first person who never opens the app. So a turn
-- nobody has taken for three days passes the same way a skip does, the next
-- time anybody in the room looks -- never on the look of the person whose
-- turn it is, who would otherwise open the app to play and watch the turn
-- leave. Nobody is shown a timer, a deadline or how long anybody took, and
-- one look passes one turn at most, so nobody is passed over for a turn
-- they were never told about.
--
-- **Publishing the result** needs nothing new, which is the point of a turn
-- being an ordinary take: handing a turn in shares it with the room, and
-- 0155 already refuses to put a song in front of strangers until everybody
-- with a shared take on it has said yes -- at both functions and at the
-- table. A round is only ever read by the room.
--
-- No new notification type: "your turn" is news about a song, and rides the
-- switch everything else about a song rides on.

-- ---------------------------------------------------------------------
-- The round and its order
-- ---------------------------------------------------------------------

create table if not exists public.loop_rounds (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  -- Null when the account that started it is gone. The round stays: the
  -- turns in it are other people's playing.
  started_by uuid references public.profiles(id) on delete set null,
  start_ms integer not null check (start_ms >= 0),
  end_ms integer not null,
  created_at timestamptz not null default now(),
  -- When the turn last moved. Read by the quiet pass and by nothing else;
  -- it is never returned to anybody.
  turn_since timestamptz not null default now(),
  ended_at timestamptz,
  check (end_ms > start_ms)
);

comment on table public.loop_rounds is
  'A passage of a song going round a room in turns. Every Musician, Same '
  'Song, 17 September 2026.';

-- One round at a time on a song.
create unique index if not exists loop_rounds_one_open_idx
  on public.loop_rounds (project_id) where ended_at is null;
create index if not exists loop_rounds_project_idx
  on public.loop_rounds (project_id, created_at desc);

create table if not exists public.loop_seats (
  round_id uuid not null references public.loop_rounds(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  -- Where in the order. Playback assembles by this and never by when a turn
  -- was recorded, so somebody who comes back in goes to the end of the line
  -- and the conversation still reads in the order it was had.
  place integer not null,
  state text not null default 'waiting'
    check (state in ('waiting', 'played', 'out')),
  -- The take that was this person's turn. A take that is deleted, by its
  -- player or by the retention sweep, empties the seat and nothing else.
  layer_id uuid references public.song_layers(id) on delete set null,
  primary key (round_id, user_id),
  unique (round_id, place),
  check (state = 'played' or layer_id is null)
);

comment on table public.loop_seats is
  'Who is in a round, in what order, and which take was their turn. '
  'Written only by the functions in 0159.';

-- A take is one turn, once. Also what the foreign key looks a seat up by
-- when a take is deleted.
create unique index if not exists loop_seats_layer_idx
  on public.loop_seats (layer_id) where layer_id is not null;

alter table public.loop_rounds enable row level security;
alter table public.loop_seats enable row level security;

-- The room reads the round. Nobody writes either table directly: every row
-- is made and moved by the functions below.
drop policy if exists loop_rounds_read_members on public.loop_rounds;
create policy loop_rounds_read_members on public.loop_rounds
for select to authenticated using (
  exists (
    select 1 from public.projects p
    where p.id = loop_rounds.project_id
      and private.is_room_member(p.room_id)
  )
);

-- Your own seat and nothing else. The order is read through
-- loop_rounds_for, which leaves out the seats that have gone quiet; a
-- policy that let the room read this table would let anybody see who
-- skipped, which is the one thing a skip promises they cannot.
drop policy if exists loop_seats_read_own on public.loop_seats;
create policy loop_seats_read_own on public.loop_seats
for select to authenticated using (user_id = (select auth.uid()));

revoke all on table public.loop_rounds from public, anon, authenticated;
revoke all on table public.loop_seats from public, anon, authenticated;
grant select on table public.loop_rounds to authenticated;
grant select on table public.loop_seats to authenticated;

-- ---------------------------------------------------------------------
-- What a seat reads as, and whose turn it is
-- ---------------------------------------------------------------------

-- A seat as anybody is allowed to see it. Played means the room can hear
-- the turn: a take that was deleted, or that its player took back from the
-- room (0057's unshare), reads as out, the same as a skip -- "each can pull
-- their slot", and pulling it says nothing about why.
create or replace function private.loop_seat_state(seat_state text, seat_layer uuid)
returns text
language sql
stable
security definer set search_path = ''
as $fn$
  select case
    when seat_state = 'waiting' then 'waiting'
    when seat_state = 'played' and exists (
      select 1 from public.song_layers l
      where l.id = seat_layer and l.shared_at is not null
    ) then 'played'
    else 'out'
  end;
$fn$;

revoke all on function private.loop_seat_state(text, uuid)
  from public, anon, authenticated;

-- Whose turn it is: the first person in the order who is still waiting and
-- can still record in the room. Somebody who has left the room, or been
-- made a viewer, is stepped over without a word rather than holding the
-- round for ever. Null when nobody is waiting, or the round is over.
create or replace function private.loop_round_up(target_round uuid)
returns uuid
language sql
stable
security definer set search_path = ''
as $fn$
  select s.user_id
  from public.loop_seats s
  join public.loop_rounds r on r.id = s.round_id
  join public.projects p on p.id = r.project_id
  join public.room_members m
    on m.room_id = p.room_id and m.user_id = s.user_id
  where s.round_id = target_round
    and r.ended_at is null
    and s.state = 'waiting'
    and m.role in ('owner', 'editor')
  order by s.place
  limit 1;
$fn$;

revoke all on function private.loop_round_up(uuid)
  from public, anon, authenticated;

-- Tells whoever is up that they are, in the same two lines however the turn
-- reached them -- a turn handed in, a skip, or the quiet pass. No actor on
-- it, for that reason: a notification that named the person before you
-- would be announcing their skip. Never sent to the person whose own action
-- made them next; they are looking at the screen.
create or replace function private.tell_whose_turn(target_round uuid)
returns void
language plpgsql
security definer set search_path = ''
as $fn$
declare
  next_up uuid := private.loop_round_up(target_round);
  song record;
begin
  if next_up is null or next_up is not distinct from auth.uid() then
    return;
  end if;

  select p.id, p.room_id, p.title into song
  from public.loop_rounds r
  join public.projects p on p.id = r.project_id
  where r.id = target_round;

  perform private.notify_user(
    next_up,
    'project_update',
    'Your turn on ' || coalesce(song.title, 'a song'),
    'The loop has come round to you. Skipping is free, and nobody is told.',
    song.room_id,
    song.id,
    null,
    null
  );
end;
$fn$;

revoke all on function private.tell_whose_turn(uuid)
  from public, anon, authenticated;

-- The quiet pass. Called at the top of everything that reads or moves a
-- round, so there is no job to schedule and nothing happens while nobody
-- is looking. One turn at most, and the clock starts again for whoever is
-- next: they are told now, so their three days start now. Never the
-- caller's own turn -- see the top of this file.
create or replace function private.settle_loop_round(target_round uuid)
returns void
language plpgsql
security definer set search_path = ''
as $fn$
declare
  the_round record;
  holding uuid;
begin
  select r.id, r.turn_since, r.ended_at into the_round
  from public.loop_rounds r
  where r.id = target_round
  for update;

  if the_round.id is null or the_round.ended_at is not null then
    return;
  end if;
  if the_round.turn_since > now() - interval '3 days' then
    return;
  end if;

  holding := private.loop_round_up(target_round);
  if holding is null or holding is not distinct from auth.uid() then
    return;
  end if;

  update public.loop_seats
  set state = 'out'
  where round_id = target_round and user_id = holding;

  update public.loop_rounds set turn_since = now() where id = target_round;

  perform private.tell_whose_turn(target_round);
end;
$fn$;

revoke all on function private.settle_loop_round(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Starting one
-- ---------------------------------------------------------------------

-- The passage and the order, from anybody who can record in the room. The
-- order is whoever said they want in, as the person starting it heard it:
-- each person once, the first time they are named, and only people who can
-- put a take on this song. Left empty, it is the person starting it, and
-- everybody else joins themselves.
--
-- Somebody outside the room gets the sentence they would get for a song
-- that does not exist, so a refusal never says what is in a room.
create or replace function public.start_loop_round(
  target_project uuid,
  in_start_ms integer,
  in_end_ms integer,
  in_order uuid[] default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  me uuid := auth.uid();
  song record;
  going uuid;
  made uuid;
  wanted uuid[];
  person record;
  starter text;
  first_up uuid;
begin
  select p.id, p.room_id, p.title into song
  from public.projects p
  where p.id = target_project and p.deleted_at is null;

  if song.id is null or not private.is_room_member(song.room_id) then
    raise exception 'No such song.' using errcode = '22023';
  end if;
  if coalesce(private.room_role_for(song.room_id)::text, '')
       not in ('owner', 'editor') then
    raise exception 'Only somebody who can record here can start a round.'
      using errcode = '42501';
  end if;
  if in_start_ms is null or in_end_ms is null
     or in_start_ms < 0 or in_end_ms <= in_start_ms then
    raise exception 'Choose the bars first.' using errcode = '22023';
  end if;

  -- One at a time. A round everybody has finished with makes way on its
  -- own; one somebody is still waiting on has to be ended by whoever
  -- started it, because ending it takes a turn away from a person.
  select r.id into going
  from public.loop_rounds r
  where r.project_id = target_project and r.ended_at is null
  for update;

  if going is not null then
    if private.loop_round_up(going) is not null then
      raise exception 'This song already has a round going.'
        using errcode = '22023';
    end if;
    update public.loop_rounds set ended_at = now() where id = going;
  end if;

  select array_agg(named.id order by named.first_at) into wanted
  from (
    select o.id, min(o.n) as first_at
    from unnest(coalesce(in_order, array[]::uuid[]))
      with ordinality as o(id, n)
    where o.id is not null
    group by o.id
  ) named;

  if wanted is null then
    wanted := array[me];
  end if;

  if exists (
    select 1
    from unnest(wanted) as w(id)
    where not exists (
      select 1 from public.room_members m
      where m.room_id = song.room_id
        and m.user_id = w.id
        and m.role in ('owner', 'editor')
    )
  ) then
    raise exception 'Everybody in the order has to be able to record in this room.'
      using errcode = '22023';
  end if;

  begin
    insert into public.loop_rounds (project_id, started_by, start_ms, end_ms)
    values (target_project, me, in_start_ms, in_end_ms)
    returning id into made;
  exception when unique_violation then
    -- Two people pressed at once. One round started; this is the other.
    raise exception 'This song already has a round going.'
      using errcode = '22023';
  end;

  insert into public.loop_seats (round_id, user_id, place)
  select made, w.id, w.n::integer
  from unnest(wanted) with ordinality as w(id, n);

  starter := coalesce(
    (select m.display_name from public.room_members m
      where m.room_id = song.room_id and m.user_id = me),
    (select pr.display_name from public.profiles pr where pr.id = me),
    'Somebody'
  );
  first_up := private.loop_round_up(made);

  -- Everybody in the order is told once: the person who is up that it is
  -- their turn, everybody else that they are in it. Both say the one thing
  -- somebody put in an order without being asked needs to know.
  for person in select w.id from unnest(wanted) as w(id)
  loop
    if person.id is distinct from first_up then
      perform private.notify_user(
        person.id,
        'project_update',
        starter || ' started taking turns on ' || coalesce(song.title, 'a song'),
        'You are in the order. Skipping is free, and nobody is told.',
        song.room_id,
        song.id,
        null,
        me
      );
    end if;
  end loop;
  perform private.tell_whose_turn(made);

  return made;
end;
$fn$;

revoke all on function public.start_loop_round(uuid, integer, integer, uuid[])
  from public, anon;
grant execute on function public.start_loop_round(uuid, integer, integer, uuid[])
  to authenticated;

-- ---------------------------------------------------------------------
-- Joining, skipping, handing a turn in, ending it
-- ---------------------------------------------------------------------

-- "I'm in", and "count me back in": the end of the order, either way. A
-- seat that went quiet -- skipped, passed, or its take pulled -- moves to
-- the back rather than reopening where it was, so nobody's turn is taken
-- out from under them by somebody ahead of them changing their mind.
create or replace function public.join_loop_round(target_round uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  me uuid := auth.uid();
  the_round record;
  was_up uuid;
  mine record;
  last_place integer;
begin
  select r.id, r.ended_at, p.room_id into the_round
  from public.loop_rounds r
  join public.projects p on p.id = r.project_id
  where r.id = target_round and p.deleted_at is null
  for update of r;

  if the_round.id is null or not private.is_room_member(the_round.room_id) then
    raise exception 'No such round.' using errcode = '22023';
  end if;
  if coalesce(private.room_role_for(the_round.room_id)::text, '')
       not in ('owner', 'editor') then
    raise exception 'Only somebody who can record here can take a turn.'
      using errcode = '42501';
  end if;
  if the_round.ended_at is not null then
    raise exception 'That round is over.' using errcode = '22023';
  end if;

  perform private.settle_loop_round(target_round);
  was_up := private.loop_round_up(target_round);

  select s.state, s.layer_id into mine
  from public.loop_seats s
  where s.round_id = target_round and s.user_id = me;

  if found and private.loop_seat_state(mine.state, mine.layer_id) <> 'out' then
    return;
  end if;

  select coalesce(max(s.place), 0) into last_place
  from public.loop_seats s
  where s.round_id = target_round;

  insert into public.loop_seats as s (round_id, user_id, place)
  values (target_round, me, last_place + 1)
  on conflict (round_id, user_id) do update
    set place = excluded.place, state = 'waiting', layer_id = null;

  -- Nobody was up, so the person who just joined is: their turn starts now.
  if was_up is null then
    update public.loop_rounds set turn_since = now() where id = target_round;
  end if;
end;
$fn$;

revoke all on function public.join_loop_round(uuid) from public, anon;
grant execute on function public.join_loop_round(uuid) to authenticated;

-- Skip me. Any time, your turn or not, and nothing is said to anybody: the
-- next person is told it is their turn in the words they would have been
-- told anyway, and only when the turn actually moved. Skipping a seat that
-- is not waiting is not an error; there is nothing to skip and nothing to
-- say about it.
create or replace function public.skip_my_turn(target_round uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  me uuid := auth.uid();
  the_round record;
  was_up uuid;
begin
  select r.id, r.ended_at, p.room_id into the_round
  from public.loop_rounds r
  join public.projects p on p.id = r.project_id
  where r.id = target_round and p.deleted_at is null
  for update of r;

  if the_round.id is null or not private.is_room_member(the_round.room_id) then
    raise exception 'No such round.' using errcode = '22023';
  end if;
  if the_round.ended_at is not null then
    return;
  end if;

  perform private.settle_loop_round(target_round);
  was_up := private.loop_round_up(target_round);

  update public.loop_seats
  set state = 'out'
  where round_id = target_round and user_id = me and state = 'waiting';

  if not found then
    return;
  end if;

  if was_up is not distinct from me then
    update public.loop_rounds set turn_since = now() where id = target_round;
    perform private.tell_whose_turn(target_round);
  end if;
end;
$fn$;

revoke all on function public.skip_my_turn(uuid) from public, anon;
grant execute on function public.skip_my_turn(uuid) to authenticated;

-- Hands a take in as your turn. Yours, on this song, starting on the
-- passage, and only when the turn is yours. Handing it in shares it with
-- the room (0057): the next person has to hear it to answer it, and until
-- this moment it was a draft only its player could hear, to be recorded
-- again as many times as they liked. Sharing tells the room the way
-- sharing always has, and asks its player about strangers if the song is
-- already out (0155); neither is restated here.
create or replace function public.hand_in_my_turn(
  target_round uuid,
  target_layer uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  me uuid := auth.uid();
  the_round record;
  the_take record;
begin
  select r.id, r.project_id, r.start_ms, r.end_ms, r.ended_at, p.room_id
    into the_round
  from public.loop_rounds r
  join public.projects p on p.id = r.project_id
  where r.id = target_round and p.deleted_at is null
  for update of r;

  if the_round.id is null or not private.is_room_member(the_round.room_id) then
    raise exception 'No such round.' using errcode = '22023';
  end if;
  if the_round.ended_at is not null then
    raise exception 'That round is over.' using errcode = '22023';
  end if;

  perform private.settle_loop_round(target_round);

  -- 22023 and not 42501, because this is the one refusal here somebody can
  -- walk into honestly -- the turn passed while they were recording -- and
  -- the app reads 22023's sentence out and turns 42501 into "you don't have
  -- access".
  if private.loop_round_up(target_round) is distinct from me then
    raise exception 'It is not your turn yet.' using errcode = '22023';
  end if;

  select l.id, l.start_ms into the_take
  from public.song_layers l
  where l.id = target_layer
    and l.project_id = the_round.project_id
    and l.recorded_by = me;

  if the_take.id is null then
    raise exception 'That take is not yours to hand in.' using errcode = '42501';
  end if;
  if the_take.start_ms < the_round.start_ms
     or the_take.start_ms >= the_round.end_ms then
    raise exception 'That take is not on these bars.' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.loop_seats s where s.layer_id = target_layer
  ) then
    raise exception 'That take has already been a turn.' using errcode = '22023';
  end if;

  update public.song_layers
  set shared_at = now()
  where id = target_layer and shared_at is null;

  update public.loop_seats
  set state = 'played', layer_id = target_layer
  where round_id = target_round and user_id = me;

  update public.loop_rounds set turn_since = now() where id = target_round;
  perform private.tell_whose_turn(target_round);
end;
$fn$;

revoke all on function public.hand_in_my_turn(uuid, uuid) from public, anon;
grant execute on function public.hand_in_my_turn(uuid, uuid) to authenticated;

-- Ends it: whoever started it, or the room's owner. The turns stay on the
-- song as the takes they always were, and the round can still be heard.
-- Silent, like everything else here -- nobody is told a round ended with
-- their turn not taken.
create or replace function public.end_loop_round(target_round uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $fn$
declare
  me uuid := auth.uid();
  the_round record;
begin
  select r.id, r.started_by, p.room_id into the_round
  from public.loop_rounds r
  join public.projects p on p.id = r.project_id
  where r.id = target_round and p.deleted_at is null
  for update of r;

  if the_round.id is null or not private.is_room_member(the_round.room_id) then
    raise exception 'No such round.' using errcode = '22023';
  end if;
  if the_round.started_by is distinct from me
     and private.room_role_for(the_round.room_id) is distinct from 'owner' then
    raise exception 'Only whoever started the round, or the room''s owner, can end it.'
      using errcode = '42501';
  end if;

  update public.loop_rounds
  set ended_at = coalesce(ended_at, now())
  where id = target_round;
end;
$fn$;

revoke all on function public.end_loop_round(uuid) from public, anon;
grant execute on function public.end_loop_round(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Reading it
-- ---------------------------------------------------------------------

-- The rounds on a song, newest first, for somebody in its room; nothing at
-- all for anybody else. Each carries the order as names and words: the
-- seats that are waiting or played, in order, and the caller's own seat
-- whatever state it is in. A seat that went quiet is simply not in anybody
-- else's list -- no gap, no mark, no place number to count the gaps with.
--
-- `started_at` is there so the app can tell a draft recorded for this round
-- from an older take on the same bars. It is not shown to anybody.
--
-- Not `stable`: it runs the quiet pass first, which may move a turn.
create or replace function public.loop_rounds_for(target_project uuid)
returns table (
  id uuid,
  start_ms integer,
  end_ms integer,
  started_by uuid,
  started_by_name text,
  started_at timestamptz,
  ended boolean,
  up uuid,
  seats jsonb
)
language plpgsql
security definer
set search_path = ''
as $fn$
#variable_conflict use_column
declare
  me uuid := auth.uid();
  song record;
  going uuid;
begin
  select p.id, p.room_id into song
  from public.projects p
  where p.id = target_project and p.deleted_at is null;

  if song.id is null or not private.is_room_member(song.room_id) then
    return;
  end if;

  select r.id into going
  from public.loop_rounds r
  where r.project_id = target_project and r.ended_at is null;

  if going is not null then
    perform private.settle_loop_round(going);
  end if;

  return query
  select
    r.id,
    r.start_ms,
    r.end_ms,
    r.started_by,
    coalesce(sm.display_name, sp.display_name, 'Somebody'),
    r.created_at,
    r.ended_at is not null,
    private.loop_round_up(r.id),
    coalesce(
      (select jsonb_agg(
                jsonb_build_object(
                  'id', s.user_id,
                  'name', coalesce(m.display_name, pr.display_name, 'Somebody'),
                  'state', private.loop_seat_state(s.state, s.layer_id),
                  'layer_id', case
                    when private.loop_seat_state(s.state, s.layer_id) = 'played'
                      then s.layer_id
                  end
                )
                order by s.place
              )
         from public.loop_seats s
         left join public.room_members m
           on m.room_id = song.room_id and m.user_id = s.user_id
         left join public.profiles pr on pr.id = s.user_id
        where s.round_id = r.id
          and (
            s.user_id = me
            or private.loop_seat_state(s.state, s.layer_id) <> 'out'
          )),
      '[]'::jsonb
    )
  from public.loop_rounds r
  left join public.room_members sm
    on sm.room_id = song.room_id and sm.user_id = r.started_by
  left join public.profiles sp on sp.id = r.started_by
  where r.project_id = target_project
  order by r.created_at desc
  limit 12;
end;
$fn$;

revoke all on function public.loop_rounds_for(uuid) from public, anon;
grant execute on function public.loop_rounds_for(uuid) to authenticated;
