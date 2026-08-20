-- public.rooms and public.projects have had row level security enabled
-- since the very first migration, but neither ever got a `for delete`
-- policy. RLS defaults to deny when no policy matches an operation, so
-- every "Delete Room" / "Delete Song" the app has ever sent has silently
-- deleted zero rows — the client-side .delete() call doesn't error when
-- nothing matched, it just succeeds having done nothing.
--
-- Deletion is at least as sensitive as the update permission each table
-- already has, so these mirror the existing update policies exactly:
-- rooms stay owner-only (rooms_update_owner is owner-only), projects open
-- to owner or editor (projects_update_editors already trusts editors with
-- destructive actions on contributions/files within a project — deleting
-- the project itself is the same trust level, not a new one).

create policy rooms_delete_owner on public.rooms
for delete to authenticated using (account_id = (select auth.uid()));

create policy projects_delete_editors on public.projects
for delete to authenticated using (private.room_role_for(room_id) in ('owner', 'editor'));
