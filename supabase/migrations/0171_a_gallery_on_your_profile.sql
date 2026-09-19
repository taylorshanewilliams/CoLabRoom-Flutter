-- A gallery on your profile.
--
-- Taylor asked on 19 September 2026 whether somebody can put a gallery of
-- images or video on their profile. Images yes; hosted video no, for the
-- reason 0059 already wrote down and which has not changed: storage is the
-- one line on this bill paid again every month on everything ever uploaded,
-- and a video library is a cost that grows on its own forever on things
-- almost nobody watches. Video stays a link.
--
-- **What a picture is here.** Up to eight per profile, each with an optional
-- line of the owner's own words, and optionally tied to one of their own
-- songs that is already on the Open Mic — a photograph of the gig that plays
-- the song from that night. Nothing is counted: no likes, no views, no
-- ordering by anything except the order the owner put them in. A profile is
-- a room somebody is proud of, not a feed.
--
-- **Moderation is the same moderation an avatar gets, with one difference.**
-- Every picture goes through the check-picture Edge Function, is reportable,
-- and is reachable by take_down_image and tools/take_down.py. The difference
-- is when it becomes visible: an avatar is shown the instant it is uploaded
-- and unpointed afterwards if it is refused, whereas a gallery picture is
-- shown to nobody but its owner until `passed_at` is set. There are eight of
-- these per profile rather than one, and an owner looking at their own page
-- sees their picture immediately either way, so waiting costs nothing that
-- showing it early would not cost more.
--
-- check-picture still fails open, deliberately and for its own stated reason:
-- when the moderation call cannot be made at all it passes the picture and
-- records why. A moderation system that takes the product down with it is one
-- that gets switched off, and the report path still catches what it misses.
--
-- **Whose gallery a stranger sees.** Exactly the profiles whose page they can
-- already open: the rule in musician_profile (0063, widened by 0137) rather
-- than a second rule invented here. That is what keeps a minor's gallery away
-- from strangers without this migration having to know anything about age —
-- if the profile is hidden the gallery is hidden with it, and it stays true
-- the next time the profile rule changes.
--
-- **The bucket is `avatars`, and that is on purpose.** Its four policies key
-- on the first path segment being the owner's id, so `<uid>/gallery/<name>`
-- is already exactly what they read: the owner writes their own and nobody
-- else's, and take_down.py deletes from a bucket it already knows. A bucket
-- of its own would mean four more storage policies with no local Postgres to
-- try them on, to hold the same pictures of the same person.

-- ---------------------------------------------------------------------
-- Who can see a profile at all
-- ---------------------------------------------------------------------

-- The same question `musician_profile` asks before it returns a row, as a
-- predicate other things can ask too.
--
-- musician_profile is left exactly as 0137 wrote it. This is deliberately a
-- second reader of the same rule rather than a rewrite of it: restating that
-- function to call this one would put a wave of concurrent migrations in each
-- other's way for no behaviour change at all.
create or replace function private.profile_page_visible(target uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not private.blocked_between((select auth.uid()), target)
    and (
      target = (select auth.uid())
      or exists (
        select 1 from public.profiles p
        where p.id = target and p.discoverable
      )
      or exists (
        select 1 from public.room_members rm
        where rm.user_id = target and private.is_room_member(rm.room_id)
      )
      -- One of your people, or somebody asking to be, either way round (0137).
      or exists (
        select 1 from public.connections c
        where (c.requester_id = (select auth.uid()) and c.addressee_id = target)
           or (c.requester_id = target and c.addressee_id = (select auth.uid()))
      )
    );
$$;

revoke all on function private.profile_page_visible(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The pictures
-- ---------------------------------------------------------------------

create table if not exists public.profile_pictures (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null default auth.uid()
    references public.profiles(id) on delete cascade,

  -- Where the object is, in the `avatars` bucket. Unique because two rows
  -- pointing at one object means a takedown that removes one leaves the
  -- other drawing a picture that is supposed to be gone.
  storage_path text not null unique,

  -- Their own words about their own picture. Short: this is a line under a
  -- photograph, not a post.
  caption text not null default '' check (char_length(caption) <= 140),

  -- The song tapping it plays, when there is one. Null is the ordinary case.
  -- `set null` rather than `cascade`: deleting a song should quieten a
  -- picture, not take it off somebody's profile.
  project_id uuid references public.projects(id) on delete set null,

  -- The owner's own arrangement, and the only thing this is ever ordered by.
  position integer not null default 0,

  -- Null until check-picture has looked at it. Until then the only person
  -- who can see this row is the person whose picture it is.
  passed_at timestamptz,

  -- Set by check-picture when it refuses a picture, and by take_down_image
  -- when a person does. The row stays so the report that named it stays;
  -- the picture is off the profile from that moment for everybody, its
  -- owner included, and the object still has to go through the Storage API.
  taken_down_at timestamptz,

  created_at timestamptz not null default now(),

  -- The path names an object the storage policies already agree is theirs.
  -- Without this a row could point at anybody's object in that bucket and
  -- the gallery would be a way to draw somebody else's picture under your
  -- own name.
  constraint profile_pictures_path_is_yours
    check (storage_path like (profile_id::text || '/gallery/%'))
);

create index if not exists profile_pictures_profile_idx
  on public.profile_pictures (profile_id, position, created_at);

alter table public.profile_pictures enable row level security;

-- Yours, always, passed or not — otherwise adding a picture would look like
-- nothing happening. Anybody else's, only once it has passed and only on a
-- profile they could already open.
drop policy if exists profile_pictures_read on public.profile_pictures;
create policy profile_pictures_read on public.profile_pictures
for select to authenticated using (
  taken_down_at is null
  and (
    profile_id = (select auth.uid())
    or (passed_at is not null and private.profile_page_visible(profile_id))
  )
);

drop policy if exists profile_pictures_write_own on public.profile_pictures;
create policy profile_pictures_write_own on public.profile_pictures
for insert to authenticated with check (profile_id = (select auth.uid()));

drop policy if exists profile_pictures_update_own on public.profile_pictures;
create policy profile_pictures_update_own on public.profile_pictures
for update to authenticated using (profile_id = (select auth.uid()))
with check (profile_id = (select auth.uid()));

drop policy if exists profile_pictures_delete_own on public.profile_pictures;
create policy profile_pictures_delete_own on public.profile_pictures
for delete to authenticated using (profile_id = (select auth.uid()));

revoke all on table public.profile_pictures from anon;
revoke all on table public.profile_pictures from authenticated;

-- Column by column, because the policy above cannot say which columns a
-- write may touch and two of them decide whether the picture is visible at
-- all. A phone that could set `passed_at` could put an unexamined picture in
-- front of strangers, which is the entire thing this table is careful about;
-- one that could rewrite `storage_path` could point a passed row at a
-- different object afterwards.
grant select, delete on table public.profile_pictures to authenticated;
grant insert (profile_id, storage_path, caption, project_id, position)
  on table public.profile_pictures to authenticated;
grant update (caption, project_id, position)
  on table public.profile_pictures to authenticated;

-- ---------------------------------------------------------------------
-- What a picture may point at
-- ---------------------------------------------------------------------

-- Their own song, and one that is already out in the open.
--
-- Their own, because a picture that plays somebody else's song is a picture
-- claiming it. Already on the Open Mic, because the person looking at the
-- gallery is often a stranger, and a tie to a song in a private room would
-- make a profile picture the way into a room nobody let them into.
create or replace function private.picture_song_is_your_own()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
begin
  if new.project_id is not null and not exists (
    select 1 from public.projects p
    where p.id = new.project_id
      and p.created_by = new.profile_id
      and p.deleted_at is null
      and p.open_mic_at is not null
  ) then
    raise exception
      'A picture can play one of your own songs that is on the Open Mic.'
      using errcode = '22023';
  end if;
  return new;
end;
$$;

drop trigger if exists profile_pictures_song_is_your_own on public.profile_pictures;
create trigger profile_pictures_song_is_your_own
before insert or update of project_id on public.profile_pictures
for each row execute function private.picture_song_is_your_own();

-- Somewhere to stop, the same shape as the showcase's cap in 0059.
--
-- Eight is a shelf. Unbounded is a place to put things, and every one of them
-- is a file this app pays for every month for as long as the account exists.
-- A picture that has been taken down does not hold a place: its owner should
-- not be left at seven forever by something they cannot even see.
create or replace function private.limit_profile_pictures()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
begin
  if (select count(*) from public.profile_pictures
      where profile_id = new.profile_id and taken_down_at is null) > 8 then
    raise exception 'A profile can show up to eight pictures.'
      using errcode = '54000';
  end if;
  return null;
end;
$$;

drop trigger if exists profile_pictures_capped on public.profile_pictures;
create constraint trigger profile_pictures_capped
after insert on public.profile_pictures
for each row execute function private.limit_profile_pictures();

-- ---------------------------------------------------------------------
-- Reading one
-- ---------------------------------------------------------------------

-- Through a function rather than the table, the same way `showcase_for` is,
-- and it hands back the song's audio with the picture so that tapping a
-- photograph of a gig plays the song from that night without a second round
-- trip that could answer differently.
--
-- The tie is checked again here rather than trusted from write time. A song
-- can be pulled off the Open Mic, deleted or moved after a picture was tied
-- to it, and a picture that still offered to play it would be a play button
-- that does nothing at best and a way into a private room at worst.
create or replace function public.gallery_for(target_profile uuid)
returns table (
  id uuid,
  storage_path text,
  caption text,
  song_id uuid,
  song_title text,
  song_storage_path text,
  song_duration_ms integer,
  -- Not `position`: Postgres will not take that as a returns-table column
  -- name, the same as 0063's showcase and 0164's sets.
  sort_position integer,
  -- True only on your own rows, and only until check-picture has been. It is
  -- what lets your own page say so rather than draw a picture other people
  -- cannot see and say nothing about it.
  waiting boolean
)
language sql
stable
security definer
set search_path = public
as $fn$
  select
    g.id,
    g.storage_path,
    g.caption,
    song.id,
    song.title,
    audio.storage_path,
    audio.duration_ms,
    g.position,
    g.passed_at is null
  from public.profile_pictures g
  left join lateral (
    select p.id, p.title
    from public.projects p
    where p.id = g.project_id
      and p.created_by = g.profile_id
      and p.deleted_at is null
      and p.open_mic_at is not null
  ) song on true
  left join lateral private.song_audio(song.id) audio on true
  where g.profile_id = target_profile
    and g.taken_down_at is null
    and (
      g.profile_id = (select auth.uid())
      or (g.passed_at is not null
          and private.profile_page_visible(target_profile))
    )
  order by g.position, g.created_at;
$fn$;

revoke all on function public.gallery_for(uuid) from public, anon;
grant execute on function public.gallery_for(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Reportable, and removable
-- ---------------------------------------------------------------------

-- A gallery picture is seen by people who did not choose it, which is the
-- test 0077 used when it gave room logos and song covers a kind of their own.
alter table public.content_reports
  add column if not exists target_picture uuid
  references public.profile_pictures(id) on delete cascade;

alter table public.content_reports
  drop constraint if exists content_reports_kind_check;

alter table public.content_reports
  add constraint content_reports_kind_check
  check (kind in (
    'profile', 'song', 'take', 'link', 'message',
    'room_logo', 'song_cover',
    'gallery_picture'
  ));

alter table public.content_reports
  drop constraint if exists content_reports_one_target;

alter table public.content_reports
  add constraint content_reports_one_target check (
    (case when target_profile is null then 0 else 1 end)
  + (case when target_project is null then 0 else 1 end)
  + (case when target_layer   is null then 0 else 1 end)
  + (case when target_link    is null then 0 else 1 end)
  + (case when target_room    is null then 0 else 1 end)
  + (case when target_picture is null then 0 else 1 end) = 1
  );

-- Restated from 0077, which is still its latest definition, with the ninth
-- argument and nothing else changed.
create or replace function public.report_content(
  in_kind text,
  in_reason text,
  in_detail text default '',
  in_profile uuid default null,
  in_project uuid default null,
  in_layer uuid default null,
  in_link uuid default null,
  in_room uuid default null,
  in_picture uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
declare
  new_report uuid;
begin
  insert into public.content_reports
    (reporter_id, kind, reason, detail,
     target_profile, target_project, target_layer, target_link, target_room,
     target_picture)
  values
    (auth.uid(), in_kind, in_reason, left(trim(coalesce(in_detail, '')), 1000),
     in_profile, in_project, in_layer, in_link, in_room, in_picture)
  returning id into new_report;

  return new_report;
end;
$fn$;

revoke all on function
  public.report_content(text, text, text, uuid, uuid, uuid, uuid, uuid, uuid)
  from public, anon;
grant execute on function
  public.report_content(text, text, text, uuid, uuid, uuid, uuid, uuid, uuid)
  to authenticated;

-- The eight-argument form would otherwise sit alongside the new one and take
-- every call that does not name the ninth — 0077's own reason for dropping
-- the seven-argument one.
drop function if exists
  public.report_content(text, text, text, uuid, uuid, uuid, uuid, uuid);

-- Restated from 0079, which is still its latest definition. Same shape, same
-- three branches, one more.
--
-- A gallery picture is marked rather than unpointed, because the row *is* the
-- pointer: deleting it would take the report that named it with it (every
-- target on content_reports cascades) and leave the queue with no record of
-- what was removed. Marked, it is gone from every read in this migration,
-- its owner's own page included, and the object still has to be deleted
-- through the Storage API — which is what the returned bucket and path are
-- for, and what tools/take_down.py does with them.
create or replace function public.take_down_image(
  target_report uuid,
  in_note text default ''
)
returns table (what text, bucket text, cleared_path text)
language plpgsql
security definer
set search_path = public
as $fn$
declare
  report record;
  removed text;
  in_bucket text;
  label text;
begin
  select * into report from public.content_reports where id = target_report;
  if not found then
    raise exception 'No report with that id.' using errcode = '22023';
  end if;

  -- Read the path before clearing it, in every branch. `update ... returning`
  -- hands back the new value, which is null by construction here, and the
  -- path is the whole point of what this returns.
  if report.kind = 'profile' then
    select avatar_path into removed from public.profiles
    where id = report.target_profile;
    update public.profiles set avatar_path = null
    where id = report.target_profile;
    in_bucket := 'avatars';
    label := 'profile picture';

  elsif report.kind = 'room_logo' then
    select logo_path into removed from public.rooms
    where id = report.target_room;
    update public.rooms set logo_path = null where id = report.target_room;
    in_bucket := 'room-files';
    label := 'room logo';

  elsif report.kind = 'song_cover' then
    select cover_image_path into removed from public.projects
    where id = report.target_project;
    update public.projects set cover_image_path = null
    where id = report.target_project;
    in_bucket := 'room-files';
    label := 'song cover';

  elsif report.kind = 'gallery_picture' then
    select storage_path into removed from public.profile_pictures
    where id = report.target_picture;
    update public.profile_pictures set taken_down_at = now()
    where id = report.target_picture and taken_down_at is null;
    in_bucket := 'avatars';
    label := 'gallery picture';

  else
    raise exception
      'take_down_image handles profile, room_logo, song_cover and '
      'gallery_picture, not %.', report.kind
      using errcode = '22023';
  end if;

  perform public.resolve_report(
    target_report,
    'actioned',
    case
      when nullif(trim(coalesce(in_note, '')), '') is null
        then 'Image unpointed; object deletion pending.'
      else 'Image unpointed; object deletion pending. ' || trim(in_note)
    end
  );

  return query select label, in_bucket, removed;
end;
$fn$;

revoke all on function public.take_down_image(uuid, text)
  from public, anon, authenticated;

comment on function public.take_down_image(uuid, text) is
  'Clears a reported image from the row the app reads and closes the report, '
  'then returns the bucket and path the caller must delete through the '
  'Storage API — SQL is not allowed to delete a stored object. Not a '
  'complete takedown on its own: use tools/take_down.py. Service key only.';
