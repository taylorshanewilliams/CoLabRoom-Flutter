# Beta Release Environment

## What the automated build produces

- An installable Android debug APK for invited testers.
- A release-mode Flutter web bundle ready for HTTPS hosting.
- An unsigned Apple release compile check on macOS.

All three use the same Flutter source and the same isolated Supabase beta project.

## Required configuration

1. Flutter stable `3.44.7` or the matching CI runner.
2. A Supabase beta project with `0001_music_beta.sql` applied.
3. `SUPABASE_URL` and `SUPABASE_ANON_KEY` environment values.
4. `AUTH_REDIRECT_URL` set to the HTTPS beta URL allowed in Supabase Auth redirects.
5. HTTPS hosting for the web bundle. The Play Console account-deletion link is
   `https://YOUR_BETA_HOST/?deleteAccount=1`; it opens the web account screen after sign-in.
6. For TestFlight: an Apple Developer team, registered `com.colabroom.app` bundle ID,
   App Store Connect record, distribution certificate, and provisioning profile.
7. For Google Play: a Play Console application using `com.colabroom.app` and a protected
   upload key. The first direct tester artifact may use debug signing; Play must not.

## Commands

```bash
./tool/bootstrap_platforms.sh
SUPABASE_URL=https://YOUR_PROJECT.supabase.co \
SUPABASE_ANON_KEY=YOUR_PUBLISHABLE_KEY \
./tool/build_tester_beta.sh
```

The Apple job intentionally uses `--no-codesign`; a compiled but unsigned iOS app cannot
be installed by testers. TestFlight packaging must run in the authorized Apple signing
environment.

## Tester gate

Do not distribute a build until two fresh accounts pass this sequence on separate
devices: create account, create Room, invite by email, join, create song, contribute,
rename, speak into the composer, sign out, sign back in, and confirm the same data on web.
