-- Where to reach somebody when the app is closed.
--
-- 0018 built the whole notification system and said so in its first lines:
-- "No push/FCM/APNs here — in-app only." That was the right call then and is
-- the wrong state now. Every notification this app has ever produced appears
-- only if you happen to open the app, which makes an ask a message left on a
-- desk nobody is sitting at — and an ask nobody is told about is the exact
-- defect 0049 exists to fix.
--
-- This table is the address book. The sender is an Edge Function watching
-- `notifications`, so nothing that writes a notification today has to change:
-- the row already carries the title, the body and who it is for.

create table public.device_tokens (
  -- The token is the primary key rather than (user_id, token), and that is
  -- deliberate. A device token belongs to an *installation*, not a person, and
  -- one phone can be signed into two accounts over its life. Keying on the
  -- token means signing in as somebody else moves the row instead of adding a
  -- second one — so the previous account's notifications stop arriving on a
  -- phone they no longer own. Keying on the pair would leave both rows behind
  -- and deliver one person's inbox to another person's lock screen.
  token text primary key,

  user_id uuid not null default auth.uid()
    references public.profiles(id) on delete cascade,

  platform text not null check (platform in ('ios', 'android', 'web')),

  -- Stamped every launch. FCM expires tokens that have not been seen for a
  -- couple of months, and a table that never forgets is a table that spends
  -- every send on addresses nobody lives at.
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create index device_tokens_user_idx on public.device_tokens (user_id);

alter table public.device_tokens enable row level security;

-- Your own devices, and nobody else's. There is no reason for one member of a
-- room to learn what somebody else is carrying, and the sender runs with the
-- service role, which bypasses this entirely.
create policy device_tokens_read_own on public.device_tokens
for select to authenticated using (user_id = (select auth.uid()));

create policy device_tokens_write_own on public.device_tokens
for insert to authenticated with check (user_id = (select auth.uid()));

create policy device_tokens_update_own on public.device_tokens
for update to authenticated using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

-- Signing out has to be able to remove the row. A phone that keeps receiving
-- somebody's notifications after they signed out is the worst version of this
-- feature.
create policy device_tokens_delete_own on public.device_tokens
for delete to authenticated using (user_id = (select auth.uid()));

-- Registering a device, in one call.
--
-- A function rather than an upsert from the client because the interesting
-- case is the one an upsert gets wrong: the token already exists against a
-- *different* user, because this phone was signed into another account. The
-- row has to move rather than conflict, and the person who is signed in now
-- has to end up owning it.
create or replace function public.register_device_token(
  device_token text,
  device_platform text
)
returns void
language plpgsql
security definer set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Sign in before registering for notifications.'
      using errcode = '42501';
  end if;
  if device_token is null or char_length(trim(device_token)) = 0 then
    raise exception 'That device did not provide a token.' using errcode = '22023';
  end if;
  if device_platform not in ('ios', 'android', 'web') then
    raise exception 'Unknown platform.' using errcode = '22023';
  end if;

  insert into public.device_tokens (token, user_id, platform, last_seen_at)
  values (trim(device_token), auth.uid(), device_platform, now())
  on conflict (token) do update
  set user_id = excluded.user_id,
      platform = excluded.platform,
      last_seen_at = now();
end;
$$;

revoke all on function public.register_device_token(text, text) from public, anon;
grant execute on function public.register_device_token(text, text) to authenticated;

-- Signing out, or turning notifications off on this device.
create or replace function public.forget_device_token(device_token text)
returns void
language plpgsql
security definer set search_path = public
as $$
begin
  delete from public.device_tokens
  where token = trim(device_token)
    and user_id = auth.uid();
end;
$$;

revoke all on function public.forget_device_token(text) from public, anon;
grant execute on function public.forget_device_token(text) to authenticated;
