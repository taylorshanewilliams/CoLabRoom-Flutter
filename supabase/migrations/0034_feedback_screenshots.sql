-- The optional screenshot on beta feedback.
--
-- A bug report that says "the chord line is wrong" is a guess at what
-- happened; one with a picture of the actual screen is a fact. The route,
-- version and platform this table already carries answer "where and on
-- what" — a screenshot answers "what did it actually look like," which is
-- the one thing none of those fields can.

alter table public.feedback add column screenshot_path text;

insert into storage.buckets (id, name, public)
values ('feedback-screenshots', 'feedback-screenshots', false)
on conflict (id) do nothing;

-- Insert-only, own-folder, no select — matching feedback_create_self on the
-- table itself exactly. Nobody reads their own submitted feedback back
-- inside the app (there is no history view, by design: this is fire-and-
-- forget), so a screenshot attached to it needs no more access than that.
-- Review happens through the dashboard or service-role tooling, both of
-- which bypass RLS entirely. Granting authenticated select here would only
-- widen who can see the inside of somebody else's screen at the moment they
-- filed a bug — for no feature that exists.
create policy feedback_screenshots_write_own on storage.objects
for insert to authenticated with check (
  bucket_id = 'feedback-screenshots' and (storage.foldername(name))[1] = (select auth.uid())::text
);
