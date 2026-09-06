-- A blank line is not an event.
--
-- The first real record read out of production — "Tonight Live", 5 September
-- — opened with the song being created, the recording being uploaded, and
-- then a lyric event whose detail was an empty string. The editor writes a row
-- for a blank line the way any text editor does, and the record faithfully
-- reported it.
--
-- Harmless in a query and not harmless on the page this is for. The whole
-- value of a provenance record is that it reads as a credible account, and an
-- account with an entry that says nothing happened invites the reader to
-- wonder what else is in there that should not be. Precision is the product.

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

    select
      c.created_at,
      'lyric written',
      c.author_id,
      coalesce(pr.display_name, c.author_name),
      left(c.body, 120)
    from public.contributions c
    left join public.profiles pr on pr.id = c.author_id
    where c.project_id = target_project
      -- The line that closes the gap. A row whose body is empty or nothing
      -- but whitespace is the editor's blank line, not a moment in the
      -- writing of a song.
      and char_length(trim(c.body)) > 0

    union all

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
      and char_length(trim(r.body)) > 0

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
