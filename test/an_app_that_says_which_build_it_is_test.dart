import 'package:colabroom/app/beta_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// The app says which build it is.
///
/// Taylor, on an APK built from a commit that provably contained the change
/// he was looking for: "my apk still has the old emoji icons... and i dont
/// see the friends section at all." One of those was true (the friends work
/// landed three commits later) and one could not be settled either way,
/// because every build this app has ever produced reports the same version
/// number.
///
/// So an install that silently failed to replace its predecessor looks
/// exactly like one that worked, and the only way to tell was to read the
/// code and guess. `appVersion` answers "which release"; nothing answered
/// "which build", which is the question people actually ask.
void main() {
  test('the version is kept in step with pubspec', () {
    // This drifted three releases once, and every crash report, help request
    // and usage row was labelled 0.3.0 while 0.4.0 shipped. A version that
    // lies is worse than none: it points triage at the wrong build.
    expect(BetaConfig.appVersion, '0.4.1');
  });

  test('a build made outside CI says so rather than claiming a commit', () {
    // No --dart-define here, so this is the default. It must never guess at
    // a commit it may not match — "local" is the honest answer for anything
    // built on somebody's own machine.
    expect(BetaConfig.buildRef, 'local');
  });

  test('the two are shown together, because either alone is ambiguous', () {
    expect(BetaConfig.fullVersion, '0.4.1 (local)');
  });
}
