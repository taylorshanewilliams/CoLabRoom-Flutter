# Music Beta Architecture

## Client

Flutter owns the adaptive visual system and feature flows for iOS, Android, and web.
The client depends on a `MusicRepository` contract rather than directly on Supabase.
This keeps screens testable and permits a seeded local preview.

## Backend

Supabase provides:

- Auth for stable user identities.
- Postgres for Rooms, projects, contributions, comments, revisions, invitations, files,
  history, and feedback.
- Realtime for persisted changes, presence, and collaboration events.
- Storage for Room artwork, reference files, and voice/melody notes.
- Row Level Security for Room membership and role enforcement.

## Data ownership

The account owning a Room is the project-name uniqueness boundary. Projects store the
Room account ID so Postgres can enforce one normalized project name across every Room
in that account. IDs—not names—are used for relationships, so renaming never breaks
comments, history, files, or invitations.

## Collaboration policy

- Persisted content uses optimistic client writes plus server-generated timestamps.
- Each contribution carries a monotonically increasing revision number.
- Revisions are append-only.
- Deletes should become soft deletes before external beta to support recovery.
- Realtime is a delivery mechanism, not the source of truth; Postgres remains canonical.
- Presence and typing signals are ephemeral broadcasts and are not written as history.

## Environments

- Local preview: seeded in-memory repository; no real collaboration.
- Beta: isolated Supabase project and storage buckets.
- Production: separate Supabase project, keys, data, signing, and telemetry.

No beta service credential is committed to this repository. Public client keys are
provided with `--dart-define`; server secrets remain in backend-only configuration.
