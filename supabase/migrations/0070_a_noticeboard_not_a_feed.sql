-- The Open Mic is a noticeboard, not a feed.
--
-- Two different things were sharing one shelf, and mixing them made the shelf
-- read as a place to dump work rather than a place to ask for help.
--
--   * **What you are proud of** belongs on your profile. Curated, permanent,
--     and it says what your style and standard are. `songs_by` already does
--     this and is unchanged.
--   * **What genuinely needs somebody** belongs on the Open Mic. Specific,
--     and it resolves the moment it is answered.
--
-- Collapsing those made "fill the Open Mic" look like the answer to an empty
-- room, which is exactly backwards: an app that pressures people to publish
-- work they are not ready to show stops being a safe place to write in, and
-- the safety is the reason anybody ever shows anything.
--
-- **So an empty Open Mic is a healthy state.** A feed with nothing in it is
-- broken; a noticeboard with nothing on it means nobody needs anything today.
-- Those read completely differently to a person and the app should not
-- confuse them.
--
-- Putting a song up still does both — it appears on your profile *and* it can
-- carry an ask. This only changes what the browse surface leads with.

create or replace function public.open_mic_songs(
  in_part text default null,
  in_limit integer default 30,
  -- Off by default: the noticeboard shows what is being asked for. Passing
  -- true is "show me everything anybody has put up", which is a different
  -- and much less useful question.
  include_not_asking boolean default false
)
returns table (
  id uuid,
  title text,
  owner_id uuid,
  owner_name text,
  open_mic_at timestamptz,
  take_count bigint,
  asking_for text[]
)
language sql
stable
security definer
set search_path = public
as $$
  select
    p.id,
    p.title,
    p.created_by,
    pr.display_name,
    p.open_mic_at,
    (select count(*) from public.song_layers l
      where l.project_id = p.id and l.shared_at is not null),
    coalesce(
      (select array_agg(distinct a.part)
         from public.project_asks a
        where a.project_id = p.id
          and a.status = 'open'
          and a.part is not null),
      '{}'::text[]
    )
  from public.projects p
  left join public.profiles pr on pr.id = p.created_by
  where p.open_mic_at is not null
    and p.deleted_at is null
    and not private.blocked_between((select auth.uid()), p.created_by)
    and (
      in_part is null
      or exists (
        select 1 from public.project_asks a
        where a.project_id = p.id and a.status = 'open' and a.part = in_part
      )
    )
    and (
      include_not_asking
      or exists (
        select 1 from public.project_asks a
        where a.project_id = p.id and a.status = 'open'
      )
    )
  order by p.open_mic_at desc
  limit greatest(least(in_limit, 100), 1);
$$;

revoke all on function public.open_mic_songs(text, integer, boolean)
  from public, anon;
grant execute on function public.open_mic_songs(text, integer, boolean)
  to authenticated;

-- The old three-argument signature would otherwise sit alongside the new one
-- and get picked by anything still calling it, which is how a filter quietly
-- fails to apply.
drop function if exists public.open_mic_songs(text, integer);
