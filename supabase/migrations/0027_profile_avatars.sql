-- A face next to your name.
--
-- profiles.avatar_path has existed since migration 0001 and nothing has ever
-- written to it. This gives it somewhere to point.
--
-- A bucket of its own rather than a corner of room-files. That bucket's
-- policies match on the first two path segments to decide room and project
-- membership, and an avatar belongs to a person, not a room — the whole point
-- is that it follows you into every room you're in.

insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', false)
on conflict (id) do nothing;

-- Path is '<user id>/avatar.png', so the first path segment is the owner.
-- That's what every policy below matches on.

-- Readable by any signed-in user, which is the point of a profile picture:
-- your bandmates see it, and a stranger who guesses a uuid sees a face
-- somebody chose to put on a profile. Not public, though — an unauthenticated
-- request gets nothing, so avatars can't be scraped or hotlinked.
create policy avatars_read_authenticated on storage.objects
for select to authenticated using (bucket_id = 'avatars');

-- Writing is yours alone. Without the owner check any signed-in user could
-- overwrite anybody's picture, which is a small thing that would feel
-- enormous to the person it happened to.
create policy avatars_write_own on storage.objects
for insert to authenticated with check (
  bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text
);

create policy avatars_update_own on storage.objects
for update to authenticated using (
  bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text
);

create policy avatars_delete_own on storage.objects
for delete to authenticated using (
  bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text
);

-- Everyone can already read display_name from profiles (the invite flow and
-- the notification list both do). Nothing new is exposed by avatar_path
-- living in the same row — the object it points at is what's protected.
