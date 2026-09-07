-- A takedown that actually removes something.
--
-- The app could receive a complaint about a profile picture and could not act
-- on it. Three gaps, and they compound:
--
--   * **No limits on the buckets.** No size cap and no type restriction, so
--     the only thing standing between the app and a 200MB file that is not an
--     image was the picker on the phone.
--   * **Two of the three images were not reportable at all.** `content_reports`
--     knew about profiles, songs, takes, links and messages. A room logo and a
--     song cover — both visible to people who did not upload them — had no
--     kind, so there was no way to file anything about either.
--   * **`resolve_report` removed nothing.** It set a status and appended a
--     note. "Actioned" was a word in a log; the picture stayed exactly where
--     it was, still visible to every signed-in account.
--
-- App Store Guideline 1.2 asks for a way to report *and* a timely response,
-- and a response that changes nothing is the first without the second. The
-- sharper reason is 18 U.S.C. § 2258A: there is no duty to go looking, but
-- once a provider has actual knowledge of apparent child sexual abuse
-- material there is a duty to act and to report it. Acting requires a way to
-- take something down, and this app had none.

-- ---------------------------------------------------------------------
-- Limits on the buckets
-- ---------------------------------------------------------------------

-- **Size everywhere, type only where the upload path is unambiguous.**
--
-- The size cap is enforced by the storage service against the actual bytes,
-- so it holds whatever a client claims. The type list is checked against the
-- *declared* content type, which the client chooses — so it catches accidents
-- and misconfigured uploads, and does not pretend to stop somebody determined
-- to mislabel a file. It is worth having for exactly what it is.
--
-- `avatars` and `feedback-screenshots` each have one upload path in this app
-- and carry one kind of thing, so a list is safe there.
--
-- `room-files` deliberately gets no type list. It carries reference
-- recordings, takes, stems, room logos and song covers, written from four
-- different services in wav, mp4, flac, ogg, mpeg and png — and an incomplete
-- list would reject a real upload. This app has already lost three rounds of
-- device testing to an upload that failed where nobody could see it; a
-- guess here would buy very little and risk exactly that again.
update storage.buckets
set file_size_limit = 5 * 1024 * 1024,
    allowed_mime_types = array[
      'image/png', 'image/jpeg', 'image/webp',
      -- What a modern iPhone actually produces.
      'image/heic', 'image/heif'
    ]
where id = 'avatars';

update storage.buckets
set file_size_limit = 10 * 1024 * 1024,
    allowed_mime_types = array['image/png', 'image/jpeg', 'image/webp']
where id = 'feedback-screenshots';

-- Generous, because a long take at 48kHz is genuinely large, and low enough
-- that nobody is storing a film here.
update storage.buckets
set file_size_limit = 200 * 1024 * 1024
where id in ('room-files', 'studio-drafts');

-- ---------------------------------------------------------------------
-- Everything visible is reportable
-- ---------------------------------------------------------------------

alter table public.content_reports
  add column if not exists target_room uuid
  references public.rooms(id) on delete cascade;

alter table public.content_reports
  drop constraint if exists content_reports_kind_check;

alter table public.content_reports
  add constraint content_reports_kind_check
  check (kind in (
    'profile', 'song', 'take', 'link', 'message',
    -- The two images nobody could report. Both are seen by people who did
    -- not choose them: a logo by everybody in the room, a cover by anybody
    -- the song reaches.
    'room_logo', 'song_cover'
  ));

alter table public.content_reports
  drop constraint if exists content_reports_one_target;

alter table public.content_reports
  add constraint content_reports_one_target check (
    (case when target_profile is null then 0 else 1 end)
  + (case when target_project is null then 0 else 1 end)
  + (case when target_layer   is null then 0 else 1 end)
  + (case when target_link    is null then 0 else 1 end)
  + (case when target_room    is null then 0 else 1 end) = 1
  );

create or replace function public.report_content(
  in_kind text,
  in_reason text,
  in_detail text default '',
  in_profile uuid default null,
  in_project uuid default null,
  in_layer uuid default null,
  in_link uuid default null,
  in_room uuid default null
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
     target_profile, target_project, target_layer, target_link, target_room)
  values
    (auth.uid(), in_kind, in_reason, left(trim(coalesce(in_detail, '')), 1000),
     in_profile, in_project, in_layer, in_link, in_room)
  returning id into new_report;

  return new_report;
end;
$fn$;

revoke all on function
  public.report_content(text, text, text, uuid, uuid, uuid, uuid, uuid)
  from public, anon;
grant execute on function
  public.report_content(text, text, text, uuid, uuid, uuid, uuid, uuid)
  to authenticated;

-- The seven-argument form would otherwise sit alongside the new one and take
-- every call that does not name the eighth.
drop function if exists
  public.report_content(text, text, text, uuid, uuid, uuid, uuid);

-- ---------------------------------------------------------------------
-- Taking it down
-- ---------------------------------------------------------------------

-- **What this does and what it deliberately does not.**
--
-- It clears the column the app reads, so the picture stops being shown
-- anywhere, immediately, to everybody. It deletes the `storage.objects` row,
-- which is what the storage API answers from — so the path stops resolving
-- and no signed URL can be made for it, including any already issued, because
-- signing checks the row.
--
-- It does **not** guarantee the bytes are gone from the underlying store.
-- SQL cannot reach S3. For an ordinary abusive avatar that is fine. For
-- anything that has to be destroyed rather than merely unreachable, the
-- returned path is the thing to hand to the storage API — which is why this
-- returns it rather than swallowing it.
--
-- **Not callable from a phone**, the same as `resolve_report` and for the
-- same reason: there is no moderator role in this app, and inventing one for
-- a single operator would be a permissions system with one row in it. This
-- runs with the service key through the query workflow.
create or replace function public.take_down_image(
  target_report uuid,
  in_note text default ''
)
returns table (what text, cleared_path text)
language plpgsql
security definer
set search_path = public
as $fn$
declare
  report record;
  removed text;
  bucket text;
  label text;
begin
  select * into report from public.content_reports where id = target_report;
  if not found then
    raise exception 'No report with that id.' using errcode = '22023';
  end if;

  -- Read the path before clearing it, in every branch. `update ... returning`
  -- hands back the *new* value, which is null by construction here, and the
  -- path is the whole point of what this returns.
  if report.kind = 'profile' then
    select avatar_path into removed from public.profiles
    where id = report.target_profile;
    update public.profiles set avatar_path = null
    where id = report.target_profile;
    bucket := 'avatars';
    label := 'profile picture';

  elsif report.kind = 'room_logo' then
    select logo_path into removed from public.rooms
    where id = report.target_room;
    update public.rooms set logo_path = null where id = report.target_room;
    bucket := 'room-files';
    label := 'room logo';

  elsif report.kind = 'song_cover' then
    select cover_image_path into removed from public.projects
    where id = report.target_project;
    update public.projects set cover_image_path = null
    where id = report.target_project;
    bucket := 'room-files';
    label := 'song cover';

  else
    raise exception
      'take_down_image handles profile, room_logo and song_cover, not %.',
      report.kind
      using errcode = '22023';
  end if;

  -- Unreachable from the storage API the moment this row is gone.
  if removed is not null then
    delete from storage.objects o
    where o.bucket_id = bucket and o.name = removed;
  end if;

  -- One call, so a takedown cannot leave the queue saying it is still open.
  perform public.resolve_report(
    target_report,
    'actioned',
    case
      when nullif(trim(coalesce(in_note, '')), '') is null
        then 'Image removed.'
      else 'Image removed. ' || trim(in_note)
    end
  );

  return query select label, coalesce(removed, '(there was none)');
end;
$fn$;

revoke all on function public.take_down_image(uuid, text)
  from public, anon, authenticated;

comment on function public.take_down_image(uuid, text) is
  'Clears a reported image and makes its object unreachable, then closes the '
  'report. Returns the storage path so the bytes can also be destroyed '
  'through the storage API when unreachable is not enough. Service key only.';
