# Beta Release Checklist

## Foundation

- [ ] Reserve `com.colabroom.app` for Android and Apple.
- [ ] Own and configure a CoLabRoom domain and support email.
- [ ] Create isolated beta and production backend projects.
- [ ] Move private signing material into managed secrets.
- [ ] Add CI builds for Android App Bundle, TestFlight archive, and web.

## Core behavior

- [ ] Account creation, sign-in, sign-out, and recovery.
- [ ] Account deletion in-app and through a public web page.
- [ ] Room creation, rename, icon, invitation, role, and removal.
- [ ] Song creation and account-scoped duplicate-name enforcement.
- [ ] Live contribution, comment, file, audio, and history synchronization.
- [ ] Offline/reconnect conflict behavior and visible save state.
- [ ] Simple song-sheet export.

## Trust and diagnostics

- [ ] Crash/error reporting on Apple, Android, and web.
- [ ] In-app feedback with route, version, platform, and optional screenshot.
- [ ] Privacy policy, Terms, data retention, and deletion policy.
- [ ] Microphone disclosure immediately before permission request.
- [ ] Google Play Data Safety and Apple privacy declarations.
- [ ] Accessibility, keyboard, screen-size, and low-connectivity testing.

## Distribution

- [ ] Google Play Internal Testing Android App Bundle.
- [ ] TestFlight internal group, followed by approved external group.
- [ ] Password-protected or invitation-gated beta web deployment.
- [ ] Release notes and a focused “What to test” task for every build.
