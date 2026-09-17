-- A word for a call.
--
-- On its own, the way 0131 and the others did it: a new enum value cannot be
-- used in the transaction that adds it, so the type learns the word here and
-- 0134 uses it. Builds that have not met it show the server's title and body.
alter type public.notification_type add value if not exists 'call_started';
