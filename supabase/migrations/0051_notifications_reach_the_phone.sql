-- Hands each new notification to the sender, so it reaches a phone rather
-- than waiting to be found.
--
-- The trigger is deliberately thin. It does not decide who to tell, does not
-- format anything, and does not know what FCM is — every one of those
-- decisions already happened by the time a row exists in `notifications`.
-- It hands the row to an Edge Function and gets out of the way.
--
-- The call is made through pg_net, which queues the request and returns
-- immediately. That matters more than it looks: this trigger runs inside the
-- transaction that inserts the notification, which is itself inside whatever
-- the user was doing — accepting an invite, asking for a bridge. A synchronous
-- HTTP call there would put the latency of Google's servers inside the time it
-- takes to tap a button, and an outage would stop people using the app rather
-- than merely stop their phones buzzing.

-- pg_net is a Supabase extension and is not present on the plain Postgres the
-- smoke test replays these migrations against. Asking for it conditionally
-- keeps this file runnable in both places; 00_shim.sql provides a no-op
-- net.http_post so the trigger body still executes there.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_net') then
    create extension if not exists pg_net;
  end if;
end $$;

-- Where to send, and the secret that proves it was us.
--
-- A table rather than a constant in this file, because both values are
-- environment-specific and one of them is a credential. Migrations live in
-- git; this is populated once, by hand, against the real project. Until it is,
-- the trigger does nothing at all and notifications behave exactly as they did
-- before — which is the correct behaviour for a half-configured deployment,
-- rather than an error surfacing in front of somebody accepting an invite.
create table if not exists private.push_config (
  -- One row, enforced. A second row would silently mean half the
  -- notifications went to one place and half to another.
  id boolean primary key default true check (id),
  function_url text not null,
  hook_secret text not null
);

revoke all on table private.push_config from public, anon, authenticated;

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

drop trigger if exists notifications_deliver on public.notifications;
create trigger notifications_deliver
after insert on public.notifications
for each row execute function private.deliver_notification();

-- How to turn this on, once, against the real project:
--
--   insert into private.push_config (function_url, hook_secret)
--   values (
--     'https://<project-ref>.supabase.co/functions/v1/send-push',
--     '<the same value as the PUSH_HOOK_SECRET function secret>'
--   );
--
-- and to turn it off again without a deploy:
--
--   delete from private.push_config;
