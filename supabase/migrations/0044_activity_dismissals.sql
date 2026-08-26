-- Putting a piece of news away.
--
-- Home shows what the band has been doing, and until now the only way an
-- item left was by scrolling far enough down that it fell off the end. That
-- is fine for a feed nobody acts on and wrong for one people are meant to
-- read: the item you have dealt with looks exactly like the one you have not.
--
-- Per person, because "I have seen this" is a fact about a reader rather
-- than about the event. Two people in a band clear their own.
create table public.activity_dismissals (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  event_id uuid not null references public.project_events(id) on delete cascade,
  dismissed_at timestamptz not null default now(),
  primary key (profile_id, event_id)
);

create index activity_dismissals_profile_idx
  on public.activity_dismissals (profile_id);

alter table public.activity_dismissals enable row level security;

-- Your own, and nobody else's. What somebody has chosen to stop looking at
-- is not information the rest of the band is owed.
create policy activity_dismissals_read_own on public.activity_dismissals
for select to authenticated using (profile_id = (select auth.uid()));

create policy activity_dismissals_write_own on public.activity_dismissals
for insert to authenticated with check (profile_id = (select auth.uid()));

-- Undo. A feed you can clear without recourse is a feed people stop
-- trusting, so putting something back is a delete rather than a second row.
create policy activity_dismissals_delete_own on public.activity_dismissals
for delete to authenticated using (profile_id = (select auth.uid()));

-- What the band has been doing, minus everything this person has put away.
--
-- A function rather than a client query, because "what counts as activity"
-- is three rules that have to agree and one of them is already subtle:
--
--   * not your own doing — a feed that reports your own typing back to you
--     teaches everyone to stop reading it;
--   * not dismissed by you;
--   * not on a song in the recycle bin.
--
-- The first of those cost a bug when it lived in the client: a plain
-- `actor_id <> auth.uid()` also drops every row where actor_id is NULL,
-- because in SQL null <> anything is null rather than true — and null is
-- exactly what a system event carries, and what 0032 sets when an account is
-- deleted so that person's words survive. Written once here, it can only be
-- wrong in one place.
create or replace function public.recent_activity(max_rows integer default 20)
returns table (
  id uuid,
  project_id uuid,
  project_title text,
  kind text,
  body text,
  created_at timestamptz,
  actor_id uuid,
  actor_name text,
  actor_avatar_path text
)
language sql
security invoker
set search_path = public
as $$
  select
    e.id,
    e.project_id,
    p.title as project_title,
    e.kind,
    e.body,
    e.created_at,
    e.actor_id,
    a.display_name as actor_name,
    a.avatar_path as actor_avatar_path
  from public.project_events e
  join public.projects p on p.id = e.project_id
  left join public.profiles a on a.id = e.actor_id
  where p.deleted_at is null
    and (e.actor_id is null or e.actor_id <> auth.uid())
    and not exists (
      select 1 from public.activity_dismissals d
      where d.event_id = e.id and d.profile_id = auth.uid()
    )
  order by e.created_at desc
  limit greatest(1, least(max_rows, 100));
$$;

revoke all on function public.recent_activity(integer) from public, anon;
grant execute on function public.recent_activity(integer) to authenticated;
