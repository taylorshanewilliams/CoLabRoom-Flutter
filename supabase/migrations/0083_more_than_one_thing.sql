-- More than one thing.
--
-- Taylor, looking for somebody to work with: "you can only choose one option
-- at a time, like harmony, or lead, not make multiple selections, like a
-- singer, who plays guitar and writes lyrics."
--
-- `find_musicians` takes one part and filters on it, so the question it can
-- answer is "who plays bass" and the question people actually have is "who
-- could do this with me", which is nearly always more than one thing.
--
-- **The obvious fix is the wrong one.** Taking a list and requiring all of it
-- turns three ticked boxes into an empty screen: at seventy-five people the
-- odds that somebody has recorded singing *and* guitar *and* lyrics are
-- close to nil, and an empty result reads as a broken app rather than a
-- small one. Requiring any of it is better and still throws away what was
-- asked — the person who does all three is the answer, and lands wherever
-- the shuffle put them.
--
-- **So it ranks instead of narrowing.** Tick three things and everybody who
-- does at least one is here, with whoever does the most first. Nothing is
-- hidden for missing a box, the full match is genuinely rewarded, and the
-- list never comes back empty because somebody was thorough.
--
-- This is closeness, not quality, exactly as 0072 and 0074 require: matching
-- more of what *you* asked for says nothing about whether somebody is a
-- better musician, only that they are nearer what you are looking for. A
-- beginner who sings and plays guitar outranks a session player who only
-- drums, for this search, and that is the correct answer to this question.

drop function if exists public.find_musicians(text, text, integer, text);

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
  -- Which of the things you asked for they actually do, so the card can say
  -- why they are near the top instead of leaving somebody to work it out.
  matched_parts text[]
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
    coalesce(fit.parts, '{}'::text[])
  from public.profiles p
  cross join lateral (
    select array_agg(t) as tags
    from unnest(p.sounds_like) as t
    where t = any(coalesce((select m.sounds_like from me m), '{}'::text[]))
  ) shared
  cross join lateral (
    -- Every asked-for part this person either says they play or has actually
    -- recorded. Declared and recorded both count: 0072 settled that a
    -- declaration is not worth less than a record when the question is who to
    -- ask, and this is that question.
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
  where p.discoverable
    and not private.blocked_between((select auth.uid()), p.id)
    -- Nothing asked for: everybody. Something asked for: anybody who does at
    -- least one of them. Never all of them, which is how a thorough question
    -- ends in an empty room.
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
    -- How much of what you asked for they do. The only count in this
    -- function that orders anything, and it measures the fit between two
    -- people rather than one of them.
    coalesce(array_length(fit.parts, 1), 0) desc,
    -- Then the same corner of music, as 0076 has it.
    case when coalesce(array_length(shared.tags, 1), 0) > 0 then 0 else 1 end,
    -- Then 0072's daily shuffle, unchanged: stable while you look, different
    -- tomorrow, and nobody's position earned.
    md5(p.id::text || current_date::text)
  limit greatest(least(in_limit, 100), 1);
$fn$;

revoke all on function public.find_musicians(text[], text, integer, text)
  from public, anon;
grant execute on function public.find_musicians(text[], text, integer, text)
  to authenticated;
