-- The dial did not know about the showcase.
--
-- 0088 added a second public surface and `song_audience` still only knew
-- about the first, so a song on the showcase reported its reach as whatever
-- its room membership said — "Only you", for a solo writer who had just
-- published finished work to everybody.
--
-- The control whose entire job is answering "who can hear this" was giving
-- the wrong answer for the newest way to be heard, one day after shipping.

drop function if exists public.song_audience(uuid);

create function public.song_audience(target_project uuid)
returns table (
  reach text,
  room_name text,
  room_icon text,
  listeners jsonb,
  on_open_mic boolean,
  on_showcase boolean,
  open_mic_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $fn$
  with the_song as (
    select p.id, p.room_id, p.open_mic_at, p.showcased_at, p.created_by
    from public.projects p
    where p.id = target_project
      and p.deleted_at is null
      and (
        private.is_room_member(p.room_id)
        or private.is_project_member(p.id)
      )
  ),
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
      -- Either public surface is "anyone". Showing finished work reaches
      -- exactly as far as the Open Mic does, and a dial that said otherwise
      -- would be understating reach — the one direction it must never err in.
      when s.open_mic_at is not null or s.showcased_at is not null
        then 'anyone'
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
    s.showcased_at is not null,
    s.open_mic_at
  from the_song s
  left join public.rooms r on r.id = s.room_id;
$fn$;

revoke all on function public.song_audience(uuid) from public, anon;
grant execute on function public.song_audience(uuid) to authenticated;
