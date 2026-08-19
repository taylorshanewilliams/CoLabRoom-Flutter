# CoLabRoom Music Beta

This is the clean cross-platform rebuild of CoLabRoom for Apple, Android, and web.
The recovered Android 1.0.44 application remains the visual and interaction reference;
none of its decoded APK internals are dependencies of this project.

## Beta boundary

The first beta supports only music collaboration:

- User-created Music Rooms with icons.
- Multiple song projects inside each Room.
- Account-wide duplicate project-name prevention.
- Compact editor-first song workspace.
- Seamless inline lyric editing with compact color-coded attribution bullets.
- Confirmed voice-note recording with play, re-record, and delete controls per line.
- Setlists, long-press project selection, and batch Room moves.
- Native print and text/email sharing for songs and setlists.
- Reviewed lyric import from PDF, Excel/CSV, Google Sheets links, text, or paste.
- Quick Auto-scroll and writing-color controls, plus a two-column landscape lyric sheet.
- Realtime contributions with author color and line-level attribution.
- Email-bound invitations with share codes and in-app feedback.
- Responsive phone, tablet, and browser layout from one Flutter codebase.

CNC, electrical, film, product design, research, custom industry forms, and advanced
professional exports are deliberately deferred.

## Run the local preview

This repository was created in an environment without the Flutter SDK. On a Flutter
development machine, generate the platform runners once and launch the preview:

```bash
flutter create --platforms=android,ios,web --org com.colabroom --project-name colabroom .
flutter pub get
flutter test
flutter run -d chrome
```

The app uses a seeded in-memory repository when Supabase environment values are absent.
That mode is intended for design and flow testing only.

## Connect Supabase

1. Create separate Supabase projects for beta and production.
2. Apply every SQL file in `supabase/migrations/` in numeric order.
3. Launch with:

```bash
flutter run -d chrome \
  --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=YOUR_PUBLISHABLE_KEY \
  --dart-define=AUTH_REDIRECT_URL=https://YOUR_BETA_HOST
```

The migration establishes the music collaboration schema, membership checks, account-
scoped project-name uniqueness, storage metadata, feedback, and Row Level Security.

The tester build exposes verified account, Room, song, setlist, invite, contribution,
speech-to-text, per-line voice-note, lyric-import, print/share, and feedback flows.
Comments, history restoration, custom Room artwork, and notifications remain staged
until their complete UI and tests are ready.

## Repository map

- `lib/app/` — application shell, design system, and responsive navigation.
- `lib/domain/` — beta models and naming rules.
- `lib/data/` — repository contract, seeded preview data, and Supabase adapter.
- `lib/features/` — Home, Rooms, song workspace, invites, and account/feedback.
- `supabase/migrations/` — authoritative backend schema and security policies.
- `test/` — naming and controller behavior tests.
- `docs/` — product boundary, architecture, and release checklist.

## Permanent identities

Before the first external build, reserve these identifiers and do not change them:

- Android beta application ID: `com.colabroom.beta`
- Apple bundle ID: `com.colabroom.app`
- Web beta host: `beta.colabroom.com` or another owned domain

The placeholder platform runners created locally must be updated to these identities
before Play Internal Testing or TestFlight distribution.

## Platform permissions required for Talk to Text

After the platform shells are generated, add:

- Android: `android.permission.RECORD_AUDIO` in `AndroidManifest.xml`.
- iOS: `NSSpeechRecognitionUsageDescription` and `NSMicrophoneUsageDescription` in
  `Info.plist`.
- Web: serve over HTTPS and allow the browser's microphone prompt. Speech-recognition
  availability varies by browser, so the UI always retains the normal text composer.

## Current checkpoint

Version 0.3.1 is the Android-first seamless lyric editor checkpoint. Push CI runs static
analysis and tests and produces the consistently signed Android tester APK. Web and
unsigned Apple release checks remain available as intentional manual workflow targets.
