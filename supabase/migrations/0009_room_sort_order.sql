-- Adds manual drag-reorder support for Room tiles.
alter table public.rooms
  add column sort_order double precision not null default 0;

-- Backfill existing rooms with a stable initial order (newest first, matching
-- the previous default sort so nothing visibly reshuffles on upgrade).
with ordered as (
  select id, row_number() over (
    partition by account_id order by updated_at desc
  ) as rn
  from public.rooms
)
update public.rooms
set sort_order = ordered.rn * 1024
from ordered
where public.rooms.id = ordered.id;

create index rooms_account_sort_idx on public.rooms (account_id, sort_order);
