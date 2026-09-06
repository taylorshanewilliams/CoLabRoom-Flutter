-- Who did what to this song, and when.
--
-- The fear this answers is real and old: somebody shows a half-finished song
-- to a collaborator, and later the song is somebody else's. It happens in
-- music constantly, and the reason it goes unresolved is almost never that
-- the truth is unknowable — it is that nobody kept a record anybody believes.
-- A voice memo has a file date that its owner can change.
--
-- CoLabRoom has been keeping that record accidentally since 0001. Every lyric
-- line carries an author and a revision history, every take carries who
-- recorded it, every upload carries who uploaded it, and all of it is
-- timestamped by the server rather than by the phone. This function stops
-- that being an accident and makes it something a musician can hold.
--
-- **What this is not.** It is not copyright registration, and it does not
-- decide anything. It is contemporaneous evidence — a dated account, written
-- as things happened, by a system with no stake in the argument. That is what
-- these disputes actually turn on, and it is more than almost anybody in a
-- band has.

-- Where a recording's fingerprint lives.
--
-- The pipeline already computes a SHA-256 of every recording it analyses —
-- 0024 keys the analysis cache on it — but the hash was never written back
-- against the file, so nothing could say "this exact audio existed in this
-- account on this date". One column closes that.
--
-- Nullable, and honestly so: it is filled in when a recording is analysed,
-- which is most of them but not all, and nothing backfills the ones from
-- before this migration.
alter table public.files
  add column if not exists audio_sha256 text;

create index if not exists files_audio_sha256_idx
  on public.files (audio_sha256) where audio_sha256 is not null;

comment on column public.files.audio_sha256 is
  'SHA-256 of the audio as uploaded, written by the analysis pipeline. A '
  'fingerprint for the provenance record — two files with the same hash are '
  'the same recording.';

-- The record itself.
--
-- One row per event, oldest first, because that is the order the story
-- happened in and the order anybody reading it will want. Deliberately a flat
-- timeline rather than nested structures: this is going to be printed, read
-- by somebody who is upset, and possibly shown to a lawyer, and a table of
-- dated events is the shape all three of those want.
create or replace function public.song_provenance(target_project uuid)
returns table (
  at timestamptz,
  event text,
  who uuid,
  who_name text,
  detail text
)
language sql
security invoker
set search_path = public
as $$
  -- security invoker on purpose: the caller sees this song's history only if
  -- RLS already lets them see the song. A provenance record is evidence about
  -- people, and the last thing it should do is become a way to read the
  -- history of a song somebody is not part of.
  with events as (
    select
      p.created_at as at,
      'song created' as event,
      p.created_by as who,
      coalesce(pr.display_name, 'someone') as who_name,
      p.title as detail
    from public.projects p
    left join public.profiles pr on pr.id = p.created_by
    where p.id = target_project

    union all

    select
      f.created_at,
      'recording uploaded',
      f.uploaded_by,
      coalesce(pr.display_name, 'someone'),
      f.display_name
        || case when f.audio_sha256 is null then ''
                else ' · sha256 ' || left(f.audio_sha256, 16) end
    from public.files f
    left join public.profiles pr on pr.id = f.uploaded_by
    where f.project_id = target_project and f.deleted_at is null

    union all

    -- The first version of every line, which is the moment the words existed.
    select
      c.created_at,
      'lyric written',
      c.author_id,
      coalesce(pr.display_name, c.author_name),
      left(c.body, 120)
    from public.contributions c
    left join public.profiles pr on pr.id = c.author_id
    where c.project_id = target_project

    union all

    -- And every edit after it. A line that changed hands matters as much as
    -- one that did not: "who wrote this" and "who rewrote it" are different
    -- questions and both get asked.
    select
      r.created_at,
      'lyric edited',
      r.edited_by,
      coalesce(pr.display_name, 'someone'),
      left(r.body, 120)
    from public.contribution_revisions r
    join public.contributions c on c.id = r.contribution_id
    left join public.profiles pr on pr.id = r.edited_by
    where c.project_id = target_project

    union all

    select
      l.created_at,
      'take recorded',
      l.recorded_by,
      coalesce(pr.display_name, 'someone'),
      coalesce(nullif(l.label, ''), l.part)
        || case when l.performer is null then '' else ' · ' || l.performer end
    from public.song_layers l
    left join public.profiles pr on pr.id = l.recorded_by
    where l.project_id = target_project

    union all

    select
      a.created_at,
      'asked for',
      a.asked_by,
      coalesce(pr.display_name, 'someone'),
      coalesce(a.part, 'ideas')
    from public.project_asks a
    left join public.profiles pr on pr.id = a.asked_by
    where a.project_id = target_project
  )
  select at, event, who, who_name, detail
  from events
  order by at asc;
$$;

revoke all on function public.song_provenance(uuid) from public, anon;
grant execute on function public.song_provenance(uuid) to authenticated;

-- A one-line summary, for the top of the printed page.
--
-- The two facts somebody reaches for first: when this song first existed, and
-- who has touched it since.
create or replace function public.song_provenance_summary(target_project uuid)
returns table (
  title text,
  started_at timestamptz,
  started_by text,
  contributors bigint,
  events bigint
)
language sql
security invoker
set search_path = public
as $$
  select
    p.title,
    p.created_at,
    coalesce(pr.display_name, 'someone'),
    (select count(distinct e.who) from public.song_provenance(target_project) e
      where e.who is not null),
    (select count(*) from public.song_provenance(target_project))
  from public.projects p
  left join public.profiles pr on pr.id = p.created_by
  where p.id = target_project;
$$;

revoke all on function public.song_provenance_summary(uuid) from public, anon;
grant execute on function public.song_provenance_summary(uuid) to authenticated;
