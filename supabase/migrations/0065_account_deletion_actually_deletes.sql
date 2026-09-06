-- Account deletion, which does not currently work.
--
-- Anybody who has recorded a take on somebody else's song cannot delete their
-- account. `song_layers.recorded_by` references profiles with NO ACTION, so
-- the final `delete from auth.users` raises a foreign key violation and the
-- person gets a Postgres error in a snackbar after tapping "Delete
-- Permanently". One real account is in that state today.
--
-- It was correct in 0001 and stopped being correct as the app grew. The
-- function deletes the projects you *created*, which cascades to everything
-- inside them — but a take you recorded on a bandmate's song lives under
-- their project, survives that, and then blocks the delete. Three tables are
-- in that position now, and the number goes up every time collaboration gets
-- better, which is the direction the whole app is heading.
--
-- App Store Guideline 5.1.1(v) requires account deletion to work. So does the
-- right to erasure. Both are answered by the same fix.
--
-- **What happens to your parts of other people's songs.** Not deletion: a
-- band losing a bass part they cannot re-record because the bassist closed
-- their account is a worse outcome than the one deletion is meant to prevent.
-- Not keeping them either, with a name attached, because that is not
-- deletion. They are **de-identified** — the audio stays in the song it
-- belongs to, and everything saying who made it goes.
--
-- That is the call 0049 already made for asks, for the same reason: an ask
-- outliving the person who left is better than a song silently stopping
-- asking.

-- Nullable, because "who recorded this" now has a true answer of "somebody
-- who is gone". A not-null column here would force the choice between
-- destroying a band's song and not deleting an account.
alter table public.song_layers
  alter column recorded_by drop not null;
alter table public.song_layer_versions
  alter column created_by drop not null;
alter table public.project_audio_references
  alter column uploaded_by drop not null;

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  current_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if current_user_id is null then
    raise exception 'You must be signed in.' using errcode = '42501';
  end if;

  -- Your own things first, exactly as before.
  delete from public.invitations
  where invited_by = current_user_id or lower(email) = current_email;
  delete from public.comments where author_id = current_user_id;
  delete from public.files where uploaded_by = current_user_id;
  delete from public.contribution_revisions where edited_by = current_user_id;
  delete from public.contributions where author_id = current_user_id;

  -- Then the songs you made, which takes their takes with them.
  delete from public.projects where created_by = current_user_id;

  -- Takes nobody has ever heard are yours alone, and they go.
  --
  -- 0057 made a take private until its recorder shares it. An unshared take
  -- on somebody else's song is a draft only you could play — not part of the
  -- band's work, not something anybody would miss, and squarely the personal
  -- data that deleting an account is supposed to remove.
  delete from public.song_layers
  where recorded_by = current_user_id and shared_at is null;

  -- What is left is work the room has actually heard, inside songs other
  -- people own. The audio stays where it belongs; the person goes. Deleting
  -- these would take a bass part a band cannot re-record, which is a worse
  -- outcome than the one deletion exists to prevent.
  --
  -- `performer` is nulled alongside the id because it is free text somebody
  -- typed and it is usually a name — a deletion that left "Dave" written
  -- under a take would be deletion in the database and not in the room.
  update public.song_layers
  set recorded_by = null, performer = null
  where recorded_by = current_user_id;

  update public.song_layer_versions
  set created_by = null
  where created_by = current_user_id;

  update public.project_audio_references
  set uploaded_by = null
  where uploaded_by = current_user_id;

  -- And now nothing points at the row.
  delete from auth.users where id = current_user_id;
end;
$$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
