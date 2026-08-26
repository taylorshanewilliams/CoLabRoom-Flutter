-- Hear about the crashes that happen before anyone signs in.
--
-- analysis_errors admits inserts only from an authenticated user, which
-- leaves exactly one blind spot and it is the worst one available: the sign-in
-- screen. That is the first thing every new person sees, a crash there loses
-- them completely, and until now it produced no row, no signal and no way to
-- know it had happened. An iOS tester reporting "the app is down" with nothing
-- in the table is indistinguishable from an iOS tester being wrong.
--
-- The obvious fix — let `anon` insert into the table — is not one. It would
-- hand anybody on the internet an unbounded, unauthenticated write into a
-- table nothing else limits. So the write goes through a function instead,
-- which is the only thing anon may call and which decides what it accepts.
--
-- Three guards, each closing a different hole:
--
--   Shape. Severity and service come from fixed lists and the message is
--   truncated hard. A caller cannot invent a service, or store a novel.
--
--   Repetition. The same signature is accepted at most once every ten
--   minutes. That mirrors the cooldown the client already applies to itself,
--   and it means a crash loop costs six rows an hour rather than thousands.
--
--   Volume. A ceiling on anonymous rows per hour, across everybody. Past it
--   the function returns quietly rather than failing, because a caller being
--   rate-limited is not something the app should surface or retry.
--
-- Worst case under all three: a determined flood fills the hourly ceiling and
-- the real reports for that hour are lost. That is a bad hour. Unbounded
-- writes would be a bad month.

alter table public.analysis_errors
  alter column user_id drop not null;

-- Which reports arrived without a session. Kept as its own column rather than
-- inferred from `user_id is null`, because a signed-in user's account can be
-- deleted later and that sets user_id to null too — the two look identical
-- afterwards and mean completely different things.
alter table public.analysis_errors
  add column if not exists anonymous boolean not null default false;

create index if not exists analysis_errors_anonymous_idx
  on public.analysis_errors (created_at desc)
  where anonymous;

create or replace function public.report_anonymous_error(
  in_service text,
  in_message text,
  in_stage text default null,
  in_severity text default 'error',
  in_app_version text default null,
  in_platform text default null
)
returns void
language plpgsql
security definer set search_path = ''
as $$
declare
  recent_total integer;
  clean_message text;
  clean_service text;
  clean_severity text;
begin
  clean_message := left(coalesce(trim(in_message), ''), 2000);
  if clean_message = '' then
    return;
  end if;

  -- A short allowlist rather than free text. Everything that legitimately
  -- reports before sign-in is one of these, and an unrecognised service is
  -- either a bug in the caller or somebody else's traffic.
  clean_service := case
    when in_service in ('app', 'auth', 'startup') then in_service
    else 'app'
  end;
  clean_severity := case when in_severity = 'warning' then 'warning' else 'error' end;

  select count(*) into recent_total
  from public.analysis_errors
  where anonymous and created_at > now() - interval '1 hour';

  -- 120 an hour. A real crash loop on a real device produces a handful; this
  -- is far above any honest volume and far below anything that would matter
  -- to storage.
  if recent_total >= 120 then
    return;
  end if;

  -- The signature is derived by the existing trigger, so it cannot be read
  -- before the row exists. Matching on the message prefix is the closest
  -- thing available before insert, and is enough to stop a loop repeating
  -- itself: identical crashes have identical first lines.
  if exists (
    select 1 from public.analysis_errors
    where anonymous
      and created_at > now() - interval '10 minutes'
      and left(message, 200) = left(clean_message, 200)
  ) then
    return;
  end if;

  insert into public.analysis_errors
    (user_id, anonymous, severity, service, stage, message, app_version, platform)
  values
    (null, true, clean_severity, clean_service, left(coalesce(in_stage, ''), 60),
     clean_message, left(coalesce(in_app_version, ''), 40),
     left(coalesce(in_platform, ''), 40));
end;
$$;

-- The function is the only thing anon may reach. The table itself stays
-- closed to them, so this is the whole of the surface being opened.
revoke all on function public.report_anonymous_error(text, text, text, text, text, text) from public;
grant execute on function public.report_anonymous_error(text, text, text, text, text, text)
  to anon, authenticated;
