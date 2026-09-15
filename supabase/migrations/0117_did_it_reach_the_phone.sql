-- Did it reach the phone?
--
-- Taylor, 14 Sep: "I am not sure if notifications are actually working as
-- pushes to the phone. I've only gotten them to work when I do the test in
-- the options, but never actually gotten a notification to my phone from a
-- real event."
--
-- The server's view that evening: one registered token, his Android phone,
-- created on the 10th and seen again that night; six pushes to it in the
-- day, every one accepted by FCM with {"sent":1}. And that is where the
-- server's knowledge ends. FCM accepting a message says the message left
-- the building. Whether the phone drew it -- in the tray with the app
-- closed, or as a banner with it open -- is a fact only the phone has, and
-- until now the phone kept it to itself.
--
-- So the phone now reports back. When a push arrives, the app calls
-- push_arrived with the notification's id and how it arrived: 'closed' (the
-- background handler ran, which means the phone received it with the app
-- not in front), 'open' (it arrived while the app was in front and the app
-- drew it), or 'tapped' (the person opened the app from it). The receipt
-- is a column on the notification itself, so the inbox, the health check
-- and the settings screen can all answer the question with the same row.
--
-- The settings screen gets one honest sentence out of it: of the last
-- week's notifications, how many reached a phone, and how many of those
-- with the app closed -- the half of the question the test button cannot
-- reach. "Six sent, six arrived" ends the doubt; "six sent, none arrived"
-- names the bug.

alter table public.notifications
  add column if not exists arrived_at timestamptz,
  add column if not exists arrived_how text
    check (arrived_how in ('closed', 'open', 'tapped'));

-- The phone, saying it got one. Own rows only; the first arrival wins,
-- except that a tap always records itself, because "they opened it" is the
-- stronger fact than "it was drawn".
create or replace function public.push_arrived(notification_id uuid, how text)
returns void
language plpgsql
security definer set search_path = ''
as $$
begin
  if auth.uid() is null then
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
  where n.id = notification_id
    and n.user_id = auth.uid()
    and (n.arrived_at is null or how = 'tapped')
    and (n.arrived_how is distinct from how);
end;
$$;

revoke all on function public.push_arrived(uuid, text) from public, anon;
grant execute on function public.push_arrived(uuid, text) to authenticated;

-- The week, in numbers the settings screen can say.
--
-- sent: notifications written for you while you had a phone registered --
-- each of those went down the real path to FCM. arrived: the phone said so.
-- arrived_closed: the phone said so with the app not in front, which is the
-- only delivery the test button cannot prove. Counted from the first
-- registration rather than from the dawn of the account, so a phone
-- registered this morning is not blamed for last month.
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
    count(n.arrived_at)::integer as arrived,
    count(*) filter (where n.arrived_how = 'closed')::integer as arrived_closed,
    max(n.created_at) as last_sent_at,
    max(n.arrived_at) as last_arrived_at
  from public.notifications n, since
  where n.user_id = auth.uid()
    and n.created_at >= since.at;
$$;

revoke all on function public.push_delivery_report() from public, anon;
grant execute on function public.push_delivery_report() to authenticated;
