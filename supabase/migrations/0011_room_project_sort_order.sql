-- Adds manual drag-reorder support for song/project tiles within a Room.
alter table public.projects
  add column sort_order double precision not null default 0;

-- Backfill existing projects with a stable initial order (newest first,
-- matching the previous default sort so nothing visibly reshuffles on
-- upgrade), scoped per room.
with ordered as (
  select id, row_number() over (
    partition by room_id order by updated_at desc
  ) as rn
  from public.projects
)
update public.projects
set sort_order = ordered.rn * 1024
from ordered
where public.projects.id = ordered.id;

create index projects_room_sort_idx on public.projects (room_id, sort_order);
