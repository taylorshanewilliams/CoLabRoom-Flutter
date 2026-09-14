-- The owner's own account on the member plan.
--
-- 0087 said plans are "set by hand until there is a store to take money
-- through", and this is that hand. Without it every "Full analysis" the
-- owner taps is quietly downgraded to the quick pass by allowedDepth() in
-- the Edge Function -- the paywall doing exactly its job on the one
-- account that is paying for all of it -- so the full pipeline was never
-- once exercised from the app by the person testing it.
--
-- A data migration rather than a console edit so the change is in the
-- repo's history, replays harmlessly on an empty database (no such row,
-- nothing to do), and does nothing at all if it has already happened.

update public.profiles
   set plan = 'member'
 where id = 'e01fede7-a319-4006-8532-1adbf3b430f5'
   and plan is distinct from 'member';
