-- A word for meeting.
--
-- On its own, the way 0048, 0090, 0111 and 0114 did it: a new enum value
-- cannot be used in the transaction that adds it, so the type learns the
-- words here and 0132 uses them. Builds since #235 show a type they have not
-- met with the title and body the server wrote; none refuses to load.
alter type public.notification_type add value if not exists 'connection_request';
alter type public.notification_type add value if not exists 'connection_accepted';
