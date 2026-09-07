-- The app noticed.
--
-- Setting up a profile is a form. Tick your instruments, tick your genres,
-- type your city, choose who sees it — four questions asked of somebody who
-- came here to play music, before they get anything back. It reads as a
-- survey because it is one, and a survey is the least interesting thing an
-- app can hand a person who has just made something.
--
-- **And most of it is already known.** By the time anybody opens that sheet
-- they have recorded takes, and every one of those carries a part. Somebody
-- who has laid down bass on four songs and never ticked "Bass" is not
-- withholding it; they were asked at the wrong moment, before there was
-- anything to say.
--
-- So the app says what it saw and asks whether to write it down. "You have
-- recorded bass on four songs — add it?" is a different feeling from an empty
-- checkbox: it is the app having paid attention, and one tap rather than a
-- form.
--
-- **Only what is actually true.** Every row here is countable and checkable:
-- shared takes with a part on them, songs on the Open Mic, a field left
-- empty. Nothing is inferred about somebody's taste or ability, because
-- nothing in this database supports inferring either, and a wrong guess about
-- who somebody is as a musician is far worse than no guess.

create or replace function public.things_we_noticed()
returns table (
  -- 'plays'        — a part they have recorded and never claimed
  -- 'discoverable' — their songs are public and they are not findable
  -- 'sounds_like'  — they have shared music and never said what it is
  kind text,
  subject text,
  detail text,
  amount bigint
)
language sql
stable
security definer
set search_path = public
as $fn$
  with me as (
    select p.id, p.plays, p.sounds_like, p.discoverable
    from public.profiles p
    where p.id = (select auth.uid())
  ),
  -- Shared takes only. A private draft is nobody's evidence of anything,
  -- including their own — the same rule parts_recorded_by has always used.
  recorded as (
    select l.part::text as part, count(*) as n
    from public.song_layers l
    where l.recorded_by = (select auth.uid())
      and l.shared_at is not null
    group by l.part
  ),
  mine_up as (
    select count(*) as n
    from public.projects p
    join public.rooms r on r.id = p.room_id
    where r.account_id = (select auth.uid())
      and p.open_mic_at is not null
      and p.deleted_at is null
  )
  select
    'plays'::text,
    r.part,
    'You have recorded ' || r.part || ' on ' || r.n ||
      case when r.n = 1 then ' song.' else ' songs.' end,
    r.n
  from recorded r
  where not (r.part = any(coalesce((select plays from me), '{}'::text[])))

  union all

  -- The one that costs somebody something real. Their music is findable and
  -- they are not, so an offer to play on it has nowhere to come from.
  select
    'discoverable'::text,
    ''::text,
    'You have ' || m.n || case when m.n = 1 then ' song' else ' songs' end ||
      ' on the Open Mic, but nobody can find you.',
    m.n
  from mine_up m, me
  where m.n > 0 and not me.discoverable

  union all

  select
    'sounds_like'::text,
    ''::text,
    'You have shared music and never said what it sounds like. It is the '
      'one thing that puts you in front of people making the same kind.',
    (select count(*) from recorded)
  from me
  where coalesce(array_length(me.sounds_like, 1), 0) = 0
    and exists (select 1 from recorded)

  order by 4 desc;
$fn$;

revoke all on function public.things_we_noticed() from public, anon;
grant execute on function public.things_we_noticed() to authenticated;

-- Adding one thing, without rewriting the rest of the profile.
--
-- `set_open_mic_presence` takes every field at once, which is right for a
-- settings sheet and wrong here: accepting "you play bass" should not require
-- the client to send back a city and a visibility setting it was not asked
-- about, and a client that gets that wrong silently overwrites something
-- somebody chose.
create or replace function public.claim_part(in_part text)
returns text[]
language plpgsql
security invoker
set search_path = public
as $fn$
declare
  cleaned text;
  result text[];
begin
  cleaned := lower(trim(coalesce(in_part, '')));
  if char_length(cleaned) = 0 or char_length(cleaned) > 40 then
    raise exception 'That is not a part.' using errcode = '22023';
  end if;

  update public.profiles
  set plays = case
    when cleaned = any(plays) then plays
    else array_append(plays, cleaned)
  end
  where id = auth.uid()
  returning plays into result;

  return result;
end;
$fn$;

revoke all on function public.claim_part(text) from public, anon;
grant execute on function public.claim_part(text) to authenticated;
