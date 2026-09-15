-- Two things the app could not tell Taylor about his own phone.
--
-- 15 September 2026. His tester on iOS sent him two messages, 17:48:01 and
-- 17:49:05 UTC. Both created a notification, both went down the real path,
-- and the push sender's own reply is in the pg_net log:
--
--   17:48:01  200  {"sent":2,"pruned":0}
--   17:49:05  200  {"sent":2,"pruned":0}
--   17:50:40  200  {"sent":0,"reason":"no devices"}   <- his reply, iOS
--
-- FCM accepted delivery to two of his Android devices. He saw nothing. And
-- when we went to read the receipts that 0117 added for exactly this
-- question, there was nothing to read: his notifications table was empty.
--
-- Both failures are ours, and they are the reason the investigation stalled
-- rather than the reason the push did not arrive.
--
-- **The receipt died with the inbox.** 0117 put `arrived_at` and
-- `arrived_how` on `notifications`, and `notifications` is the inbox --
-- people delete from it. There is a Clear-read button on the notifications
-- screen and a per-row delete, both of which are right, and both of which
-- take the only evidence that a push was ever drawn on a phone. A receipt
-- stored inside the thing it is a receipt for is not a receipt.
--
-- **Nobody could tell his two devices apart.** `device_tokens` holds a
-- token, a platform and two timestamps. Two rows both saying `android` is
-- all anybody could see, so "is my actual phone registered, or is that the
-- emulator?" had no answer -- and on this machine the emulator is used for
-- testing every day, which makes the question a real one rather than a
-- pedantic one.

-- ---------------------------------------------------------------------
-- The receipt, kept somewhere it cannot be swept away
-- ---------------------------------------------------------------------

-- One row per push actually queued to a registered device, and what the
-- phone said about it afterwards.
--
-- **`notification_id` deliberately has no foreign key.** Every other id
-- column in this schema references its table with `on delete cascade`, and
-- doing that here would rebuild the exact bug this migration exists to fix:
-- clearing the inbox would cascade the receipts away again. The id is kept
-- as a plain uuid so the record of a delivery outlives the message that
-- caused it. That is the entire point, so nobody should "tidy" it later.
--
-- It holds no content -- no title, no body, no actor. A row says that a
-- push went out and whether a phone drew it, which is all the delivery
-- question needs and nothing a leak would be interesting for.
create table if not exists public.push_arrivals (
  notification_id uuid primary key,

  user_id uuid not null references public.profiles(id) on delete cascade,

  -- When the trigger handed it to the sender. Named for what it is: the
  -- database knows the push was queued, never that it was delivered.
  queued_at timestamptz not null default now(),

  arrived_at timestamptz,
  arrived_how text check (arrived_how in ('closed', 'open', 'tapped'))
);

create index if not exists push_arrivals_user_queued_idx
  on public.push_arrivals (user_id, queued_at desc);

alter table public.push_arrivals enable row level security;

-- Read your own. There is deliberately no insert, update or delete policy:
-- every write happens through the two security-definer functions below, and
-- a client that could delete these could destroy its own evidence, which is
-- the bug being fixed.
drop policy if exists push_arrivals_read_own on public.push_arrivals;
create policy push_arrivals_read_own on public.push_arrivals
for select to authenticated using (user_id = (select auth.uid()));

comment on table public.push_arrivals is
  'One row per push queued to a registered device, and what the phone said '
  'about it. Survives deletion of the notification on purpose: do not add a '
  'foreign key to public.notifications. Written only by '
  'private.deliver_notification and public.push_arrived.';

-- Whatever receipts are still in the inbox, moved somewhere they will keep.
--
-- Expected to find nothing: on the day this was written every notification
-- in production had a null `arrived_at`, because the only account with a
-- registered phone had already cleared its inbox. It runs anyway, because a
-- receipt filed between writing this and applying it is exactly the kind of
-- evidence this migration exists to stop losing.
--
-- Only rows a phone actually confirmed. A notification with no arrival says
-- nothing about whether a push was queued for it, and inventing a queued_at
-- for one would put a number in the report that nothing supports.
insert into public.push_arrivals
  (notification_id, user_id, queued_at, arrived_at, arrived_how)
select n.id, n.user_id, n.created_at, n.arrived_at, n.arrived_how
from public.notifications n
where n.arrived_at is not null
on conflict (notification_id) do nothing;

-- ---------------------------------------------------------------------
-- Recording the send, at the one place that knows it happened
-- ---------------------------------------------------------------------

-- Same as 0051 plus three lines: before handing the row to the sender, write
-- down that we did.
--
-- Only when the account has a device registered. A notification for somebody
-- with no phone is not a push that failed to arrive, and counting it as one
-- would make the report read "six sent, none arrived" for an account that
-- never had a phone -- the precise false alarm 0100 was written to end.
create or replace function private.deliver_notification()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
declare
  config private.push_config%rowtype;
begin
  select * into config from private.push_config limit 1;
  if config.function_url is null then
    return new;
  end if;

  -- The receipt, before the attempt, so a send that crashes the sender still
  -- leaves a trace that it was tried.
  if exists (
    select 1 from public.device_tokens where user_id = new.user_id
  ) then
    insert into public.push_arrivals (notification_id, user_id, queued_at)
    values (new.id, new.user_id, now())
    on conflict (notification_id) do nothing;
  end if;

  -- Telemetry must never break the thing it is watching, and neither must
  -- delivery. A notification that reached the database but not the phone is a
  -- notification the person will still see next time they open the app; an
  -- exception here would roll back the invite, the ask, or the take that
  -- caused it.
  begin
    perform net.http_post(
      url := config.function_url,
      body := to_jsonb(new),
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-push-secret', config.hook_secret
      )
    );
  exception when others then
    raise warning 'push delivery could not be queued: %', sqlerrm;
  end;

  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- The phone, saying it got one
-- ---------------------------------------------------------------------

-- Unchanged rules, written to both places. `notifications` still carries the
-- stamp, because the inbox can usefully show it while the row is there;
-- `push_arrivals` carries it for keeps.
--
-- The first arrival wins, except that a tap always records itself, because
-- "they opened it" is the stronger fact than "it was drawn".
create or replace function public.push_arrived(notification_id uuid, how text)
returns void
language plpgsql
security definer set search_path = ''
as $$
declare
  -- Copied into locals on purpose. `notification_id` is both this function's
  -- parameter and a column of push_arrivals, and the insert below puts the
  -- table in scope; 0120 lost a run to exactly that ambiguity. Locals that
  -- share no name with any column leave nothing to resolve.
  the_id uuid := notification_id;
  me uuid := auth.uid();
begin
  if me is null then
    return;
  end if;
  if how not in ('closed', 'open', 'tapped') then
    raise exception 'Unknown arrival.' using errcode = '22023';
  end if;

  update public.notifications n
  set arrived_at = coalesce(n.arrived_at, now()),
      arrived_how = case
        when how = 'tapped' then 'tapped'
        else coalesce(n.arrived_how, how)
      end
  where n.id = the_id
    and n.user_id = me
    and (n.arrived_at is null or how = 'tapped')
    and (n.arrived_how is distinct from how);

  -- The keeping copy. Inserted rather than only updated, because a phone can
  -- report an arrival for a push queued before this table existed, and
  -- because the caller's own account is the only one it can write to.
  insert into public.push_arrivals as a
    (notification_id, user_id, queued_at, arrived_at, arrived_how)
  values (the_id, me, now(), now(), how)
  on conflict (notification_id) do update
  set arrived_at = coalesce(a.arrived_at, now()),
      arrived_how = case
        when how = 'tapped' then 'tapped'
        else coalesce(a.arrived_how, how)
      end
  where a.user_id = me;
end;
$$;

revoke all on function public.push_arrived(uuid, text) from public, anon;
grant execute on function public.push_arrived(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- The week, counted from the receipts instead of the inbox
-- ---------------------------------------------------------------------

-- Same five numbers, same names, same meanings -- read from a table that
-- clearing the inbox does not touch. Counted from the first registration
-- rather than from the dawn of the account, so a phone registered this
-- morning is not blamed for last month.
create or replace function public.push_delivery_report()
returns table (
  sent integer,
  arrived integer,
  arrived_closed integer,
  last_sent_at timestamptz,
  last_arrived_at timestamptz
)
language sql
security definer set search_path = ''
stable
as $$
  with since as (
    select greatest(
      now() - interval '7 days',
      coalesce((select min(created_at) from public.device_tokens
                where user_id = auth.uid()), now() - interval '7 days')
    ) as at
  )
  select
    count(*)::integer as sent,
    count(a.arrived_at)::integer as arrived,
    count(*) filter (where a.arrived_how = 'closed')::integer as arrived_closed,
    max(a.queued_at) as last_sent_at,
    max(a.arrived_at) as last_arrived_at
  from public.push_arrivals a, since
  where a.user_id = auth.uid()
    and a.queued_at >= since.at;
$$;

revoke all on function public.push_delivery_report() from public, anon;
grant execute on function public.push_delivery_report() to authenticated;

-- ---------------------------------------------------------------------
-- Which phones these actually are
-- ---------------------------------------------------------------------

-- Your own devices, enough of each to tell them apart, and no token.
--
-- `device_tokens` is closed to clients entirely, because a token is a
-- credential: anybody holding one can be sent notifications as that device.
-- What comes back here is the last six characters, which identify a row
-- without being usable as an address -- so the app can mark which row is the
-- phone somebody is holding, and every other row is then plainly a different
-- device. That is the whole question: two rows saying `android` were
-- indistinguishable, and one of them on this project is usually an emulator
-- that can never draw a notification.
--
-- Ordered most recently seen first, which is the order somebody reads it in.
create or replace function public.my_devices()
returns table (
  token_tail text,
  platform text,
  first_seen_at timestamptz,
  last_seen_at timestamptz
)
language sql
security definer set search_path = ''
stable
as $$
  select
    right(d.token, 6) as token_tail,
    d.platform,
    d.created_at as first_seen_at,
    d.last_seen_at
  from public.device_tokens d
  where d.user_id = auth.uid()
  order by d.last_seen_at desc;
$$;

revoke all on function public.my_devices() from public, anon;
grant execute on function public.my_devices() to authenticated;

-- ---------------------------------------------------------------------
-- What this table is not
-- ---------------------------------------------------------------------
--
-- There is no cleanup job, and that is a decision rather than an oversight.
-- `push_arrivals` gains one row per push actually queued to a phone; this
-- project has queued fewer than two hundred in its life, and the whole table
-- will be smaller than a single song's analysis for a long time. When there
-- are enough accounts for that to stop being true, the answer is a scheduled
-- prune of rows older than the report's own window, added the way
-- expire-stems was: with a schedule, not as a manual job nobody watches.
