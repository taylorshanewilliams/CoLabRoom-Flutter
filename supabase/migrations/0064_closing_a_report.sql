-- Closing a report.
--
-- 0063 gave people a way to file one. This is the other end: a way to say
-- what was done about it, so the queue drains and the record of what happened
-- survives.
--
-- Both halves matter and the second is the one that usually gets skipped.
-- App Store Review Guideline 1.2 asks for a report mechanism *and* timely
-- responses; a table that only grows is the first without the second. And
-- §512's repeat infringer policy has to run on something — you cannot
-- terminate the account of somebody who has infringed three times if nothing
-- recorded the first two.
--
-- **Deliberately not callable from a phone.** There is no moderator role in
-- this app and inventing one for a single operator would be a permissions
-- system with one row in it. This runs with the service key, through the
-- same query workflow every other operational task uses. When the volume
-- justifies a screen, the screen calls this function and nothing else
-- changes.

create or replace function public.resolve_report(
  target_report uuid,
  in_status text,
  in_note text default ''
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if in_status not in ('actioned', 'dismissed') then
    raise exception 'A report is either actioned or dismissed.'
      using errcode = '22023';
  end if;

  update public.content_reports
  set status = in_status,
      reviewed_at = now(),
      -- Appended rather than replaced. A report that was dismissed and later
      -- actioned has a history worth keeping, and the history is the thing a
      -- repeat infringer policy is built on.
      detail = case
        when nullif(trim(coalesce(in_note, '')), '') is null then detail
        else left(
          detail || case when detail = '' then '' else E'\n\n' end
            || '[' || to_char(now(), 'YYYY-MM-DD') || ' ' || in_status || '] '
            || trim(in_note),
          4000)
      end
  where id = target_report;

  if not found then
    raise exception 'No report with that id.' using errcode = '22023';
  end if;
end;
$$;

-- Nobody holding a phone, including the person who filed it. Closing your own
-- report would let somebody clear a record of what they did.
revoke all on function public.resolve_report(uuid, text, text)
  from public, anon, authenticated;

-- The detail column has to hold the original plus the notes appended above.
alter table public.content_reports
  drop constraint if exists content_reports_detail_check;
alter table public.content_reports
  add constraint content_reports_detail_check
  check (char_length(detail) <= 4000);

-- ---------------------------------------------------------------------
-- How many times has this account been the subject of one?
-- ---------------------------------------------------------------------

-- The number the repeat infringer policy on colabroom.com counts.
--
-- Only reports that were actioned, and only copyright ones — a dismissed
-- report is not a strike, and neither is a harassment report, which is a
-- different policy with a different remedy. Counting the wrong thing here
-- would mean terminating somebody's account over a complaint nobody upheld.
create or replace function public.copyright_strikes(target_person uuid)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select count(*)
  from public.content_reports r
  where r.status = 'actioned'
    and r.reason = 'copyright'
    and (
      r.target_profile = target_person
      or exists (
        select 1 from public.projects p
        where p.id = r.target_project and p.account_id = target_person
      )
      or exists (
        select 1 from public.song_layers l
        where l.id = r.target_layer and l.recorded_by = target_person
      )
      or exists (
        select 1 from public.profile_links pl
        where pl.id = r.target_link and pl.profile_id = target_person
      )
    );
$$;

revoke all on function public.copyright_strikes(uuid)
  from public, anon, authenticated;
