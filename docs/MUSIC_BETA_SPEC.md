# CoLabRoom Music Beta — Product Specification

## Promise

Two or more musicians can create a private Music Room and move a song from an idea to a
traceable shared draft without losing authorship, context, or earlier versions.

## Core hierarchy

1. An account owns or joins Music Rooms.
2. A Music Room contains song projects.
3. A song project contains ordered contributions.
4. Contributions can have comments, revisions, files, and inline audio.
5. Project history records important collaboration events.

## Beta journey

1. Create or sign in to an account.
2. Create a Music Room, choose an icon, and invite a collaborator.
3. Create a song project or open an existing song.
4. Add and edit contributions with visible author color.
5. Comment on a contribution or attach a voice/melody note.
6. Review project history and restore an earlier revision when necessary.
7. Export a simple song sheet.
8. Submit product feedback without leaving the app.

## Naming rules

- Room names preserve capitalization and are unique within the owning account.
- Project names preserve capitalization and are unique across the owning account, even
  when projects live in different Rooms.
- Unrelated customer accounts can use the same Room and project names.
- Names are trimmed and repeated whitespace is collapsed before comparison.

## Roles

- Owner: manages the Room, members, projects, and deletion.
- Editor: creates and edits projects and contributions.
- Commenter: comments and attaches feedback without rewriting contributions.
- Viewer: read-only access.

## Included in the first tester build

- Email account creation, sign-in, password recovery, sign-out, and account deletion.
- Music-only Home and Rooms experience.
- Room creation, icon selection, search, rename, and invitation codes.
- Song creation, rename, and account-wide duplicate-name prevention.
- Real-time, author-colored text contributions.
- Talk to Text that writes into the visible composer before submission.
- Compact keyboard-safe workspace.
- Apple, Android, and responsive web layouts.
- In-app feedback and basic privacy disclosure.

## Next beta increments

- Contribution-level comments.
- Attached voice/melody notes and reference-file uploads.
- Restorable contribution revision history and project event history.
- Custom uploaded Room artwork.
- Push notifications and presence indicators.
- Song-sheet export and self-service account export/deletion.

## Explicitly deferred

- Non-music industries and templates.
- Public Room discovery.
- Payments, subscriptions, and monetization.
- Marketplace features.
- Advanced studio DAW behavior.
- Complex rights-split contracts or royalty accounting.
- Full professional PDF formatting beyond a simple beta song sheet.

## Beta success checks

- A new tester can create a Room, invite someone, and add the first shared contribution
  without assistance.
- No accepted edit is silently lost during reconnect or device switching.
- Every contribution and revision retains an author and timestamp.
- Permission boundaries prevent non-members from reading Room data.
- A tester can report a confusing screen in under thirty seconds.
- The same account and Room data appear on Apple, Android, and web.
