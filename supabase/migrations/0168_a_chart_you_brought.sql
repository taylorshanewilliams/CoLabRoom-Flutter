-- A chart you brought.
--
-- Taylor, 19 September 2026: can people practise any song they want in here,
-- the way they use a tab site? Until now, no. Chords in this app exist only
-- as `chord_cues` -- a chord with a start and an end in milliseconds against
-- an analysed recording -- so a song with no recording has nowhere at all to
-- put a chord. Somebody who owns the sheet music for a song, or wrote a
-- chart out in Notes, could export ChordPro from this app (#360) and could
-- not bring one in.
--
-- This is the other half of that door. It is what OnSong and SongbookPro do:
-- a person brings a chart they already have, for their own practice, into
-- their own private song. **Nothing here fetches anything.** There is no
-- scraper in this app, no URL import of a third-party page and no search
-- inside one: tabs and lyrics of commercial songs are licensed content, and
-- the sites that hold them have no API and terms that say so. The only way a
-- chart gets into this table is a person pasting or opening one.
--
-- **One chart per song, and it is not chord cues.** `project_id` is the
-- primary key, so bringing a second chart replaces the first rather than
-- leaving a song with two. And a brought chart stays what it is -- text on a
-- page -- rather than being turned into timed cues: lining a chart up with a
-- recording is a different job, with its own decisions, and doing it badly
-- here would silently rewrite the song sheet the analysis made.
--
-- **It is never public.** There is no policy here for anon, the Open Mic or
-- the showcase, and no view over it. A song made by bringing a chart is
-- answered as somebody else's (0142) unless the person says otherwise, which
-- keeps it off both public surfaces in SQL; this table is narrower still,
-- and is readable only by the people already in the room.

create table public.brought_charts (
  -- One song, one chart. Cascades because a chart of a song that is gone is
  -- not a chart of anything.
  project_id uuid primary key
    references public.projects(id) on delete cascade,
  -- The chart as normalised ChordPro (see lib/services/brought_chart.dart),
  -- whichever of the three shapes it arrived in. Capped at about 64 KB,
  -- which is a very long song and a very short abuse of a text column.
  body text not null check (char_length(body) between 1 and 65536),
  -- Who brought it, kept because a chart is somebody's work of typing and
  -- the room should be able to see whose. Nulled rather than cascaded when
  -- that account goes: the band's chart is not deleted by somebody leaving.
  brought_by uuid references public.profiles(id) on delete set null,
  brought_at timestamptz not null default now()
);

comment on table public.brought_charts is
  'A chart somebody brought into a song, as normalised ChordPro. One per '
  'song. Readable by the people in the room, written only through '
  'bring_a_chart by the room''s owner or an editor. Never public: nothing '
  'here is served to anon and no view exposes it.';
comment on column public.brought_charts.body is
  'Normalised ChordPro. Not chord_cues: a brought chart has no timings and '
  'lining one up with a recording is a separate job.';

alter table public.brought_charts enable row level security;

-- ---------------------------------------------------------------------
-- Who can read it
-- ---------------------------------------------------------------------

-- The people in the room, and anybody invited to this song in particular
-- (0013) -- the same pair `can_hear_recording` (0141) asks about, and
-- deliberately narrower than the song's own read policy, which also admits
-- Open Mic listeners and anybody who found a showcased song. A chart is not
-- a public page of a song: 0096's stance is that there is no public page for
-- anything inside a room, and a chart somebody typed out of the sheet music
-- they own is exactly the thing that must not become one.
create policy brought_charts_read on public.brought_charts
for select to authenticated using (
  exists (
    select 1 from public.projects p
    where p.id = brought_charts.project_id
      and p.deleted_at is null
      and (private.is_room_member(p.room_id) or private.is_project_member(p.id))
  )
);

revoke all on table public.brought_charts from anon;
grant select on table public.brought_charts to authenticated;

-- There is deliberately no insert, update or delete policy. Everything that
-- writes here goes through the function below, for the reason every other
-- shared fact about a song does (0142, 0144, 0161, 0163): the rule about who
-- may say it is one sentence in one place, and a person who is refused gets
-- that sentence rather than a row that silently did not appear.

-- ---------------------------------------------------------------------
-- Bringing one
-- ---------------------------------------------------------------------

-- Owner or editor: the same two who can say what key the song is in (0144),
-- where bar 1 is (0161) and what it is sung in (0163). A chart is a shared
-- fact about the song -- everybody in the room reads the same page off it --
-- so somebody who can only look cannot replace it.
--
-- Brought a second time, it replaces the first. That is what "Replace the
-- chart" means in the app, and it is why this is an upsert rather than an
-- insert that would fail the second time with a constraint name.
create or replace function public.bring_a_chart(
  target_project uuid,
  in_body text
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  song record;
  role_here public.room_role;
  cleaned text;
begin
  cleaned := nullif(btrim(coalesce(in_body, '')), '');
  if cleaned is null then
    raise exception 'There is nothing in that chart.' using errcode = '22023';
  end if;
  -- Said as a sentence here as well as refused by the check on the column,
  -- so somebody who brought a whole songbook by mistake is told what
  -- happened rather than handed a constraint name.
  if char_length(cleaned) > 65536 then
    raise exception 'That chart is too long to keep.' using errcode = '22023';
  end if;

  select p.id, p.room_id into song
  from public.projects p
  where p.id = target_project and p.deleted_at is null;

  if song.id is null then
    raise exception 'That song does not exist.' using errcode = '22023';
  end if;

  role_here := private.room_role_for(song.room_id);

  -- `is distinct from` twice, not `not in`. room_role_for is null for
  -- somebody who is not in the room, `null not in ('owner', 'editor')` is
  -- null, and `if null then` does not fire -- so the plain form waves through
  -- the exact person the check exists to stop. See 0068.
  if role_here is distinct from 'owner' and role_here is distinct from 'editor'
  then
    raise exception 'Only somebody who can edit this song can bring a chart.'
      using errcode = '42501';
  end if;

  insert into public.brought_charts (project_id, body, brought_by, brought_at)
  values (target_project, cleaned, auth.uid(), now())
  on conflict (project_id) do update
  set body = excluded.body,
      brought_by = excluded.brought_by,
      brought_at = excluded.brought_at;
end;
$fn$;

revoke all on function public.bring_a_chart(uuid, text) from public, anon;
grant execute on function public.bring_a_chart(uuid, text) to authenticated;
