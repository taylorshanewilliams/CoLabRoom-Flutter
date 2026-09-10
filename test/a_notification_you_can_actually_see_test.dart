import 'dart:io';

import 'package:colabroom/services/notification_shade.dart';
import 'package:flutter_test/flutter_test.dart';

/// A notification somebody can actually see.
///
/// The delivery chain worked and nothing appeared. On 2026-09-10 the database
/// had a device token, the trigger fired, and the Edge Function came back
/// `{"sent":1,"pruned":0}` with a 200 — FCM accepted the message — while
/// Taylor watched his phone and got nothing.
///
/// Two causes, both of them Android behaviour that is documented and easy to
/// miss:
///
///   A message with a `notification` block is drawn by the system **only
///   while the app is in the background**. With the app open FCM hands it to
///   the app and expects the app to decide. There was no `onMessage` listener
///   at all, so the answer was nothing — and pressing the test button and
///   staring at the screen is precisely the case that produces.
///
///   Android 8 and later will not show a notification without a channel, and
///   `default_notification_channel_id` in the manifest has to name one the
///   app has created. Naming one that does not exist drops every notification
///   silently.
void main() {
  test('the manifest names the channel the app creates', () {
    // These two live in different files, in different languages, and nothing
    // connects them but this test. If they drift, Android stops showing
    // notifications that arrive while the app is closed and says nothing
    // about why — which is a week of looking in the wrong place.
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

    expect(
      manifest.contains('com.google.firebase.messaging.default_notification_channel_id'),
      isTrue,
      reason: 'without it Android picks a fallback channel, and on some '
          'devices picks nothing',
    );
    expect(
      manifest.contains('android:value="${NotificationShade.channelId}"'),
      isTrue,
      reason: 'the manifest must name the channel NotificationShade creates, '
          'character for character',
    );
  });

  test('the channel is described in words a person would recognise', () {
    // This text is visible in Android settings, where somebody decides
    // whether to keep notifications on. "CoLabRoom / Miscellaneous" is what
    // an app gets when it never bothered.
    expect(NotificationShade.channelName, 'CoLabRoom');
    expect(NotificationShade.channelDescription, isNotEmpty);
    expect(NotificationShade.channelDescription.length, greaterThan(20));
  });
}
