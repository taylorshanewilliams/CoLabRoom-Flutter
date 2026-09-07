-- Every list makes a sound.
--
-- The Open Mic could not play anything. Not the list of songs, not a
-- person's profile, not the public page for a single song. Three surfaces
-- built to help somebody decide whether they want to work on a piece of
-- music, and none of them could let you hear it — the judgement they exist
-- to support is made by ear in about ten seconds, and every one of them
-- asked you to make it by reading a title.
--
-- The cause was here rather than in the app. `open_mic_songs`, `songs_by`
-- and `open_mic_song` return a title, an owner and what the song is asking
-- for, and never returned **where the audio lives**. The client could not
-- have played them if it wanted to; there was nothing to sign.
--
-- `open_mic_feed` already knew the rule, written out inline in 0071. Copying
-- it into three more places would mean four copies of the answer to "what
-- does this song sound like", which drift apart the first time one of them
-- is fixed. So the rule moves into one function and the four callers ask it.
--
-- **Nothing new becomes audible.** Every one of these already required
-- `open_mic_at is not null` — a song its owner deliberately put up — and the
-- take fallback already refused anything without `shared_at`. This adds a
-- column to rows the caller was being handed anyway. The permission check is
-- not here in any case: `storage.objects` decides at signing time, so a path
-- returned to somebody who may not hear it never becomes a URL.

-- ---------------------------------------------------------------------
-- What a song sounds like, decided once
-- ---------------------------------------------------------------------

-- **The reference recording, or failing that the earliest shared take.**
--
-- The reference is the recording the song sheet was made from, and is the
-- closest thing this app has to "the song" as a single object. But requiring
-- it would quietly silence the person this feature is most for: somebody who
-- opened the app, sang into their phone, shared it, and never made a sheet.
-- They have audio. A list that only plays finished work is a list for people
-- who are already finished.
--
-- Only ever a *shared* take. A song's owner offers the song; they never offer
-- somebody else's unheard draft, and a private take stays private on a
-- published song. `song_layers_read_members` says the same thing as a policy,
-- and this says it again here so the answer cannot come back wrong even when
-- it is asked by a definer that bypasses the policy.
--
-- Granted to nobody. It reads across projects without checking who is asking,
-- which is safe only because every caller has already narrowed to songs on
-- the Open Mic. Callable inside those functions, and nowhere else.
create or replace function private.song_audio(target_project uuid)
returns table (storage_path text, duration_ms integer)
language sql
stable
security definer
set search_path = public
as $fn$
  select
    coalesce(f.storage_path, take.storage_path),
    coalesce(r.duration_ms, take.duration_ms)
  from public.projects p
  left join public.project_audio_references r on r.project_id = p.id
  left join public.files f on f.id = r.file_id
  left join lateral (
    select l.storage_path, l.duration_ms
    from public.song_layers l
    where l.project_id = p.id and l.shared_at is not null
    order by l.shared_at
    limit 1
  ) take on true
  where p.id = target_project
  limit 1;
$fn$;

revoke all on function private.song_audio(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The three lists that could not play
-- ---------------------------------------------------------------------

-- Dropped rather than replaced: `create or replace` cannot change the shape
-- of a `returns table`, and each of these grows columns.

drop function if exists public.open_mic_songs(text, integer, boolean);
drop function if exists public.open_mic_songs(text, integer);

create function public.open_mic_songs(
  in_part text default null,
  in_limit integer default 30,
  include_not_asking boolean default false
)
returns table (
  id uuid,
  title text,
  owner_id uuid,
  owner_name text,
  owner_avatar text,
  open_mic_at timestamptz,
  take_count bigint,
  asking_for text[],
  storage_path text,
  duration_ms integer
)
language sql
stable
security definer
set search_path = public
as $fn$
  select
    p.id,
    p.title,
    p.created_by,
    pr.display_name,
    pr.avatar_path,
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
    ),
    audio.storage_path,
    audio.duration_ms
  from public.projects p
  left join public.profiles pr on pr.id = p.created_by
  left join lateral private.song_audio(p.id) audio on true
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
$fn$;

revoke all on function public.open_mic_songs(text, integer, boolean)
  from public, anon;
grant execute on function public.open_mic_songs(text, integer, boolean)
  to authenticated;

-- Songs on somebody's profile: theirs, or ones they played on.

drop function if exists public.songs_by(uuid);

create function public.songs_by(target_profile uuid)
returns table (
  id uuid,
  title text,
  owner_id uuid,
  owner_name text,
  owner_avatar text,
  open_mic_at timestamptz,
  take_count bigint,
  asking_for text[],
  their_parts text[],
  storage_path text,
  duration_ms integer
)
language sql
stable
security definer
set search_path = public
as $fn$
  select
    p.id,
    p.title,
    p.created_by,
    pr.display_name,
    pr.avatar_path,
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
    ),
    coalesce(
      (select array_agg(distinct l.part::text)
         from public.song_layers l
        where l.project_id = p.id
          and l.recorded_by = target_profile
          and l.shared_at is not null),
      '{}'::text[]
    ),
    audio.storage_path,
    audio.duration_ms
  from public.projects p
  left join public.profiles pr on pr.id = p.created_by
  left join lateral private.song_audio(p.id) audio on true
  where p.open_mic_at is not null
    and p.deleted_at is null
    and not private.blocked_between((select auth.uid()), target_profile)
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
  limit 30;
$fn$;

revoke all on function public.songs_by(uuid) from public, anon;
grant execute on function public.songs_by(uuid) to authenticated;

-- And one song's own page.

drop function if exists public.open_mic_song(uuid);

create function public.open_mic_song(target_project uuid)
returns table (
  id uuid,
  title text,
  owner_id uuid,
  owner_name text,
  owner_avatar text,
  open_mic_at timestamptz,
  musical_key text,
  bpm double precision,
  asking_for text[],
  ask_note text,
  storage_path text,
  duration_ms integer
)
language sql
stable
security definer
set search_path = public
as $fn$
  select
    p.id,
    p.title,
    p.created_by,
    pr.display_name,
    pr.avatar_path,
    p.open_mic_at,
    r.musical_key,
    r.bpm,
    coalesce(
      (select array_agg(distinct a.part)
         from public.project_asks a
        where a.project_id = p.id and a.status = 'open' and a.part is not null),
      '{}'::text[]
    ),
    (select a.note from public.project_asks a
      where a.project_id = p.id and a.status = 'open'
        and char_length(trim(a.note)) > 0
      order by a.created_at desc limit 1),
    audio.storage_path,
    audio.duration_ms
  from public.projects p
  left join public.profiles pr on pr.id = p.created_by
  left join public.project_audio_references r on r.project_id = p.id
  left join lateral private.song_audio(p.id) audio on true
  where p.id = target_project
    and p.open_mic_at is not null
    and p.deleted_at is null
    and not private.blocked_between((select auth.uid()), p.created_by)
  limit 1;
$fn$;

revoke all on function public.open_mic_song(uuid) from public, anon;
grant execute on function public.open_mic_song(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- And the feed, asking the same question the same way
-- ---------------------------------------------------------------------

-- Unchanged in what it returns; it now gets its answer from `song_audio`
-- rather than from its own copy of the rule. One answer, not two that agree
-- today and diverge later.
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
  storage_path text
)
language sql
stable
security definer
set search_path = public
as $fn$
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
        where a.project_id = p.id and a.status = 'open' and a.part is not null),
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
    audio.duration_ms,
    audio.storage_path
  from public.projects p
  left join public.project_audio_references r on r.project_id = p.id
  left join public.profiles pr on pr.id = p.created_by
  left join lateral private.song_audio(p.id) audio on true
  where p.open_mic_at is not null
    and p.deleted_at is null
    -- Nothing silent. A card in a listening feed with nothing to play is
    -- worse than a shorter feed.
    and audio.storage_path is not null
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
  limit greatest(least(in_limit, 24), 1);
$fn$;

revoke all on function public.open_mic_feed(timestamptz, integer, text)
  from public, anon;
grant execute on function public.open_mic_feed(timestamptz, integer, text)
  to authenticated;
