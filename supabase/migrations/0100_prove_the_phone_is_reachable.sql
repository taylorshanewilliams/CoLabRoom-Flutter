-- Two questions the app could not answer about its own notifications.
--
-- Established 2026-09-10 by querying production: `device_tokens` holds
-- **zero rows and always has**, while `notifications` holds 184. Every part
-- of the delivery chain is built and deployed -- register_device_token
-- exists and `authenticated` may call it, the notifications_deliver trigger
-- is on the table, push_config is populated, the send-push function was
-- deployed on 6 September -- and none of it has ever carried a single
-- notification to a phone, because no phone has ever registered.
--
-- Nothing here fixes that. Registration is a client-side act and, on iOS, it
-- is blocked on an APNs key that has never been created. What these two
-- functions fix is that the failure was **unobservable**: the app told
-- people notifications reached their phone while this table was empty, and
-- the only way to know otherwise was to query the database by hand.

-- Whether this account has a phone that could receive a notification.
--
-- Deliberately not a count of rows the caller could read for themselves:
-- `device_tokens` is closed to clients entirely, because a token is a
-- credential -- anybody holding one can be sent notifications as that
-- device. This returns the fact and not the token.
create or replace function public.push_reaches_me()
returns boolean
language sql
security definer set search_path = ''
stable
as $$
  select exists (
    select 1 from public.device_tokens where user_id = auth.uid()
  );
$$;

revoke all on function public.push_reaches_me() from public, anon;
grant execute on function public.push_reaches_me() to authenticated;

-- Prove the whole chain, from a button, in one tap.
--
-- Inserts a real notification for the caller, which fires the real trigger,
-- which calls the real function, which talks to the real FCM. There is no
-- test path: a test that exercises a shortcut proves the shortcut works.
--
-- The row is a `project_update` because the enum has no member for this and
-- adding one would put a value in the type that only ever appears in tests.
-- It reads as what it is in the inbox.
create or replace function public.send_myself_a_test_notification()
returns boolean
language plpgsql
security definer set search_path = ''
as $$
declare
  reachable boolean;
  recent integer;
begin
  if auth.uid() is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;

  -- Said rather than sent. A test that silently succeeds while no phone is
  -- registered is the exact failure this whole migration exists to end.
  select exists (select 1 from public.device_tokens where user_id = auth.uid())
    into reachable;
  if not reachable then
    return false;
  end if;

  -- Three an hour. Enough to test a fix a couple of times, and not enough to
  -- turn a button into a way of notifying yourself forever, or somebody
  -- else's phone if a token is ever mis-assigned.
  select count(*) into recent
  from public.notifications
  where user_id = auth.uid()
    and type = 'project_update'
    and title = 'Test notification'
    and created_at > now() - interval '1 hour';
  if recent >= 3 then
    raise exception 'That is enough tests for one hour.' using errcode = '53400';
  end if;

  insert into public.notifications (user_id, type, title, body)
  values (
    auth.uid(),
    'project_update',
    'Test notification',
    'If this arrived on your phone with the app closed, notifications work.'
  );
  return true;
end;
$$;

revoke all on function public.send_myself_a_test_notification() from public, anon;
grant execute on function public.send_myself_a_test_notification() to authenticated;
