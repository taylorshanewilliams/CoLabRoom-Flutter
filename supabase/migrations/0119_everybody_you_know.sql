-- Everybody you know.
--
-- Taylor, 15 Sep: "a way to see all your friends, band mates, connections,
-- people you collaborating with etc in one place, whos online".
--
-- The People screen already lists your connections and, under "people you
-- already work with", whoever shares a room with you (0101). Two gaps:
-- it did not know who you had *played* with -- somebody who recorded on a
-- song of yours through an ask is a collaborator without being a room-mate
-- -- and it could not say whether the app would let you write to them.
--
-- So people_you_might_add grows: room-mates first, named with the rooms
-- you share; then people who recorded on a song you are in, or on a song
-- you recorded on; and a can_message column that says what may_tell (0102)
-- will say, so a screen can show the message button only where it works.
-- The return shape changes, so the function is dropped and made again.

drop function if exists public.people_you_might_add();

create function public.people_you_might_add()
returns table (
  person_id uuid,
  display_name text,
  avatar_path text,
  because text,
  can_message boolean
)
language sql
security definer set search_path = ''
stable
as $fn$
  with me as (select auth.uid() as id),
  mine as (
    select case when c.requester_id = (select id from me) then c.addressee_id else c.requester_id end as id
    from public.connections c
    where (select id from me) in (c.requester_id, c.addressee_id)
  ),
  blocked as (
    select b.blocked_id as id from public.user_blocks b where b.blocker_id = (select id from me)
    union
    select b.blocker_id from public.user_blocks b where b.blocked_id = (select id from me)
  ),
  roommates as (
    select m2.user_id as id,
           string_agg(r.name, ', ' order by r.name) as rooms
    from public.room_members m1
    join public.room_members m2 on m2.room_id = m1.room_id
    join public.rooms r on r.id = m1.room_id
    where m1.user_id = (select id from me) and m2.user_id <> (select id from me)
    group by m2.user_id
  ),
  -- Songs you are on: in one of your rooms, or one you recorded on.
  my_songs as (
    select p.id
    from public.projects p
    join public.room_members rm on rm.room_id = p.room_id
    where rm.user_id = (select id from me)
    union
    select l.project_id from public.song_layers l where l.recorded_by = (select id from me)
  ),
  played as (
    select l.recorded_by as id, count(distinct l.project_id) as songs
    from public.song_layers l
    where l.project_id in (select id from my_songs)
      and l.recorded_by <> (select id from me)
    group by l.recorded_by
  ),
  candidates as (
    select r.id,
           'In ' || r.rooms || ' with you' as because,
           true as can_message,
           0 as rank
    from roommates r
    union all
    select pl.id,
           case when pl.songs = 1 then 'Played on a song with you'
                else 'Played on ' || pl.songs || ' songs with you' end,
           false,
           1
    from played pl
    where pl.id not in (select id from roommates)
  )
  select distinct on (c.id) c.id, p.display_name, p.avatar_path, c.because, c.can_message
  from candidates c
  join public.profiles p on p.id = c.id
  where c.id not in (select id from mine)
    and c.id not in (select id from blocked)
  order by c.id, c.rank;
$fn$;

revoke all on function public.people_you_might_add() from public, anon;
grant execute on function public.people_you_might_add() to authenticated;
