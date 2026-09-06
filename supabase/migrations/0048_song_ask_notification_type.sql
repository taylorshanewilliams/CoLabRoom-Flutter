-- The notification type a song uses to say it is asking for something.
--
-- Alone in its own migration for the reason 0035 set out: `alter type ... add
-- value` is allowed inside a transaction on PG12+, which is how
-- apply_migration.py runs every file, but the new value cannot be *used* in
-- the same transaction that adds it. Splitting the value from the trigger
-- that references it sidesteps the rule rather than relying on a plpgsql body
-- not counting as use.
--
-- Deliberately not wired into notification_preferences. The invite and
-- project_update types are other people's activity arriving uninvited, which
-- is exactly the thing somebody might want to turn off. An ask is a request
-- addressed to you — the whole defect it exists to fix is that a song wanting
-- something was invisible to the people who could have answered it, so a
-- request nobody is told about is not a request.
--
-- If this ever becomes noisy it will be at public scale, and public asks are
-- browsed rather than pushed: they will not notify individuals at all.

alter type public.notification_type add value if not exists 'song_ask';
