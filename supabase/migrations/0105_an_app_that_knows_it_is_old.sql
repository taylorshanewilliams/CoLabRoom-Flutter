-- The oldest version of the app that is still the app.
--
-- On 13 September 2026 both iPhones in the band were opening 0.4.0 while the
-- Android phone beside them ran 0.4.1. Friends, the People screen, the
-- notifications test button and the strip had all shipped three days earlier,
-- and TestFlight had six builds carrying them. Nobody had tapped Update,
-- because nothing anywhere said there was anything to update to. Three
-- connection requests sat unanswered for three days, sent to phones that had
-- no screen to answer them on. Before that, a bandmate on 0.3.0 hit a function
-- this repo had renamed twelve times in one evening.
--
-- A social feature is exactly as shipped as the least-updated phone in the
-- band. This is the one fact the app needs in order to say so: the version
-- below which a build should tell its owner to update. The app compares it to
-- its own `BetaConfig.appVersion` and draws one card in the strip on Your
-- music. Nothing is blocked; it is a sentence, not a gate.
--
-- Raising it is a migration, deliberately: the number is versioned next to
-- the code it describes, replayed from empty by CI like everything else, and
-- cannot be changed by anything that is not a review. Set it to the version
-- whose absence would make the band feel like two apps, not to the newest
-- number.

create or replace function public.minimum_app_version()
returns text
language sql
stable
set search_path = public
as $$
  select '0.4.1'::text
$$;

comment on function public.minimum_app_version() is
  'The oldest app version that still matches everybody else. A build below '
  'it shows one card asking its owner to update. Raise by migration.';

revoke all on function public.minimum_app_version() from public, anon;
grant execute on function public.minimum_app_version() to authenticated;
