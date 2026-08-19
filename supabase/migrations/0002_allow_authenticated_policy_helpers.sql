-- RLS policies call these private helpers while evaluating requests made by the
-- authenticated role. The helpers remain outside the exposed API schema and
-- derive every answer from auth.uid(), so they reveal only the caller's own
-- membership and role.

revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

revoke all on function private.is_room_member(uuid) from public, anon;
revoke all on function private.room_role_for(uuid) from public, anon;
grant execute on function private.is_room_member(uuid) to authenticated;
grant execute on function private.room_role_for(uuid) to authenticated;
