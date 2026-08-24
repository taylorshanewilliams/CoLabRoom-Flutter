# Cutting over to a production Supabase project

Not done yet, and deliberately not urgent. Read the reasoning before the
steps — it's most of the point of this document.

## Why this waited

The checklist item is "create isolated beta and production backend
projects." As of 2026-08-24, everything — every migration, every test,
every load test — runs against one Supabase project
(`gzcoclsfvazfhcheefhz`), because there is no real tester data yet to
protect from that. A second project today would be an empty database
sitting untouched for months, and every future migration would need to
remember to reach both.

The specific risk a split guards against — a broken migration silently
reaching real data — is now substantially covered a different way: the
`database` job in `verify.yml` replays every migration against a
throwaway Postgres and checks it before it's ever applied for real. That's
exactly the class of bug `0033_fix_notify_project_update_uuid_aggregate.sql`
fixed (`min(uuid)` in a trigger, silently broken since 0018). The remaining
thing isolation protects against is different: Taylor or Claude running
`run-query.yml` or `load-test.yml` against data that real people are
depending on, or a mistake made while debugging live. That risk starts
existing the moment real testers do — not before.

**Run this when:** Google Play Internal Testing or TestFlight is about to
onboard real testers for the first time. Not before.

## What "cutover" actually means here

Nothing moves. `gzcoclsfvazfhcheefhz` keeps being what every beta build
points at, forever — testers' data lives there, migrations keep landing
there first. A second project is created fresh, gets the same schema
replayed into it once, and is what a *future* public/production release
track points at. There is no data migration because there's nothing to
migrate — production starts empty, the way any new product does.

## Steps

1. **Create the project.** Supabase dashboard → New Project. Free tier
   covers this (2 projects per org, 500MB DB / 50k MAU / 5GB egress) unless
   real usage has since outgrown that — check current usage on the existing
   project first if it's been a while since this was written.

2. **Replay the schema.** Every file in `supabase/migrations/`, in order,
   the same way `apply-migration.yml` already does one at a time — or
   faster, adapt `tools/apply_migration.py` to loop the whole directory
   against the new project ref in one run, the way the `database` CI job
   already does against its throwaway Postgres.

3. **Get the new project's four values**, same shape as what the existing
   secrets already hold: project ref, a Supabase access token scoped to it,
   its anon/publishable key, its service role key.

4. **Wire it up as a second GitHub Environment, not new secret names.**
   Every workflow that touches Supabase (`apply-migration.yml`,
   `deploy-analyze-chords.yml`, `health-check.yml`, `load-test.yml`,
   `run-query.yml`, `triage-analysis-errors.yml`) already reads
   `SUPABASE_PROJECT_REF` / `SUPABASE_ACCESS_TOKEN` / `SUPABASE_SERVICE_ROLE_KEY`
   as repo-level secrets — the same names, everywhere. GitHub Environments
   let two environments each hold a secret with that same name pointing at
   different values, so the fix isn't renaming six workflows' worth of
   references — it's adding one `environment: beta` (or `production`)
   line to each job, ideally driven by a `workflow_dispatch` choice input,
   and creating "beta" and "production" Environments in repo settings with
   the existing secrets moved into "beta" and the new ones added to
   "production."

5. **Give the app two build targets.** `beta_config.dart`'s
   `SUPABASE_URL`/`SUPABASE_ANON_KEY` defaults stay pointed at the beta
   project — that's what every beta build (Play Internal Testing,
   TestFlight, `build-android-debug.yml`, `build-web.yml`) should keep
   using. A future release-track build passes the production project's
   URL/anon key via `--dart-define`, overriding the default. Nothing about
   today's default needs to change for beta builds to keep working exactly
   as they do now.

6. **Confirm it, don't assume it.** Same standard as everything else in
   this repo's CI: after replaying the schema, run a read query against the
   new project confirming table count and RLS policy count match the
   existing one, the way `0034`'s migration was confirmed live rather than
   trusted on the apply step's exit code alone.

## What this document is not

A decision to keep the two projects isolated forever in every other way.
The GPU analysis chain (RunPod, Google Cloud Run, OpenAI) isn't part of
this split — those don't hold durable per-user data the way Postgres does,
and sharing them across beta and production is a reasonable, lower-risk
default unless that changes.
