import 'package:colabroom/services/apns_watcher.dart';
import 'package:flutter_test/flutter_test.dart';

/// Three states that looked identical for a week.
///
/// A tester's iPhone reported "No APNs token after 30s (permission
/// authorized)" on 15 September 2026, and the token call never threw. Signing
/// was ruled out twice: the App ID carries PUSH_NOTIFICATIONS, and the
/// provisioning profile and the signed binary both carry
/// `aps-environment: production`.
///
/// So iOS was either refusing the registration or never answering it. Apple
/// says which, through a callback whose entire implementation in
/// firebase_messaging is one `NSLog`, so the answer reached nobody. These pin
/// the three cases apart, because they need different fixes and only one of
/// them is ours.
void main() {
  test('a refusal is quoted, because the words are the diagnosis', () {
    const state = ApnsState(
      registered: false,
      failure: 'NSCocoaErrorDomain 3000: no valid aps-environment entitlement '
          'string found for application',
    );
    expect(state.silent, isFalse);
    expect(state.describe(), contains('Apple refused'));
    expect(state.describe(), contains('aps-environment'));
  });

  test('silence is named as silence, not as failure', () {
    // The case nothing could say before, and the most useful one: no token
    // and no error is what a device that cannot reach Apple's push service
    // looks like from inside the app. A refusal is a configuration problem.
    // Silence is a connectivity one, and telling a person to check their
    // signing when their WiFi is the problem wastes another evening.
    const state = ApnsState(registered: false);
    expect(state.silent, isTrue);
    expect(state.describe(), contains('neither answered nor refused'));
    expect(state.describe(), contains('cannot reach the push service'));
    expect(state.describe(), isNot(contains('refused:')));
  });

  test('a token that did arrive is not silence', () {
    const state = ApnsState(registered: true);
    expect(state.silent, isFalse);
    expect(state.describe(), contains('did hand over a token'));
  });

  test('a refusal outranks having registered earlier', () {
    // Both can be true across one launch. What went wrong is the half worth
    // reporting; "it worked once" explains nothing about why it stopped.
    const state = ApnsState(registered: true, failure: 'BOOM');
    expect(state.describe(), contains('Apple refused: BOOM'));
    expect(state.silent, isFalse);
  });
}
