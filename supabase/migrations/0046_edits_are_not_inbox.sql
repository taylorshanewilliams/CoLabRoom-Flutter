-- Lyric edits stop going to the inbox.
--
-- Opening the app after a bandmate wrote a verse produced a screenful of
-- notifications — one per line, because notify_project_update is a FOR EACH
-- STATEMENT trigger and the lyric editor saves a line at a time. Each line is
-- its own statement.
--
-- Coalescing them was the obvious fix and it is the wrong one. It makes the
-- flood smaller without asking why edits are in the inbox at all.
--
-- **Notify for what needs you; show what merely happened.** That is the rule
-- every app that gets this right shares: Slack badges mentions and not
-- channel chatter, GitHub separates Participating from All, Notion and Docs
-- digest comments and never notify per edit. Once an inbox contains things
-- nobody has to act on, people stop reading it — and then it fails at the one
-- job it had, which here is invitations.
--
-- Somebody adding lines to a song is not asking anything of anyone. It is
-- progress. And in a songwriting app there is a cost to pretending otherwise:
-- a writer who knows every line pings their band will write differently, and
-- tidy their work before saving. That is a product problem, not a polish one.
--
-- Nothing is lost by removing it. contributions_project_event has written
-- every edit to project_events since 0032, coalesced there already, and that
-- is exactly what Home reads: "Mike changed the words", with his face on it,
-- and no number pressuring anybody. Home is the first tab; you cannot open
-- the app without passing it.
--
-- What stays in the inbox is what genuinely needs a person: an invitation
-- only they can accept, the answer to one they sent, and the song sheet they
-- asked for and waited on.

drop trigger if exists contributions_notify_project_update on public.contributions;
drop function if exists public.notify_project_update();

-- The type stays in the enum. Old notifications still reference it, dropping
-- a value from an enum in Postgres is a rewrite, and nothing is served by
-- pretending the rows were never written.
comment on type public.notification_type is
  'project_update is no longer emitted — see 0046. Lyric edits are progress '
  'rather than requests, and live on Home via project_events instead.';
