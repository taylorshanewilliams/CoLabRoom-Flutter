-- An answer you can read.
--
-- 0080 gave people somewhere to ask and gave whoever runs this app a queue to
-- read. It gave the person who asked nothing at all: the question went into a
-- table, and the only way to reply was to already know their email.
--
-- So `answer_help` now actually answers. The reply reaches them the way
-- everything else in this app does — a notification — and their own questions
-- and answers are readable from the help screen, which is where somebody who
-- asked something a week ago will look for it.

create or replace function public.answer_help(
  target_request uuid,
  in_note text default ''
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  asker uuid;
  asked text;
begin
  select asked_by, question into asker, asked
  from public.help_requests where id = target_request;

  if asker is null then
    raise exception 'No help request with that id.' using errcode = '22023';
  end if;

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

  -- The half that was missing. An answer nobody is told about is a note in
  -- a table, and the person who asked has no way to know it happened.
  if nullif(trim(coalesce(in_note, '')), '') is not null then
    perform private.notify_user(
      asker,
      'help_answered'::public.notification_type,
      'Somebody answered you',
      trim(in_note)
    );
  end if;
end;
$fn$;

revoke all on function public.answer_help(uuid, text)
  from public, anon, authenticated;

-- What you asked, and what came back.
--
-- Only ever your own — `asked_by = auth.uid()` — because a help question
-- routinely contains "I cannot find my song about my divorce", and that is
-- not readable by anybody else even in aggregate.
create or replace function public.my_help_requests(in_limit integer default 20)
returns table (
  id uuid,
  question text,
  status text,
  notes text,
  created_at timestamptz,
  answered_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $fn$
  select h.id, h.question, h.status, h.notes, h.created_at, h.answered_at
  from public.help_requests h
  where h.asked_by = (select auth.uid())
  order by h.created_at desc
  limit greatest(least(in_limit, 100), 1);
$fn$;

revoke all on function public.my_help_requests(integer) from public, anon;
grant execute on function public.my_help_requests(integer) to authenticated;
