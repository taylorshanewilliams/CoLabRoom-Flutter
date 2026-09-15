-- Clear the test arrival.
--
-- Proving the attribution chain end to end on 15 September meant sending a
-- real beacon at the live function with the code `smoke-test`, which is the
-- only way to know the chain works. It left one row in public.arrivals, and
-- that row turns up in the weekly report as a place somebody came from.
--
-- A made-up row in a table of real ones is worse than no row: the first
-- report anybody reads should not contain a thing that never happened. The
-- run-query workflow is read-only by design, so the tidy-up is a migration.
--
-- Named codes only, not a pattern: a broad delete here would be a way to
-- quietly remove real arrivals later.

delete from public.arrivals where code = 'smoke-test';
