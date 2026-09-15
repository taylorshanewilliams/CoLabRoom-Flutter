import 'package:colabroom/services/registered_devices.dart';
import 'package:flutter_test/flutter_test.dart';

/// The fact the notifications screen could not tell anybody.
///
/// 15 September 2026. Two messages arrived for Taylor from a tester on iOS.
/// Both created a notification, both went down the real path, and the push
/// sender's reply is in the pg_net log for each: `{"sent":2,"pruned":0}`.
/// Firebase accepted delivery to two of his Android devices. His phone showed
/// nothing.
///
/// `device_tokens` held two rows, both saying `android`, and nothing else
/// that distinguished them. Every line on the notifications screen read as
/// working, because by the only fact the screen had — "a phone is registered
/// for this account" — it was. The question nobody could ask was whether
/// either of those rows was the phone in his hand, and on this project one
/// Android row is usually the emulator, which can never draw a notification.
///
/// So the case these tests care about most is the third one: registered
/// devices exist, and none of them is this one.
void main() {
  RegisteredDevice device(
    String tail, {
    String platform = 'android',
  }) =>
      RegisteredDevice(tokenTail: tail, platform: platform);

  test('no devices says so plainly', () {
    expect(
      describeRegisteredDevices(const <RegisteredDevice>[]),
      contains('No device is registered'),
    );
  });

  test('this phone alone is the simple case', () {
    final said = describeRegisteredDevices(
      <RegisteredDevice>[device('ABCDEF')],
      myToken: 'a-long-fcm-token-ending-ABCDEF',
    );
    expect(said, contains('This Android'));
    expect(said, contains('only device'));
  });

  test('this phone plus another says a miss here is the phone', () {
    final said = describeRegisteredDevices(
      <RegisteredDevice>[device('ABCDEF'), device('123456')],
      myToken: 'a-long-fcm-token-ending-ABCDEF',
    );
    expect(said, contains('This Android is registered'));
    expect(said, contains('one other device'));
    // The useful half: two devices get every push, so one of them being
    // empty is that device and not the delivery.
    expect(said, contains('this phone, not the push'));
  });

  test('registered elsewhere and not here is the sentence that was missing',
      () {
    // Taylor's exact shape on 15 September: two android rows, and the token
    // this install holds matches neither.
    final said = describeRegisteredDevices(
      <RegisteredDevice>[device('ABCDEF'), device('123456')],
      myToken: 'a-long-fcm-token-ending-999999',
    );
    expect(said, contains('2 devices are registered'));
    expect(said, contains('none of them is this one'));
    expect(said, contains('will show up on this phone'));
    // It must never read as working in this state, which is what every other
    // line on that screen did.
    expect(said, isNot(contains('This Android is registered')));
  });

  test('an unknown token marks nothing as this phone', () {
    // iOS throws on getToken until APNs hands one over, which is the state
    // that made the screen necessary. Not knowing must not guess.
    final said = describeRegisteredDevices(
      <RegisteredDevice>[device('ABCDEF', platform: 'ios')],
      myToken: null,
    );
    expect(said, contains('none of them is this one'));
  });

  test('platforms are named the way a person names them', () {
    final said = describeRegisteredDevices(
      <RegisteredDevice>[
        device('ABCDEF'),
        device('123456', platform: 'ios'),
        device('777777', platform: 'web'),
      ],
      myToken: 'ends-ABCDEF',
    );
    expect(said, contains('iPhone'));
    expect(said, contains('Web'));
    // And an unrecognised one reads as itself rather than as a guess.
    expect(
      const RegisteredDevice(tokenTail: 'x', platform: 'fridge').platformName,
      'fridge',
    );
  });

  test('a row is only this device when the token ends with its tail', () {
    const row = RegisteredDevice(tokenTail: 'ABCDEF', platform: 'android');
    expect(row.isThisDevice('something-ABCDEF'), isTrue);
    expect(row.isThisDevice('ABCDEF-something'), isFalse);
    expect(row.isThisDevice(null), isFalse);
    // An empty tail would otherwise match every token, marking every row as
    // this phone.
    expect(
      const RegisteredDevice(tokenTail: '', platform: 'android')
          .isThisDevice('anything'),
      isFalse,
    );
  });

  test('a row is read from the server the way the function returns it', () {
    final row = RegisteredDevice.fromRow(<String, dynamic>{
      'token_tail': 'ABCDEF',
      'platform': 'android',
      'first_seen_at': '2026-09-12T10:00:00Z',
      'last_seen_at': '2026-09-15T17:50:00Z',
    });
    expect(row.tokenTail, 'ABCDEF');
    expect(row.platformName, 'Android');
    expect(row.firstSeenAt, isNotNull);
    expect(row.lastSeenAt!.isAfter(row.firstSeenAt!), isTrue);
  });
}
