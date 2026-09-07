-- Somewhere to ask.
--
-- The only way to say anything to whoever runs this app is the feedback box
-- labelled "Tell us what happened", which is for reporting a fault. Somebody
-- who simply does not know how to do a thing has nowhere to go, and the app
-- has never told them where.
--
-- Most of those questions have a fixed answer and do not need a person.
-- The ones that do need a person need to reach one — and to be recorded on
-- the way, because a question answered in an inbox and nowhere else is a
-- question the next fifty people will also ask.

create table if not exists public.help_requests (
  id uuid primary key default gen_random_uuid(),
  asked_by uuid not null default auth.uid()
    references public.profiles(id) on delete cascade,

  question text not null check (char_length(trim(question)) between 1 and 2000),

  -- Which canned answer the app offered before they asked for a person, or
  -- null when nothing matched.
  --
  -- The most useful column here. A question that was answered and asked
  -- anyway means the answer is wrong; a run of questions matching nothing
  -- means an answer is missing. Both are invisible without this.
  matched_answer text,

  -- Where they were standing. The same three fields the crash reporter
  -- carries, for the same reason: "it does not work" is unanswerable without
  -- them.
  route text,
  platform text,
  app_version text,

  status text not null default 'open'
    check (status in ('open', 'answered', 'closed')),
  created_at timestamptz not null default now(),
  answered_at timestamptz,
  -- Appended, never overwritten, the way resolve_report does it.
  notes text not null default ''
);

create index if not exists help_requests_open_idx
  on public.help_requests (status, created_at desc);

alter table public.help_requests enable row level security;

-- You can ask, and you can see what you asked. Nobody reads anybody else's:
-- a help question routinely contains "I cannot find my song about my
-- divorce", and that is not public even in aggregate.
drop policy if exists help_requests_read_own on public.help_requests;
create policy help_requests_read_own on public.help_requests
for select to authenticated using (asked_by = (select auth.uid()));

drop policy if exists help_requests_insert_own on public.help_requests;
create policy help_requests_insert_own on public.help_requests
for insert to authenticated with check (asked_by = (select auth.uid()));

create or replace function public.ask_for_help(
  in_question text,
  in_matched_answer text default null,
  in_route text default null,
  in_platform text default null,
  in_app_version text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
declare
  new_id uuid;
begin
  insert into public.help_requests
    (asked_by, question, matched_answer, route, platform, app_version)
  values
    (auth.uid(), left(trim(in_question), 2000), in_matched_answer,
     in_route, in_platform, in_app_version)
  returning id into new_id;

  return new_id;
end;
$fn$;

revoke all on function
  public.ask_for_help(text, text, text, text, text) from public, anon;
grant execute on function
  public.ask_for_help(text, text, text, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- The other end
-- ---------------------------------------------------------------------

-- Same shape as resolve_report, same reason: there is no support role in
-- this app and one operator does not need a permissions system with a single
-- row in it. Read the queue and close things with the service key.
create or replace function public.answer_help(
  target_request uuid,
  in_note text default ''
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  update public.help_requests
  set status = 'answered',
      answered_at = now(),
      notes = case
        when nullif(trim(coalesce(in_note, '')), '') is null then notes
        else left(
          notes || case when notes = '' then '' else E'\n\n' end
            || '[' || to_char(now(), 'YYYY-MM-DD') || '] ' || trim(in_note),
          4000)
      end
  where id = target_request;

  if not found then
    raise exception 'No help request with that id.' using errcode = '22023';
  end if;
end;
$fn$;

revoke all on function public.answer_help(uuid, text)
  from public, anon, authenticated;

-- What people cannot find, newest first.
--
-- Reads as a list of what the app fails to explain rather than a list of
-- tickets, because that is the thing worth acting on: a question that
-- matched an answer and was sent anyway means the answer is wrong.
create or replace function public.help_queue(in_limit integer default 50)
returns table (
  id uuid,
  question text,
  matched_answer text,
  route text,
  app_version text,
  status text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $fn$
  select h.id, h.question, h.matched_answer, h.route, h.app_version,
         h.status, h.created_at
  from public.help_requests h
  order by (h.status = 'open') desc, h.created_at desc
  limit greatest(least(in_limit, 200), 1);
$fn$;

revoke all on function public.help_queue(integer)
  from public, anon, authenticated;
