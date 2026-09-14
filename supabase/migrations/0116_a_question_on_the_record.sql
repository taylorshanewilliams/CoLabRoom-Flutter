-- A question on the record.
--
-- Every question somebody asks the app about a song, with the answer it
-- gave and which model gave it. Not a chat history for the person -- the
-- sheet shows the answer once and that is the product -- but the one thing
-- that makes the feature improvable: a run of questions the answer dodged
-- is a missing fact in the brief, and a wrong answer somebody acted on is a
-- prompt to fix. Both are invisible without this. It is also the rate
-- limit: the function counts a person's questions in the last hour here
-- before it spends anything.
--
-- Readable by the person who asked, and only them. A question about a song
-- routinely contains the song, and that is not public even to the room.

create table public.song_questions (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  asked_by uuid not null references public.profiles(id) on delete cascade,
  question text not null check (char_length(trim(question)) between 1 and 500),
  answer text not null default '',
  model text,
  took_ms integer,
  created_at timestamptz not null default now()
);

create index song_questions_by_person_idx
  on public.song_questions (asked_by, created_at desc);

alter table public.song_questions enable row level security;

create policy song_questions_read_own on public.song_questions
for select to authenticated using (asked_by = (select auth.uid()));

-- Written by the Edge Function with the service role, never from the app,
-- so a row always carries the answer that was actually given.
revoke insert, update, delete on public.song_questions from authenticated, anon;
