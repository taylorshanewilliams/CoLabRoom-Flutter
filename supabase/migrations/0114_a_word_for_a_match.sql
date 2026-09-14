-- A word for a match.
--
-- On its own, the way 0048, 0090 and 0111 did it: a new enum value cannot
-- be used in the transaction that adds it, so the type learns the word here
-- and 0115 uses it. Not on any preference switch: this is the answer to a
-- note you left on purpose, and an app that quietly did not deliver the
-- thing you asked for would be worse than one that never offered.
alter type public.notification_type add value if not exists 'want_matched';
