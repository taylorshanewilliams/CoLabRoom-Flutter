-- Telling somebody, on purpose.
--
-- Taylor: "you could notify indivudual users direcctly to there phone that
-- you uploaded something, changed something, etc...or if you want to notify
-- the whole room, you could do that."
--
-- Everything this app has notified anybody about until now has been automatic
-- -- a trigger noticing an invite, an ask, a finished analysis. Useful, and
-- not the same thing as a person deciding somebody should hear this. A band
-- works in bursts: you put a take up on Tuesday and it matters that the bass
-- player knows on Tuesday, not whenever they next happen to open the app.
--
-- Rules, because a notify button is a way to be a nuisance:
--
--   You may only tell somebody you are actually connected to or share a room
--   with. Not anybody whose id you happen to hold.
--
--   Three per song per hour, counted across both kinds. Enough to say "new
--   take up" and then "sorry, that was the wrong one"; not enough to be a
--   megaphone.
--
--   Never yourself, and never somebody who has blocked you or whom you have
--   blocked -- checked both ways, and saying the same thing either way, so a
--   block cannot be detected by the error it produces.

-- Can I tell this person anything at all?
create or replace function public.may_tell(other_id uuid)
returns boolean
language sql
security definer set search_path = ''
stable
as $fn$
  select
    other_id is distinct from auth.uid()
    and not exists (
      select 1 from public.user_blocks b
      where (b.blocker_id = auth.uid() and b.blocked_id = other_id)
         or (b.blocker_id = other_id and b.blocked_id = auth.uid())
    )
    and (
      exists (
        select 1 from public.connections c
        where c.state = 'accepted'
          and ((c.requester_id = auth.uid() and c.addressee_id = other_id)
            or (c.requester_id = other_id and c.addressee_id = auth.uid()))
      )
      or exists (
        select 1
        from public.room_members mine
        join public.room_members theirs on theirs.room_id = mine.room_id
        where mine.user_id = auth.uid() and theirs.user_id = other_id
      )
    );
$fn$;

revoke all on function public.may_tell(uuid) from public, anon;
grant execute on function public.may_tell(uuid) to authenticated;

-- Say something about a song, to one person or to the room it lives in.
--
-- `in_targets` null or empty means everybody in the room. Otherwise it is
-- however many people were picked -- one, three, or the two who play strings.
-- A band does not divide neatly into "one person" and "all of them", and
-- making somebody send the same message four times to reach four people is
-- the kind of thing that stops them telling anybody.
--
-- Returns how many were actually told, which is the honest answer to "did
-- that work": a list where everybody has blocked you tells nobody, and the
-- button should not claim otherwise.
create or replace function public.tell_about_song(
  in_project uuid,
  in_note text default null,
  in_targets uuid[] default null
)
returns integer
language plpgsql
security definer set search_path = ''
as $fn$
declare
  me uuid := auth.uid();
  my_name text;
  song record;
  recent integer;
  told integer := 0;
  clean_note text;
  body_text text;
begin
  if me is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;

  -- Read under the caller's own reach rather than the definer's: a song you
  -- cannot see is a song you cannot tell anybody about.
  select p.id, p.title, p.room_id into song
  from public.projects p
  where p.id = in_project
    and exists (
      select 1 from public.room_members m
      where m.room_id = p.room_id and m.user_id = me
    );
  if not found then
    raise exception 'That song is not yours to share.' using errcode = '42501';
  end if;

  select count(*) into recent
  from public.notifications
  where actor_id = me
    and project_id = in_project
    and created_at > now() - interval '1 hour';
  if recent >= 3 then
    raise exception 'You have told people about this song a few times '
      || 'already. Try again in a little while.' using errcode = '53400';
  end if;

  select coalesce(display_name, 'Somebody') into my_name
  from public.profiles where id = me;

  clean_note := nullif(left(coalesce(trim(in_note), ''), 140), '');
  body_text := coalesce(clean_note, 'Have a listen when you get a minute.');

  if in_targets is null or cardinality(in_targets) = 0 then
    -- The room. Everybody in it except you, and except anybody the block
    -- rules exclude.
    insert into public.notifications
      (user_id, type, title, body, room_id, project_id, actor_id)
    select m.user_id, 'project_update', my_name || ' about ' || song.title,
           body_text, song.room_id, song.id, me
    from public.room_members m
    where m.room_id = song.room_id
      and m.user_id <> me
      and not exists (
        select 1 from public.user_blocks b
        where (b.blocker_id = me and b.blocked_id = m.user_id)
           or (b.blocker_id = m.user_id and b.blocked_id = me)
      );
    get diagnostics told = row_count;
    return told;
  end if;

  -- Filtered rather than refused. One id in a list of six that has since
  -- been blocked should cost that one person, not the whole message -- and
  -- the count that comes back says how many it actually reached.
  insert into public.notifications
    (user_id, type, title, body, room_id, project_id, actor_id)
  select t, 'project_update', my_name || ' about ' || song.title,
         body_text, song.room_id, song.id, me
  from unnest(in_targets) as t
  where public.may_tell(t);

  get diagnostics told = row_count;
  return told;
end;
$fn$;

revoke all on function public.tell_about_song(uuid, text, uuid[]) from public, anon;
grant execute on function public.tell_about_song(uuid, text, uuid[]) to authenticated;

-- Who can be told about this song, with the reason each of them is on the
-- list, so the sheet can say it.
create or replace function public.people_to_tell(in_project uuid)
returns table (
  person_id uuid,
  display_name text,
  avatar_path text,
  because text
)
language sql
security definer set search_path = ''
stable
as $fn$
  with song as (
    select p.id, p.room_id
    from public.projects p
    where p.id = in_project
      and exists (
        select 1 from public.room_members m
        where m.room_id = p.room_id and m.user_id = auth.uid()
      )
  ),
  candidates as (
    select m.user_id as id, 'In this room'::text as because, 0 as rank
    from public.room_members m
    join song on song.room_id = m.room_id
    where m.user_id <> auth.uid()
    union
    select case when c.requester_id = auth.uid() then c.addressee_id
                else c.requester_id end,
           'One of your people'::text, 1
    from public.connections c
    where c.state = 'accepted'
      and auth.uid() in (c.requester_id, c.addressee_id)
  ),
  best as (
    select distinct on (id) id, because
    from candidates
    order by id, rank
  )
  select b.id, p.display_name, p.avatar_path, b.because
  from best b
  join public.profiles p on p.id = b.id
  where public.may_tell(b.id)
  order by b.because, p.display_name;
$fn$;

revoke all on function public.people_to_tell(uuid) from public, anon;
grant execute on function public.people_to_tell(uuid) to authenticated;
