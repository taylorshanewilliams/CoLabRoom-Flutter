-- The record button leaves litter.
--
-- Taylor, from using it: "I have bumped the big yellow record button a couple
-- of times and it just leaves a new song created on the home page even though
-- I didn't do anything, and I can't delete them."
--
-- Both halves are true and both are this app's fault.
--
-- The button creates the song *first* — `startIdea()` runs on the tap, before
-- the recorder is even on screen — so a thumb brushing a floating button in
-- the corner produces a permanent, auto-named, empty song. There is no start
-- or stop to it; the creating already happened.
--
-- And the only way to delete a song is a multi-select inside a room, which
-- means the litter from a bumped button can only be swept up somewhere
-- nobody would think to look.
--
-- **This is the sweeper; the app also grows a delete on the song itself.**
--
-- Deliberately timid, because the failure mode is deleting somebody's work.
-- It will only remove a song that is *provably* nothing: no takes, no
-- recording, not one word typed, never published, made by the person asking,
-- and made in the last couple of hours. A song that fails any one of those is
-- left alone, and the caller is told nothing was removed.
--
-- It is called from one place — the moment the recorder closes on a song the
-- record button created — and never on anything a person deliberately made.

create or replace function public.discard_if_untouched(target_project uuid)
returns boolean
language plpgsql
-- Definer, like every other operational function here, and for a plainer
-- reason than usual: this does not need to borrow anybody's rights, because
-- it checks ownership itself and more strictly than any policy would. The
-- `created_by = auth.uid()` clause below is the whole permission model, and
-- it is in the same statement as the delete rather than a policy away from it.
security definer
set search_path = public
as $fn$
declare
  gone integer;
begin
  delete from public.projects p
  where p.id = target_project
    -- Yours, and recent. An old project can never be caught by this even if
    -- it is empty: somebody may be about to record into a song they made
    -- last week, and "empty" is not "abandoned".
    and p.created_by = auth.uid()
    and p.created_at > now() - interval '2 hours'
    and p.deleted_at is null
    -- Never published, at any point.
    and p.open_mic_at is null
    -- Nothing recorded into it, shared or not.
    and not exists (
      select 1 from public.song_layers l where l.project_id = p.id
    )
    and not exists (
      select 1 from public.project_audio_references r
      where r.project_id = p.id
    )
    -- And nothing written in it. A blank line is not writing; a lyric is.
    and not exists (
      select 1 from public.contributions c
      where c.project_id = p.id
        and char_length(trim(coalesce(c.body, ''))) > 0
    )
    -- Nobody else was invited to it, which would make it somebody else's
    -- business as well as theirs.
    and not exists (
      select 1 from public.project_members m
      where m.project_id = p.id and m.user_id <> auth.uid()
    );

  get diagnostics gone = row_count;
  return gone > 0;
end;
$fn$;

revoke all on function public.discard_if_untouched(uuid) from public, anon;
grant execute on function public.discard_if_untouched(uuid) to authenticated;

comment on function public.discard_if_untouched(uuid) is
  'Removes a song only if it is provably nothing: no takes, no recording, no '
  'words, never published, yours, and made within two hours. Used to sweep up '
  'after the record button when nobody recorded anything.';
