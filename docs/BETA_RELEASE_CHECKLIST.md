# Beta Release Checklist

## Foundation

- [ ] Reserve `com.colabroom.app` for Android and Apple.
- [x] Own and configure a CoLabRoom domain and support email. `colabroom.com`
      is live on GitHub Pages with HTTPS enforced; `support@` and `beta@`
      forward to a real inbox.
- [ ] Create isolated beta and production backend projects.
- [ ] Move private signing material into managed secrets.
      iOS is done — `build-ios-testflight.yml` signs via fastlane match with
      `APPLE_API_KEY_ID`/`APPLE_TEAM_ID`/`MATCH_PASSWORD` as repo secrets.
      Android has no release keystore yet — only the checked-in debug
      keystore (a fixed, non-secret identity, deliberately not private).
- [ ] Add CI builds for Android App Bundle, TestFlight archive, and web.
      TestFlight is done (`build-ios-testflight.yml`). Android App Bundle
      needs the release keystore above. Web has never been scaffolded —
      `web/` doesn't exist in the repo yet.

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
- [ ] In-app feedback with route, version, platform, and optional screenshot.
      Route, version and platform are captured and stored. The optional
      screenshot is the only part missing.
- [ ] Privacy policy, Terms, data retention, and deletion policy.
- [x] Microphone disclosure immediately before permission request.
      `MicrophoneAccess.ensureGranted` gates both recording paths — reference
      takes and voice notes — and is shown again if the permission is later
      revoked. iOS usage strings are set in the TestFlight build.
- [ ] Google Play Data Safety and Apple privacy declarations.
- [ ] Accessibility, keyboard, screen-size, and low-connectivity testing.

## Distribution

- [ ] Google Play Internal Testing Android App Bundle.
- [ ] TestFlight internal group, followed by approved external group.
- [ ] Password-protected or invitation-gated beta web deployment.
- [ ] Release notes and a focused “What to test” task for every build.
