-- Migration 0013 widened rooms_read_members with a plain (non-security-
-- definer) subquery on public.projects:
--   or exists (select 1 from public.projects p where p.room_id = rooms.id
--              and private.is_project_member(p.id))
-- projects_create_editors (migration 0001) already had a plain subquery on
-- public.rooms in its WITH CHECK. Postgres expands RLS policies at plan
-- time, so those two plain (non-security-definer) subqueries pointing at
-- each other form a real cycle: inserting a project needs to check rooms
-- visibility, which needs to check projects visibility, which needs to
-- check rooms visibility again — "infinite recursion detected in policy
-- for relation 'projects'" on every new-song creation.
--
-- The existing is_room_member/room_role_for functions avoid this exact trap
-- by being security definer, so their internal table reads bypass RLS
-- entirely instead of re-entering policy evaluation. Wrapping the
-- project-membership room-visibility check the same way closes the cycle
-- without changing what's actually visible to whom.

create or replace function private.room_visible_via_project_membership(target_room uuid)
returns boolean
language sql
stable
security definer set search_path = ''
as $$
  select exists (
    select 1 from public.projects p
    where p.room_id = target_room and private.is_project_member(p.id)
  );
$$;

revoke all on function private.room_visible_via_project_membership(uuid) from public, anon;
grant execute on function private.room_visible_via_project_membership(uuid) to authenticated;

drop policy if exists rooms_read_members on public.rooms;
create policy rooms_read_members on public.rooms
for select to authenticated using (
  account_id = (select auth.uid())
  or private.is_room_member(id)
  or private.room_visible_via_project_membership(id)
  or exists (
    select 1 from public.invitations invitation
    where invitation.room_id = rooms.id
      and invitation.status = 'pending'
      and lower(invitation.email) = lower(coalesce((select auth.jwt()) ->> 'email', ''))
  )
);
