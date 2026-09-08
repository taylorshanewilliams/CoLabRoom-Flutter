-- The ask carries the brief.
--
-- Somebody is asked to play bass on a stranger's song. What arrives is a
-- title, a name, the word "bass", and a sentence. They cannot hear it. They
-- do not know the key, the tempo, how long it is, or what is already on it.
--
-- Which means the only honest answer to that ask is "let me go and look",
-- and the number of people who go and look is the number of collaborations
-- this app can ever have. The single loudest complaint of every session
-- player alive is a bad brief, and the rest of the world sends an mp3 and a
-- text saying "it's in G I think".
--
-- **This app already worked all of it out.** The key, the tempo, the length
-- and the parts already on the song are sitting in
-- `project_audio_references` and `song_layers`, computed and paid for. The
-- ask was simply never told to carry them.
--
-- That is the whole argument for the app: it understands the inside of a
-- song, so a stranger's yes can be a usable part instead of a conversation.
-- An ask that arrives as "Weathervane, 2:14, in G at 96, guitar and a vocal
-- on it, wants bass — here, listen" is answerable on a bus.

-- ---------------------------------------------------------------------
-- Asking somebody means letting them hear it
-- ---------------------------------------------------------------------
--
-- And it always did — an ask nobody can listen to is not a request, it is a
-- riddle. But the policies never said so: somebody asked to play on a song
-- is not in its room, not on the song, has no pending invitation, and the
-- song is very often neither on the Open Mic nor showcased. So every branch
-- 0067 and 0088 added misses them, the brief below returns a storage path,
-- and the file behind it 403s.
--
-- That would be the classic version of this bug: a card that names a song
-- and cannot play it. The three layers are the same three 0088 had to widen,
-- for the same reason and with the same failure if one is missed — the row,
-- the takes on it, and the audio those takes point at.
--
-- The consent is narrow on purpose. It lasts while the ask is open and is
-- addressed to one named person: withdrawing it, or answering no, takes the
-- song back. It is not a fourth audience — the dial still decides who can
-- find a song, and this only decides that somebody you personally asked can
-- hear the thing you asked them about.

create or replace function private.was_asked(target_project uuid)
returns boolean
language sql
stable
security definer set search_path = ''
as $fn$
  select exists (
    select 1 from public.project_asks a
    where a.project_id = target_project
      and a.asked_of = (select auth.uid())
      and a.status = 'open'
  );
$fn$;

revoke all on function private.was_asked(uuid) from public, anon;
grant execute on function private.was_asked(uuid) to authenticated;

drop policy if exists projects_read_members on public.projects;
create policy projects_read_members on public.projects
for select to authenticated using (
  private.is_room_member(room_id)
  or private.is_project_member(id)
  or exists (
    select 1 from public.invitations invitation
    where invitation.project_id = projects.id
      and invitation.status = 'pending'
      and lower(invitation.email)
          = lower(coalesce((select auth.jwt()) ->> 'email', ''))
  )
  or open_mic_at is not null
  or showcased_at is not null
  or private.was_asked(id)
);

drop policy if exists song_layers_read_members on public.song_layers;
create policy song_layers_read_members on public.song_layers
for select to authenticated using (
  (
    shared_at is not null
    or recorded_by = (select auth.uid())
  )
  and exists (
    select 1 from public.projects p
    where p.id = project_id
      and (
        private.is_room_member(p.room_id)
        or private.is_project_member(p.id)
        -- Shared takes only, on every public surface and to anybody asked.
        -- A private take stays private on a song whose room has published
        -- it, and on one somebody has been asked to play on: the room offers
        -- the song, never somebody's unheard draft.
        or ((p.open_mic_at is not null or p.showcased_at is not null
             or private.was_asked(p.id))
            and shared_at is not null)
      )
  )
);

drop policy if exists room_files_read_members on storage.objects;
create policy room_files_read_members on storage.objects
for select to authenticated using (
  bucket_id = 'room-files'
  and (
    private.is_room_member(private.as_uuid((storage.foldername(name))[1]))
    or (
      array_length(storage.foldername(name), 1) >= 2
      and private.is_project_member(private.as_uuid((storage.foldername(name))[2]))
    )
    or exists (
      select 1
      from public.files f
      join public.projects p on p.id = f.project_id
      where f.storage_path = objects.name
        and (private.is_room_member(p.room_id) or private.is_project_member(p.id))
    )
    -- Paths are {room}/{project}/..., so the project is the second segment.
    or (
      array_length(storage.foldername(name), 1) >= 2
      and exists (
        select 1 from public.projects p
        where p.id = private.as_uuid((storage.foldername(name))[2])
          and (p.open_mic_at is not null or p.showcased_at is not null
               or private.was_asked(p.id))
      )
    )
  )
);

-- ---------------------------------------------------------------------
-- The brief
-- ---------------------------------------------------------------------
--
-- Dropped first, and this is the fifth migration in this repo to need that
-- sentence: `create or replace` cannot change the shape of a `returns table`
-- and fails with "cannot change return type of existing function".
drop function if exists public.asks_for_me();

create function public.asks_for_me()
returns table (
  id uuid,
  project_id uuid,
  song_title text,
  asked_by uuid,
  asked_by_name text,
  part text,
  note text,
  created_at timestamptz,

  -- Everything below is the brief, and every field of it already existed
  -- somewhere else in the database.
  storage_path text,
  duration_ms integer,
  musical_key text,
  bpm double precision,

  -- What is already on it, as words. "Guitar and a vocal on it" tells
  -- somebody whether there is a hole shaped like them; a number of takes
  -- tells them nothing and would be a count of somebody's work, which this
  -- app does not put on screens.
  parts_on_it text[],

  -- Whether the chords and words are already worked out. For the person
  -- answering this is the difference between ten minutes and an evening.
  has_song_sheet boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select
    a.id,
    a.project_id,
    p.title,
    a.asked_by,
    pr.display_name,
    a.part,
    a.note,
    a.created_at,
    audio.storage_path,
    audio.duration_ms,
    r.musical_key,
    r.bpm,
    coalesce(
      (select array_agg(distinct l.part::text)
         from public.song_layers l
        where l.project_id = p.id
          and l.shared_at is not null
          and l.part is not null),
      '{}'::text[]
    ),
    coalesce(r.analysis_state = 'ready', false)
  from public.project_asks a
  join public.projects p on p.id = a.project_id
  left join public.profiles pr on pr.id = a.asked_by
  left join public.project_audio_references r on r.project_id = p.id
  left join lateral private.song_audio(p.id) audio on true
  where a.asked_of = (select auth.uid())
    and a.status = 'open'
  order by a.created_at desc;
$$;

revoke all on function public.asks_for_me() from public, anon;
grant execute on function public.asks_for_me() to authenticated;
