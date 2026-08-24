# Beta Release Checklist

## Foundation

- [ ] Reserve `com.colabroom.app` for Android and Apple.
- [x] Own and configure a CoLabRoom domain and support email. `colabroom.com`
      is live on GitHub Pages with HTTPS enforced; `support@` and `beta@`
      forward to a real inbox.
- [ ] Create isolated beta and production backend projects. Deliberately
      deferred — no real tester data exists yet to protect, and the
      migration-safety half of this risk is now covered by the `database`
      CI job instead. The exact cutover steps are written down in
      `docs/BACKEND_CUTOVER.md` so it's a checklist at the actual moment
      Play/TestFlight testers first onboard, not an improvised scramble.
- [ ] Move private signing material into managed secrets.
      iOS is done — `build-ios-testflight.yml` signs via fastlane match with
      `APPLE_API_KEY_ID`/`APPLE_TEAM_ID`/`MATCH_PASSWORD` as repo secrets.
      Android has no release keystore yet — only the checked-in debug
      keystore (a fixed, non-secret identity, deliberately not private).
- [ ] Add CI builds for Android App Bundle, TestFlight archive, and web.
      TestFlight and web are done (`build-ios-testflight.yml`,
      `build-web.yml`) — the full mobile-first plugin set compiles clean for
      a browser with zero changes, confirmed by an actual CI run rather than
      assumed. Android App Bundle is the one piece left, blocked on the
      release keystore above.

## Core behavior

- [ ] Account creation, sign-in, sign-out, and recovery.
- [x] Account deletion in-app and through a public web page. In-app is the
      account screen's Delete account action; the public page is
      `colabroom.com`'s deletion section, required by both stores before
      review.
- [ ] Room creation, rename, icon, invitation, role, and removal.
- [ ] Song creation and account-scoped duplicate-name enforcement.
- [ ] Live contribution, comment, file, audio, and history synchronization.
- [ ] Offline/reconnect conflict behavior and visible save state.
- [x] Simple song-sheet export. Share as text and print to PDF, songs and
      setlists both (`ProjectExportService`).

## Trust and diagnostics

- [x] Crash/error reporting on Apple, Android, and web. `CrashReporter`
      installs FlutterError and PlatformDispatcher handlers in main; rows go
      to `analysis_errors` with `service = 'app'`, deduplicated and capped.
      Gap: RLS admits inserts only from a signed-in user, so a crash on the
      sign-in screen is still lost.
- [x] In-app feedback with route, version, platform, and optional screenshot.
      Attach a picture from the feedback dialog itself; it uploads to a
      private `feedback-screenshots` bucket, own-folder-scoped, before the
      row is written.
- [ ] Privacy policy, Terms, data retention, and deletion policy. Drafted and
      live at `colabroom.com/privacy.html` and `/terms.html`, grounded in the
      actual subprocessor chain (Supabase, RunPod, Cloud Run, OpenAI) and the
      real Room-deletion cascade. Unticked deliberately — Terms still has an
      explicit governing-law placeholder, and neither has had a real legal
      read yet.
- [x] Microphone disclosure immediately before permission request.
      `MicrophoneAccess.ensureGranted` gates both recording paths — reference
      takes and voice notes — and is shown again if the permission is later
      revoked. iOS usage strings are set in the TestFlight build.
- [ ] Google Play Data Safety and Apple privacy declarations. Every answer
      is mapped in `docs/STORE_PRIVACY_DECLARATIONS.md`, traced to the actual
      code — filling either console form should be copy-in. Unticked because
      only an enrolled developer account can actually submit either form.
- [ ] Accessibility, keyboard, screen-size, and low-connectivity testing.
      A code-level screen-reader audit is done — every icon-only button and
      tappable region checked, not sampled. 3 real gaps found and fixed
      (password-visibility toggle, Studio preview play/pause, cowork send —
      all missing a `tooltip`). One real gap found and deliberately *not*
      quick-fixed: the voice-note bullet rail
      (`continuous_song_editor.dart`) is a `CustomPaint` with no semantic
      content at all — tapping a line's dot to add a voice note is
      currently invisible to a screen reader, and fixing it properly means
      generating per-line semantic nodes matched to dynamic hit-test
      positions, not a one-line patch. Two more small refinements, not
      gaps: the tap-to-rename song/room titles and tap-to-place-a-chord
      targets read their visible text fine, but don't announce *what*
      double-tapping does. None of this substitutes for an actual pass with
      VoiceOver/TalkBack, a keyboard, a small screen, and a bad connection —
      that still needs a real device.

## Distribution

- [ ] Google Play Internal Testing Android App Bundle.
- [ ] TestFlight internal group, followed by approved external group.
- [ ] Password-protected or invitation-gated beta web deployment.
- [ ] Release notes and a focused “What to test” task for every build.
