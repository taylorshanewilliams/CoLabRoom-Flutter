-- A word for a message.
--
-- On its own, the way 0048 added song_ask: a new enum value cannot be used in
-- the transaction that adds it, so the type learns the word here and 0112
-- uses it. Builds from before #235 refuse to load on a type they have not
-- met; builds since show it with the title and body the server wrote.
alter type public.notification_type add value if not exists 'direct_message';
