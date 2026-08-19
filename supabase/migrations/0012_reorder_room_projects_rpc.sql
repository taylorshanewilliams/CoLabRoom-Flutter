-- Batched project reordering within a Room: takes the full new order as an
-- array and updates every row's sort_order in one statement/round trip,
-- mirroring reorder_rooms (migration 0010). Authorization mirrors the
-- projects_update_editors policy (owner/editor room members only) rather
-- than a plain account_id check, since projects are shared across a Room's
-- members rather than single-account-owned.
create or replace function public.reorder_room_projects(project_ids uuid[])
returns void
language plpgsql
security definer set search_path = public
as $$
begin
  update public.projects
  set sort_order = ordered.rn * 1024
  from (
    select id, row_number() over () as rn
    from unnest(project_ids) as id
  ) as ordered
  where public.projects.id = ordered.id
    and private.room_role_for(public.projects.room_id) in ('owner', 'editor');
end;
$$;

grant execute on function public.reorder_room_projects(uuid[]) to authenticated;
