-- Who can hear this?
--
-- No screen in this app answers that question. Not the song, not the list,
-- not the workspace. The only sentence about privacy anywhere in a song's
-- interface is one line inside the confirmation dialog for putting it on the
-- Open Mic.
--
-- Meanwhile a song's audience is decided by four separate mechanisms:
--
--   * which room it lives in, and who is a member of that room
--   * per-song invitations, from an item in an overflow menu
--   * `open_mic_at`, from another item in the same overflow menu
--   * per-take `shared_at`
--
-- Four mechanisms and no indicator. For an app whose whole promise is a safe
-- place to work on something unfinished and put it out when you are ready,
-- that is the gap: nobody can feel safe about something they cannot see.
--
-- **The four spaces are one gradient.** Alone, with your band, with somebody
-- you asked, in front of everybody. That is not a metaphor laid over the
-- schema — it *is* the schema, and it has simply never been drawn. This
-- function reads it back as a single answer so one control can show it.
--
-- Derived rather than stored, deliberately. A `reach` column would be a
-- second source of truth that drifts the first time somebody is removed from
-- a room, and the honest answer is always "whoever the memberships currently
-- say", computed now.

create or replace function public.song_audience(target_project uuid)
returns table (
  -- 'just_you' | 'room' | 'invited' | 'anyone', widest thing that is true.
  reach text,
  room_name text,
  room_icon text,
  -- Everybody who can hear it apart from you, named, so the control can show
  -- faces rather than a count. A count alone answers "how many" when the
  -- question people actually ask is "who".
  listeners jsonb,
  on_open_mic boolean,
  open_mic_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $fn$
  with the_song as (
    select p.id, p.room_id, p.open_mic_at, p.created_by
    from public.projects p
    where p.id = target_project
      and p.deleted_at is null
      -- Only somebody who can already open the song may ask about it. The
      -- membership of a room you are not in is not yours to enumerate.
      and (
        private.is_room_member(p.room_id)
        or private.is_project_member(p.id)
      )
  ),
  -- The room, and the people invited to this one song. Union, because
  -- somebody can be both and is still one person who can hear it.
  hearers as (
    select m.user_id, pr.display_name, pr.avatar_path, false as song_only
    from public.room_members m
    join the_song s on s.room_id = m.room_id
    left join public.profiles pr on pr.id = m.user_id
    union
    select pm.user_id, pr.display_name, pr.avatar_path, true
    from public.project_members pm
    join the_song s on s.id = pm.project_id
    left join public.profiles pr on pr.id = pm.user_id
    where not exists (
      select 1 from public.room_members m2
      join the_song s2 on s2.room_id = m2.room_id
      where m2.user_id = pm.user_id
    )
  ),
  others as (
    select * from hearers where user_id is distinct from (select auth.uid())
  )
  select
    case
      when s.open_mic_at is not null then 'anyone'
      when exists (select 1 from others where song_only) then 'invited'
      when exists (select 1 from others) then 'room'
      else 'just_you'
    end,
    r.name,
    r.icon,
    coalesce(
      (select jsonb_agg(
                jsonb_build_object(
                  'id', o.user_id,
                  'name', coalesce(o.display_name, 'Somebody'),
                  'avatar_path', o.avatar_path,
                  'song_only', o.song_only
                )
                order by o.song_only, coalesce(o.display_name, 'Somebody')
              )
         from others o),
      '[]'::jsonb
    ),
    s.open_mic_at is not null,
    s.open_mic_at
  from the_song s
  left join public.rooms r on r.id = s.room_id;
$fn$;

revoke all on function public.song_audience(uuid) from public, anon;
grant execute on function public.song_audience(uuid) to authenticated;
