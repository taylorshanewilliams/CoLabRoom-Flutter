-- Batched room reordering: takes the full new order as an array and updates
-- every row's sort_order in one statement/round trip. Only rooms the caller
-- actually owns are touched, matching the ownership check already used by
-- rename/delete (rooms.account_id = auth.uid()); ids the caller doesn't own
-- are silently skipped rather than raising, since a stale/foreign id in the
-- list shouldn't block reordering the caller's own rooms.
create or replace function public.reorder_rooms(room_ids uuid[])
returns void
language plpgsql
security definer set search_path = public
as $$
begin
  update public.rooms
  set sort_order = ordered.rn * 1024
  from (
    select id, row_number() over () as rn
    from unnest(room_ids) as id
  ) as ordered
  where public.rooms.id = ordered.id
    and public.rooms.account_id = auth.uid();
end;
$$;

grant execute on function public.reorder_rooms(uuid[]) to authenticated;
