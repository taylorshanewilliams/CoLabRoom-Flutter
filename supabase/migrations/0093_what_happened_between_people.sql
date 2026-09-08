-- What happened between people.
--
-- A matchmaker cannot be predicted into existence. Nobody has ever forecast
-- creative chemistry — not for bands, not for co-founders, not for writing
-- partners — and a system that claims to would be guessing with confidence.
-- What works is the other shape: make trying almost free, do it thousands of
-- times, and learn from what actually happened.
--
-- The learning half needs a memory, and a memory is the one part of that
-- which cannot be added later. Everything else here can be built in any order
-- whenever somebody has time. History that was never written down is gone.
--
-- So this is written now, a long time before anything reads it, at four real
-- users, deliberately.
--
-- ---------------------------------------------------------------------
-- Why the tables we have cannot answer the question
-- ---------------------------------------------------------------------
--
-- `project_asks` is *state*, and state is destroyed as it changes:
--
--   * `status` is 'closed' both when somebody accepted and when the asker
--     withdrew, so the row cannot tell the two apart. 0088 hit this and had
--     to read `project_members` instead to work out whether anybody actually
--     said yes.
--   * an ask deleted with its song takes the fact that two people once tried
--     something with it, because the foreign key cascades.
--   * how long somebody took to answer exists only until the next update.
--
-- None of that is a defect in `project_asks` — it is what a state table is
-- for. It is a reason to keep an events table beside it.
--
-- ---------------------------------------------------------------------
-- The one signal worth learning from
-- ---------------------------------------------------------------------
--
-- **Whether two people worked together a second time.** It is the only
-- honest measure of fit this app can have: unfakeable, needing no stars, no
-- reviews, no completion counts, and no opinion from anybody.
--
-- And it is safe here in a way a rating never could be, because it is an edge
-- between two people rather than a number on one. The matcher reads it; it is
-- shown to nobody, ever. That is how this app gets a learning matchmaker
-- without acquiring the leaderboard it spent 0072, 0074 and 0088 refusing to
-- build. Whatever eventually reads this table returns *matches*. If it ever
-- returns a count, a rank or a score about a person, it has become the thing
-- the rest of the app exists to avoid.

-- ---------------------------------------------------------------------
-- People change, and the matcher must let them
-- ---------------------------------------------------------------------
--
-- Somebody who spent two years making folk records and has started making
-- beats is not the person their history describes, and the connections worth
-- offering them are not the ones that fitted the old work. A matcher that
-- only mines the past fossilises people into who they used to be — which is
-- the standard failure of every recommender ever built, and it is a much
-- worse failure here than it is for films, because a musician changing is
-- the normal case rather than the exception.
--
-- Two things guard against it, and both are decisions rather than accidents:
--
--   * **Every row carries `at`, and the past decays.** Whatever reads this
--     must weight the last few months far above anything older. A
--     collaboration from three years ago is context, not a prediction.
--   * **A profile written by the music is current by construction.** What
--     somebody recorded last month is what they sound like now; a typed
--     description is what they thought of themselves the day they signed up,
--     and nobody goes back to edit it.
--
-- And the exploration budget — the quarter of the feed that is deliberately
-- not for you — is what makes changing *possible* rather than merely allowed.
-- A system that only proposes what history supports can never offer somebody
-- the collaborator who suits who they are becoming, because by definition
-- nothing in the record points there yet.

create table if not exists private.collaboration_events (
  id bigint generated always as identity primary key,

  -- What happened. Text with a check rather than an enum: adding a kind to an
  -- enum needs a migration and a deploy in the right order, and this table
  -- will learn new kinds long before it learns to be read.
  kind text not null check (kind in (
    'asked',      -- somebody asked, of one person or of a whole room
    'accepted',   -- and they said yes
    'declined',   -- and they said no, which is a real answer and worth as
                  -- much to a matcher as a yes
    'withdrawn',  -- the asker took it back, or the song was finished
    'delivered'   -- a take landed on somebody else's song. The thing itself
  )),

  -- Who acted, and the other person. Consistent across every kind: `by_user`
  -- did the thing, `with_user` is who it was with.
  --
  -- `with_user` is null for an ask made of a whole room rather than of a
  -- person, which is most of them and is not a lesser event — it is how most
  -- songs actually ask.
  by_user uuid not null references public.profiles(id) on delete cascade,
  with_user uuid references public.profiles(id) on delete cascade,

  -- Set null, not cascade. If the song is deleted the fact that these two
  -- people tried something is still true and still about them; the pointer to
  -- deleted content is what has to go.
  project_id uuid references public.projects(id) on delete set null,

  part text,

  at timestamptz not null default now()
);

comment on table private.collaboration_events is
  'Append-only record of two people trying something. Substrate for matching '
  'and nothing else: no function may return a count, a rank or a score about '
  'a person from this table.';

create index if not exists collaboration_events_by_idx
  on private.collaboration_events (by_user, at desc);

create index if not exists collaboration_events_with_idx
  on private.collaboration_events (with_user, at desc)
  where with_user is not null;

-- The pair, in a fixed order, because a pair is unordered and "did they come
-- back" is a question about the pair rather than about who asked first.
create index if not exists collaboration_events_pair_idx
  on private.collaboration_events (
    least(by_user, with_user), greatest(by_user, with_user), at desc)
  where with_user is not null;

-- Nobody reads this over the API. It is in `private`, which PostgREST does
-- not expose, and the grants are removed as well — two locks, because a
-- schema being unexposed is a configuration and a revoke is a fact.
revoke all on table private.collaboration_events from public, anon, authenticated;

alter table private.collaboration_events enable row level security;

-- ---------------------------------------------------------------------
-- Written by triggers, never by the app
-- ---------------------------------------------------------------------
--
-- A ledger the client has to remember to write is a ledger with holes in it,
-- and the holes appear exactly where somebody added a feature in a hurry. The
-- database already sees every one of these events; it can write them down
-- itself.

create or replace function private.remember_ask()
returns trigger
language plpgsql
security definer set search_path = ''
as $fn$
begin
  insert into private.collaboration_events
    (kind, by_user, with_user, project_id, part, at)
  values ('asked', new.asked_by, new.asked_of, new.project_id, new.part,
          new.created_at);
  return new;
end;
$fn$;

drop trigger if exists project_asks_remember on public.project_asks;
create trigger project_asks_remember
after insert on public.project_asks
for each row when (new.asked_by is not null)
execute function private.remember_ask();

-- Accepted, declined, or taken back.
--
-- The distinction `status` alone cannot make: 'closed' covers both an accepted
-- ask and a withdrawn one. `answered_at` is only ever set by answer_ask, so it
-- is what tells them apart — which means this needs no change to answer_ask
-- itself, and catches the bulk close in finish_song too. A song being finished
-- does withdraw its open asks, and recording that as a withdrawal is right:
-- nobody said no, the question stopped existing.
create or replace function private.remember_answer()
returns trigger
language plpgsql
security definer set search_path = ''
as $fn$
declare
  what text;
  actor uuid;
  other uuid;
begin
  if old.status <> 'open' or new.status = 'open' then
    return new;
  end if;

  if new.status = 'declined' then
    what := 'declined';
  elsif new.answered_at is not null then
    what := 'accepted';
  else
    what := 'withdrawn';
  end if;

  -- Who acted. An answer comes from the person asked; a withdrawal from the
  -- person who asked.
  if what = 'withdrawn' then
    actor := new.asked_by;
    other := new.asked_of;
  else
    actor := coalesce(new.asked_of, (select auth.uid()));
    other := new.asked_by;
  end if;

  if actor is null then
    return new;
  end if;

  insert into private.collaboration_events
    (kind, by_user, with_user, project_id, part)
  values (what, actor, other, new.project_id, new.part);
  return new;
end;
$fn$;

drop trigger if exists project_asks_remember_answer on public.project_asks;
create trigger project_asks_remember_answer
after update of status on public.project_asks
for each row execute function private.remember_answer();

-- The thing itself: somebody put a take on a song that is not theirs.
--
-- Shared takes only. A private take is not a delivery — it is somebody
-- working, and the whole app rests on those two being different.
create or replace function private.remember_delivery()
returns trigger
language plpgsql
security definer set search_path = ''
as $fn$
declare
  owner uuid;
begin
  if new.shared_at is null then
    return new;
  end if;
  if tg_op = 'UPDATE' and old.shared_at is not null then
    return new;
  end if;

  select created_by into owner
  from public.projects where id = new.project_id;

  if owner is null or owner = new.recorded_by or new.recorded_by is null then
    return new;
  end if;

  insert into private.collaboration_events
    (kind, by_user, with_user, project_id, part, at)
  values ('delivered', new.recorded_by, owner, new.project_id,
          new.part::text, new.shared_at);
  return new;
end;
$fn$;

drop trigger if exists song_layers_remember_delivery on public.song_layers;
create trigger song_layers_remember_delivery
after insert or update of shared_at on public.song_layers
for each row execute function private.remember_delivery();

-- ---------------------------------------------------------------------
-- And everything that is still recoverable
-- ---------------------------------------------------------------------
--
-- The argument for writing this tonight is that history cannot be recovered
-- later — so the history that has *not* been destroyed yet is worth taking
-- now, while the rows are still here. Timestamps come from the rows
-- themselves, so the ledger starts with real dates rather than today's.
--
-- Withdrawn asks are not backfilled: for rows that closed before this
-- migration there is no way to tell a withdrawal from an acceptance made
-- before `answered_at` existed, and a guess in a ledger is worse than a gap.
do $$
begin
  if exists (select 1 from private.collaboration_events) then
    return;
  end if;

  insert into private.collaboration_events
    (kind, by_user, with_user, project_id, part, at)
  select 'asked', a.asked_by, a.asked_of, a.project_id, a.part, a.created_at
  from public.project_asks a
  where a.asked_by is not null;

  insert into private.collaboration_events
    (kind, by_user, with_user, project_id, part, at)
  select
    case when a.status = 'declined' then 'declined' else 'accepted' end,
    a.asked_of, a.asked_by, a.project_id, a.part, a.answered_at
  from public.project_asks a
  where a.answered_at is not null and a.asked_of is not null;

  insert into private.collaboration_events
    (kind, by_user, with_user, project_id, part, at)
  select 'delivered', l.recorded_by, p.created_by, l.project_id,
         l.part::text, l.shared_at
  from public.song_layers l
  join public.projects p on p.id = l.project_id
  where l.shared_at is not null
    and l.recorded_by is not null
    and p.created_by is not null
    and l.recorded_by <> p.created_by;
end $$;
