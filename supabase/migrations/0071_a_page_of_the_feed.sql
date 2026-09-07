-- Everything one screen of the feed needs, in one call.
--
-- The listening surface is a different shape of query from every other one in
-- this app. A workspace opens one song and can afford a round trip per thing
-- it needs; a feed is playing the current track while fetching the next and
-- cannot. So this returns the page *and* the storage path of the audio, so
-- the client can sign a batch of URLs and start streaming without going back
-- to ask where anything lives.
--
-- **Keyset pagination, not offset.** The feed is ordered by when a song went
-- up, and songs go up while somebody is scrolling. An offset would show them
-- a track twice or skip one entirely every time that happened; a cursor on
-- the timestamp cannot.
--
-- **The reference recording, or failing that the first take anybody shared.**
-- A song has many takes and a feed needs exactly one thing to play, so the
-- reference — the recording the whole song sheet was made from — is the first
-- choice, being the closest thing this app has to "the song" as one object.
--
-- But requiring it would quietly exclude somebody who opened the app, sang
-- into their phone, and shared it. They have audio; they just never made a
-- song sheet from it. A feed that only carries finished work is a feed for
-- people who are already finished, and the whole point of this one is that a
-- bedroom recording and a mastered mix sit in the same scroll. So a shared
-- take counts, and the song appears with whatever it actually has.

create or replace function public.open_mic_feed(
  in_after timestamptz default null,
  in_limit integer default 12,
  in_part text default null
)
returns table (
  id uuid,
  title text,
  owner_id uuid,
  owner_name text,
  owner_avatar text,
  open_mic_at timestamptz,
  asking_for text[],
  ask_note text,
  musical_key text,
  bpm double precision,
  duration_ms integer,
  -- What to play. The client turns this into a signed URL in one batch for
  -- the whole page, which is what makes preloading the next track possible.
  storage_path text
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
    pr.avatar_path,
    p.open_mic_at,
    coalesce(
      (select array_agg(distinct a.part)
         from public.project_asks a
        where a.project_id = p.id
          and a.status = 'open'
          and a.part is not null),
      '{}'::text[]
    ),
    coalesce(
      (select a.note from public.project_asks a
        where a.project_id = p.id and a.status = 'open'
          and char_length(trim(a.note)) > 0
        order by a.created_at desc limit 1),
      ''
    ),
    r.musical_key,
    r.bpm,
    coalesce(r.duration_ms, take.duration_ms),
    coalesce(f.storage_path, take.storage_path)
  from public.projects p
  left join public.project_audio_references r on r.project_id = p.id
  left join public.files f on f.id = r.file_id
  left join lateral (
    -- The earliest thing the room actually heard. Only shared takes: a feed
    -- must never be the surface that publishes somebody's private draft.
    select l.storage_path, l.duration_ms
    from public.song_layers l
    where l.project_id = p.id and l.shared_at is not null
    order by l.shared_at
    limit 1
  ) take on true
  left join public.profiles pr on pr.id = p.created_by
  where p.open_mic_at is not null
    and p.deleted_at is null
    -- Nothing silent. A card in a listening feed with nothing to play is
    -- worse than a shorter feed.
    and coalesce(f.storage_path, take.storage_path) is not null
    and not private.blocked_between((select auth.uid()), p.created_by)
    and (in_after is null or p.open_mic_at < in_after)
    and (
      in_part is null
      or exists (
        select 1 from public.project_asks a
        where a.project_id = p.id and a.status = 'open' and a.part = in_part
      )
    )
  order by p.open_mic_at desc
  limit greatest(least(in_limit, 40), 1);
$$;

revoke all on function public.open_mic_feed(timestamptz, integer, text)
  from public, anon;
grant execute on function public.open_mic_feed(timestamptz, integer, text)
  to authenticated;
