import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'error_reporter.dart';

/// Putting a notification where somebody can see it.
///
/// The whole delivery chain worked and nothing appeared. On 2026-09-10 the
/// database had a device token, the trigger fired, and the Edge Function came
/// back `{"sent":1,"pruned":0}` with a 200 — FCM accepted the message — while
/// Taylor watched his phone and got nothing.
///
/// The reason is a piece of Android behaviour that is documented, easy to
/// miss, and produces exactly this: **a message with a `notification` block
/// is drawn by the system only when the app is in the background.** With the
/// app open, FCM hands it to the app instead and expects the app to decide
/// what to do. This app had no `onMessage` listener at all, so the answer was
/// nothing — and "I pressed the test button and nothing happened" is the same
/// symptom as a broken key, a dead token or a missing function, all of which
/// we had already ruled out.
///
/// Two things are needed and neither existed:
///
///   * a channel. Android 8 and later will not show a notification without
///     one, and `default_notification_channel_id` in the manifest has to name
///     a channel the app has actually created — naming one that does not
///     exist drops the notification silently.
///   * something to draw it while the app is open.
abstract final class NotificationShade {
  /// Must match `default_notification_channel_id` in AndroidManifest.xml.
  ///
  /// If these two ever drift apart, Android drops every notification that
  /// arrives while the app is closed and says nothing about why.
  static const String channelId = 'colabroom_default';
  static const String channelName = 'CoLabRoom';
  static const String channelDescription =
      'Asks, invites, and word that somebody has added something.';

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _started = false;
  static StreamSubscription<RemoteMessage>? _foreground;

  /// Creates the channel and starts listening for messages that arrive while
  /// the app is open.
  ///
  /// Safe to call when push is unavailable — it simply does nothing, the same
  /// as every other part of this path.
  static Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            // All false: firebase_messaging already asks, at a moment that
            // has earned it. Asking twice spends the one iOS dialog on
            // whichever of the two happens to run first.
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
      );

      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(
        const AndroidNotificationChannel(
          channelId,
          channelName,
          description: channelDescription,
          importance: Importance.high,
        ),
      );

      _foreground ??= FirebaseMessaging.onMessage.listen(_show);
    } catch (error) {
      // Never the reason the app fails to start. Reported, because a silent
      // failure here looks exactly like the bug it was written to fix.
      unawaited(ErrorReporter().reportWarning(
        service: 'app',
        stage: 'shade.start',
        message: error.toString(),
      ));
    }
  }

  static Future<void> _show(RemoteMessage message) async {
    final notification = message.notification;
    if (notification == null) return;
    try {
      await _plugin.show(
        // The notification's own id, so the same one arriving twice replaces
        // itself rather than stacking.
        id: notification.hashCode,
        title: notification.title,
        body: notification.body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            channelName,
            channelDescription: channelDescription,
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
      );
    } catch (error) {
      unawaited(ErrorReporter().reportWarning(
        service: 'app',
        stage: 'shade.show',
        message: error.toString(),
      ));
    }
  }

  @visibleForTesting
  static Future<void> stop() async {
    await _foreground?.cancel();
    _foreground = null;
    _started = false;
  }
}
