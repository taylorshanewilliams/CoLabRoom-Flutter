-- Lets a Room owner/editor upload a custom logo/cover image over a Room or
-- Song tile (e.g. a band's own logo) instead of the default icon. Images
-- live in the existing `room-files` storage bucket under
-- <room-id>/room-logo.png and <room-id>/<project-id>-cover.png — both paths
-- start with the room id, so the bucket's existing read (all room members)
-- and write (owner/editor) policies from migration 0001 already cover them
-- with no new storage policies needed.

alter table public.rooms add column if not exists logo_path text;
alter table public.projects add column if not exists cover_image_path text;
