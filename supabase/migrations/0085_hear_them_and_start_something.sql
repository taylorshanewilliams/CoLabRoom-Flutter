-- Hear them, and start something.
--
-- Two things the Open Mic could not do, and both are the same complaint:
-- meeting somebody takes too many steps for something that should feel like
-- one.
--
-- **You cannot hear a person from the list.** Their card carries a name, a
-- city, what they play and what you have in common — everything except the
-- one thing anybody actually judges a musician on. Deciding whether to work
-- with somebody is done by ear in about ten seconds, and doing it meant
-- opening their profile, finding a song, and pressing play.
--
-- **And meeting somebody leads nowhere.** You can ask them onto a song you
-- already have, which is the right move when you have one — and no move at
-- all for "I like this person, let us make something". That path was: go
-- back, make a room, name it, make a song, name that, invite them, wait.
-- Six deliberate acts to act on an impulse.

-- ---------------------------------------------------------------------
-- One song each, so a list can be listened to
-- ---------------------------------------------------------------------

-- The newest thing of theirs anybody can hear.
--
-- Only songs on the Open Mic, which is the whole set of things they have
-- chosen to be heard on — so this can never surface a private room's work,
-- and it needs no permission check of its own beyond the one already in the
-- flag. Theirs or played on: a bass player who has never written a song is
-- exactly who this list is for, and owning nothing must not mean sounding
-- like nothing.
create or replace function private.heard_from(target_profile uuid)
returns table (
  song_id uuid,
  title text,
  storage_path text,
  duration_ms integer
)
language sql
stable
security definer
set search_path = public
as $fn$
  select p.id, p.title, audio.storage_path, audio.duration_ms
  from public.projects p
  left join lateral private.song_audio(p.id) audio on true
  where p.open_mic_at is not null
    and p.deleted_at is null
    and audio.storage_path is not null
    and (
      p.created_by = target_profile
      or exists (
        select 1 from public.song_layers l
        where l.project_id = p.id
          and l.recorded_by = target_profile
          and l.shared_at is not null
      )
    )
  order by p.open_mic_at desc
  limit 1;
$fn$;

revoke all on function private.heard_from(uuid)
  from public, anon, authenticated;

drop function if exists public.find_musicians(text[], text, integer, text);

create function public.find_musicians(
  in_parts text[] default null,
  in_city text default null,
  in_limit integer default 30,
  in_sounds_like text default null
)
returns table (
  id uuid,
  display_name text,
  avatar_path text,
  city text,
  plays text[],
  sounds_like text[],
  parts_recorded jsonb,
  songs_played_on bigint,
  people_worked_with bigint,
  shared_sounds text[],
  is_demo boolean,
  matched_parts text[],
  -- Something of theirs to play, right there on the card.
  heard_song uuid,
  heard_title text,
  heard_path text,
  heard_duration integer
)
language sql
stable
security definer
set search_path = public
as $fn$
  with me as (
    select p.sounds_like from public.profiles p where p.id = (select auth.uid())
  ),
  wanted as (
    select array(
      select distinct lower(trim(t))
      from unnest(coalesce(in_parts, '{}'::text[])) as t
      where char_length(trim(t)) > 0
    ) as parts
  )
  select
    p.id,
    p.display_name,
    p.avatar_path,
    case when p.location_visibility = 'public' then p.city else null end,
    p.plays,
    p.sounds_like,
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
    coalesce(shared.tags, '{}'::text[]),
    p.is_demo,
    coalesce(fit.parts, '{}'::text[]),
    heard.song_id,
    heard.title,
    heard.storage_path,
    heard.duration_ms
  from public.profiles p
  cross join lateral (
    select array_agg(t) as tags
    from unnest(p.sounds_like) as t
    where t = any(coalesce((select m.sounds_like from me m), '{}'::text[]))
  ) shared
  cross join lateral (
    select array_agg(distinct w) as parts
    from unnest((select parts from wanted)) as w
    where w = any(p.plays)
       or exists (
         select 1 from public.song_layers l
         where l.recorded_by = p.id
           and l.shared_at is not null
           and l.part::text = w
       )
  ) fit
  left join lateral private.heard_from(p.id) heard on true
  where p.discoverable
    and not private.blocked_between((select auth.uid()), p.id)
    and (
      coalesce(array_length((select parts from wanted), 1), 0) = 0
      or coalesce(array_length(fit.parts, 1), 0) > 0
    )
    and (
      in_city is null
      or (p.location_visibility = 'public'
          and lower(trim(p.city)) = lower(trim(in_city)))
    )
    and (
      in_sounds_like is null
      or lower(trim(in_sounds_like)) = any(p.sounds_like)
    )
  order by
    coalesce(array_length(fit.parts, 1), 0) desc,
    case when coalesce(array_length(shared.tags, 1), 0) > 0 then 0 else 1 end,
    md5(p.id::text || current_date::text)
  limit greatest(least(in_limit, 100), 1);
$fn$;

revoke all on function public.find_musicians(text[], text, integer, text)
  from public, anon;
grant execute on function public.find_musicians(text[], text, integer, text)
  to authenticated;

-- The compatibility shim from 0084 delegates to the above and has to be
-- rebuilt with it, or it returns the old column list and fails on the join.
--
-- Dropped first. `create or replace` cannot change the shape of a
-- `returns table`, which has now caught this project in 0073, 0076, 0079 and
-- here — every migration that grows a column on an existing function.
drop function if exists public.find_musicians(text, text, integer, text);

create function public.find_musicians(
  in_part text default null,
  in_city text default null,
  in_limit integer default 30,
  in_sounds_like text default null
)
returns table (
  id uuid,
  display_name text,
  avatar_path text,
  city text,
  plays text[],
  sounds_like text[],
  parts_recorded jsonb,
  songs_played_on bigint,
  people_worked_with bigint,
  shared_sounds text[],
  is_demo boolean,
  matched_parts text[],
  heard_song uuid,
  heard_title text,
  heard_path text,
  heard_duration integer
)
language sql
stable
security definer
set search_path = public
as $fn$
  select *
  from public.find_musicians(
    case
      when in_part is null or char_length(trim(in_part)) = 0 then null
      else array[lower(trim(in_part))]
    end,
    in_city,
    in_limit,
    in_sounds_like
  );
$fn$;

revoke all on function public.find_musicians(text, text, integer, text)
  from public, anon;
grant execute on function public.find_musicians(text, text, integer, text)
  to authenticated;

-- ---------------------------------------------------------------------
-- Starting something with somebody
-- ---------------------------------------------------------------------

-- A room, a first song, and an invitation, in one call.
--
-- **They are invited, not added.** Every other door in this app waits for a
-- yes, and this one does too: the room is yours until they accept, and they
-- see an invitation rather than finding themselves in a room somebody put
-- them in. That is the difference between meeting somebody and being
-- assigned to them.
--
-- The name has to be unique per account, so a second attempt with the same
-- person does not fail with a constraint error — it counts up. Two people
-- who keep starting things together is the good case, not an error state.
create or replace function public.start_something_with(
  target_profile uuid,
  in_note text default ''
)
-- The output columns are `made_room` and `made_song` rather than `room_id`
-- and `project_id`, because in plpgsql a `returns table` name is a variable
-- for the whole body — and `on conflict (room_id, user_id)` below is then an
-- ambiguous reference between that variable and the actual column. Naming
-- them something no table has is simpler than fighting it.
returns table (made_room uuid, made_song uuid)
language plpgsql
security definer
set search_path = public
as $fn$
declare
  me uuid := auth.uid();
  my_name text;
  their_name text;
  base text;
  candidate text;
  attempt integer := 1;
  new_room uuid;
  new_project uuid;
  song_title text;
begin
  if target_profile = me then
    raise exception 'You cannot start something with yourself.'
      using errcode = '22023';
  end if;
  if private.blocked_between(me, target_profile) then
    raise exception 'That is not possible.' using errcode = '42501';
  end if;

  select display_name into my_name from public.profiles where id = me;
  select display_name into their_name
  from public.profiles where id = target_profile;
  if their_name is null then
    raise exception 'No such person.' using errcode = '22023';
  end if;

  -- First names, because "Taylor Williams & Mara Ellison" is a legal document
  -- and "Taylor & Mara" is a band.
  base := split_part(coalesce(my_name, 'Me'), ' ', 1) || ' & ' ||
          split_part(their_name, ' ', 1);
  candidate := base;
  while exists (
    select 1 from public.rooms r
    where r.account_id = me
      and lower(regexp_replace(trim(r.name), '\s+', ' ', 'g'))
        = lower(regexp_replace(trim(candidate), '\s+', ' ', 'g'))
  ) loop
    attempt := attempt + 1;
    candidate := base || ' ' || attempt;
  end loop;

  insert into public.rooms (account_id, name, icon)
  values (me, candidate, '✨')
  returning id into new_room;

  -- The owner row is written the way the app writes it, rather than trusting
  -- a trigger: 0047's colour trigger fills in the rest.
  insert into public.room_members (room_id, user_id, display_name, role)
  values (new_room, me, coalesce(my_name, 'Member'), 'owner')
  on conflict (room_id, user_id) do nothing;

  -- A song to land in, so the room is not an empty container somebody has to
  -- fill before anything can happen.
  song_title := 'Something with ' || split_part(their_name, ' ', 1);
  attempt := 1;
  while exists (
    select 1 from public.projects p
    where p.account_id = me
      and lower(regexp_replace(trim(p.title), '\s+', ' ', 'g'))
        = lower(regexp_replace(trim(song_title), '\s+', ' ', 'g'))
  ) loop
    attempt := attempt + 1;
    song_title := 'Something with ' || split_part(their_name, ' ', 1)
      || ' ' || attempt;
  end loop;

  insert into public.projects (room_id, account_id, created_by, title)
  values (new_room, me, me, song_title)
  returning id into new_project;

  perform public.invite_musician_to_room(new_room, target_profile, in_note);

  return query select new_room, new_project;
end;
$fn$;

revoke all on function public.start_something_with(uuid, text)
  from public, anon;
grant execute on function public.start_something_with(uuid, text)
  to authenticated;
