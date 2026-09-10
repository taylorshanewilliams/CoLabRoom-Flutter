-- Finding somebody you already know the name of.
--
-- `find_musicians` matches on what somebody plays, where they are, and who
-- they sound like. That is the right search for meeting a stranger and the
-- wrong one for "my mate Dave is on here somewhere" -- which is what people
-- do first, before they ever browse.
--
-- Taylor: "a place where you can see your friends, add friends, search for
-- friends".
--
-- Two rules carried over from the rest of this app, both of them the reason
-- this is a function rather than a select on profiles:
--
--   Only people who have turned discoverability on. Being findable is off
--   until somebody switches it on, and a name search that ignored that would
--   quietly undo the one privacy control the Open Mic has.
--
--   Blocks apply in both directions and are invisible: somebody who blocked
--   you is not in the results, and the results do not say why.
create or replace function public.search_people(q text)
returns table (
  person_id uuid,
  display_name text,
  avatar_path text,
  plays text[],
  city text,
  already text
)
language sql
security definer set search_path = ''
stable
as $fn$
  with needle as (
    select nullif(trim(coalesce(q, '')), '') as term
  )
  select
    p.id,
    p.display_name,
    p.avatar_path,
    p.plays,
    -- The same rule the Open Mic uses: a city is shown only by somebody who
    -- chose to show it.
    case when p.location_visibility = 'city' then p.city else null end,
    -- What the button should say, decided here rather than by the client
    -- guessing from a list it may not have loaded.
    coalesce(
      (
        select c.state::text
        from public.connections c
        where (c.requester_id = auth.uid() and c.addressee_id = p.id)
           or (c.requester_id = p.id and c.addressee_id = auth.uid())
        limit 1
      ),
      'none'
    )
  from public.profiles p, needle
  where needle.term is not null
    and p.discoverable
    and p.id <> auth.uid()
    and coalesce(p.is_demo, false) = false
    and p.display_name ilike '%' || needle.term || '%'
    and not exists (
      select 1 from public.user_blocks b
      where (b.blocker_id = auth.uid() and b.blocked_id = p.id)
         or (b.blocker_id = p.id and b.blocked_id = auth.uid())
    )
  -- Names that start with what was typed first: somebody searching "dav"
  -- means Dave before they mean Davidson.
  order by
    case when p.display_name ilike needle.term || '%' then 0 else 1 end,
    p.display_name
  limit 30;
$fn$;

revoke all on function public.search_people(text) from public, anon;
grant execute on function public.search_people(text) to authenticated;
