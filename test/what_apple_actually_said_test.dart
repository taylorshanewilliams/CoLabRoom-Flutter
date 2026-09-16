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

  test('the two silences are told apart', () {
    // 16 September, 00:45: two devices on three networks, permission granted,
    // and Apple calling back neither way. That reading is only half an
    // answer, because it cannot say whether Apple is ignoring a request or
    // whether no request was ever made -- and UIKit ignores a registration
    // asked for off the main thread, which looks identical from here.
    const asked = ApnsState(registered: false, osRegistered: true);
    expect(asked.describe(), contains('has not answered'));
    expect(asked.describe(), contains('considers this app registered'));

    const neverAsked = ApnsState(registered: false, osRegistered: false);
    expect(neverAsked.describe(), contains('never landed'));
    expect(neverAsked.describe(), contains('nothing to'));
  });

  test('silence is never reported as a failure', () {
    // A refusal is a configuration problem and silence is not, so the two
    // must never be worded alike. Telling somebody to check their signing
    // when nothing refused anything wastes an evening, and did.
    const state = ApnsState(registered: false);
    expect(state.silent, isTrue);
    expect(state.describe(), isNot(contains('refused:')));
    expect(state.describe(), isNot(contains('Apple refused')));
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
