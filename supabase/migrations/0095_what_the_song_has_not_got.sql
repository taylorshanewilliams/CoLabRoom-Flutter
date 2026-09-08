-- What the song has not got.
--
-- The ask sheet asks three questions: which song, what for, anything to say.
-- The first is preselected, the third is optional, and the second is a row of
-- sixteen chips starting on nothing — which is the app asking somebody to
-- tell it a thing it is in a better position to know than they are.
--
-- It knows what has been played on the song. It knows what this person does.
-- The overlap of "what they play" and "what this song does not have" is a
-- very good guess at why one of them is looking at the other.
--
-- **The honest version of that is narrow, and the honest version is what this
-- returns.** The app cannot know what a song *needs* — need is a musical
-- judgement and the list of things somebody might want is unbounded, so a
-- column called `missing` would be a claim it has no standing to make. What
-- it can say without inventing anything is what is *on* it. The inference
-- from there is one small step, taken in the client where it can be seen:
-- offer the thing this person does that the song has not got.
--
-- Which leaves the person asking with the common case already chosen and
-- every other case one tap away, instead of a decision the app made them
-- type out for the third time in three screens.

-- Dropped first — `create or replace` cannot change a `returns table` shape.
-- Sixth time. It is in the file every time because it is the failure that
-- looks like a typo and is not.
drop function if exists public.songs_i_can_offer(uuid);

create function public.songs_i_can_offer(target_person uuid)
returns table (
  id uuid,
  title text,
  updated_at timestamptz,
  already_asked boolean,

  -- What has been played on it, as stored role strings. Shared takes only:
  -- a private take is somebody working, and a song is not "already got
  -- drums" because a draft of some drums exists in one person's library.
  parts_on_it text[]
)
language sql
stable
security definer
set search_path = public
as $$
  select
    p.id,
    p.title,
    p.updated_at,
    exists (
      select 1 from public.project_asks a
      where a.project_id = p.id
        and a.asked_of = target_person
        and a.status = 'open'
    ),
    coalesce(
      (select array_agg(distinct l.part::text)
         from public.song_layers l
        where l.project_id = p.id
          and l.shared_at is not null
          and l.part is not null),
      '{}'::text[]
    )
  from public.projects p
  where private.is_room_member(p.room_id) or private.is_project_member(p.id)
  order by p.updated_at desc
  limit 100;
$$;

revoke all on function public.songs_i_can_offer(uuid) from public, anon;
grant execute on function public.songs_i_can_offer(uuid) to authenticated;
