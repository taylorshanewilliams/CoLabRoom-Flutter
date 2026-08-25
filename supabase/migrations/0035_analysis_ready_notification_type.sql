-- Adds the notification type an analysis uses to say it has finished.
--
-- Alone in its own migration on purpose. `alter type ... add value` is
-- allowed inside a transaction on PG12+ (apply_migration.py wraps every file
-- in one), but the new value cannot be *used* in the same transaction that
-- adds it. Splitting the value from the trigger that references it sidesteps
-- that rule entirely rather than relying on a plpgsql body not counting as
-- use — which is true, but is the kind of true that stops being true when
-- somebody adds a default or a check constraint later.
--
-- Deliberately not wired into notification_preferences the way
-- invite/project_update types are. Those are other people's activity
-- arriving uninvited, which is exactly what somebody might want to turn off.
-- This is the result of a job you personally started, so silencing it would
-- mean the app quietly not telling you the thing you asked for is ready.

alter type public.notification_type add value if not exists 'analysis_ready';
