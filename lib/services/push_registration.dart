import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'push_delivery_report.dart';
import 'registered_devices.dart';
import 'retry.dart';
import 'user_facing_error.dart';

/// Getting this phone onto the list of places a notification can reach.
///
/// Everything here is written to fail quietly. Push is the layer on top of a
/// notification system that already works: a person whose token never
/// registers still sees every notification when they open the app, exactly as
/// they did before any of this existed. Nothing in here is allowed to be the
/// reason a screen breaks.
///
/// Quietly to the *person*, though - not quietly to us. Every failure here
/// used to end in `if (kDebugMode) debugPrint(...)`, which is nothing at all
/// in a release build, and on 2026-09-10 that turned out to matter: production
/// held **zero device tokens and always had**, against 184 notifications, and
/// there was no way to tell whether that was nobody saying yes or every
/// registration failing. Failures are reported now. See [reportAndDescribe].
///
/// It is also written to do nothing at all when Firebase is not configured —
/// the preview repository, the widget tests, and any build without the config
/// files. Those all run without a Firebase app, and calling into
/// firebase_messaging there throws.
abstract final class PushRegistration {
  static bool _started = false;
  static bool _available = false;

  /// Whether this phone's token reached the database, this session.
  ///
  /// Separate from the OS permission on purpose, and the whole point of it.
  /// The settings screen used to read `getNotificationSettings` and say
  /// "Notifications reach you when the app is closed" on the strength of it -
  /// which is a claim about the OS, not about this app being able to reach
  /// you. On 2026-09-10 that sentence was false for every account in
  /// production: the permission side can be perfectly true while
  /// `device_tokens` is empty.
  static bool _registered = false;
  static bool get isRegistered => _registered;
  static StreamSubscription<String>? _refresh;

  /// Whether this build has a Firebase app to talk to.
  static bool get isAvailable => _available;

  /// Brings Firebase up, once, at launch.
  ///
  /// Deliberately does **not** ask for permission. On iOS the permission
  /// dialog can only be shown once for the life of an install, so spending it
  /// on the first launch — before somebody knows what the app is or why it
  /// would want to interrupt them — is spending the only chance there is on
  /// the worst possible moment. See [enable].
  static Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      await Firebase.initializeApp();
      _available = true;
    } catch (error) {
      // No config files in this build, or a platform without them. Everything
      // below turns into a no-op and the app is otherwise unaffected.
      _available = false;
      // A warning rather than an error, and reported once per launch: on web
      // and in the preview build this is the expected, correct outcome. It is
      // worth a row anyway, because "Firebase would not start on a real phone"
      // and "this is the web build" are indistinguishable from the outside,
      // and the first one silently removes push for everybody on that build.
      reportWarningAndDescribe(
        error,
        service: 'app',
        stage: 'push.unavailable',
      );
    }
  }

  /// Whether this person has already allowed notifications on this device.
  static Future<bool> isAllowed() async {
    if (!_available) return false;
    try {
      final settings = await FirebaseMessaging.instance.getNotificationSettings();
      return settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
    } catch (_) {
      return false;
    }
  }

  /// Asks for permission if it has not been asked for, then registers this
  /// device against the signed-in account.
  ///
  /// Returns whether notifications can now be delivered. Call this from a
  /// moment that has earned it — somebody who has just asked their room for a
  /// bridge has a reason to want to know when it arrives, and that is a very
  /// different question from the same dialog on a launch screen.
  static Future<bool> enable() async {
    if (!_available) return false;
    try {
      final settings = await FirebaseMessaging.instance.requestPermission();
      final allowed =
          settings.authorizationStatus == AuthorizationStatus.authorized ||
              settings.authorizationStatus == AuthorizationStatus.provisional;
      if (!allowed) return false;
      // A token is rotated by the OS — a restore onto a new phone, a reinstall,
      // Firebase deciding it is stale. Without this the row goes quietly out of
      // date and delivery stops with nothing to show why. Subscribed *before*
      // the first registration: on iOS the token can arrive through this
      // stream a moment after `getToken` has already given up.
      _refresh ??= FirebaseMessaging.instance.onTokenRefresh
          .listen((token) => unawaited(_send(token)));
      return await _registerToken();
    } catch (error) {
      reportAndDescribe(error, service: 'app', stage: 'push.enable');
      return false;
    }
  }

  /// Re-registers on launch for somebody who has already said yes.
  ///
  /// Cheap, and it covers the cases a one-time registration misses: the token
  /// changed while the app was closed, or the row was pruned as dead after a
  /// spell without the app.
  ///
  /// Wrapped, because it runs on every launch and it is where an iPhone
  /// threw on 2026-09-13. `getToken` on iOS raises `apns-token-not-set` until
  /// Apple has handed the app its APNs token, and this path had no catch —
  /// so the exception reached the global handler and a bandmate was shown an
  /// error every single time they opened the app. Nothing in here may be the
  /// reason a screen breaks; see the note at the top of this file.
  static Future<void> refreshIfAllowed() async {
    if (!_available) return;
    try {
      if (!await isAllowed()) return;
      // On iOS the APNs token is handed over only after the app registers
      // for remote notifications, and firebase_messaging does that inside
      // requestPermission. Once permission has been decided this shows
      // nothing and returns the answer at once -- but it is the call that
      // asks Apple for the token in this process, and a launch that never
      // made it sat for ten seconds waiting on a token nobody had requested
      // (an iPhone on 0.4.2, 14 Sep 2026, permission already granted).
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
        await FirebaseMessaging.instance.requestPermission();
      }
      _refresh ??= FirebaseMessaging.instance.onTokenRefresh
          .listen((token) => unawaited(_send(token)));
      await _registerToken();
    } catch (error) {
      reportAndDescribe(error, service: 'app', stage: 'push.refresh');
    }
  }

  /// True when this phone is now on the list a notification can reach.
  ///
  /// A null token is its own answer and not an error: on iOS it is what
  /// `getToken` returns when the project has no APNs key, which is the state
  /// this app has been in since push shipped. Reported, because it is
  /// indistinguishable from success everywhere else in the app.
  static Future<bool> _registerToken() async {
    if (!await _waitForApns()) {
      _registered = false;
      return false;
    }
    final token = await FirebaseMessaging.instance.getToken();
    if (token == null || token.isEmpty) {
      reportWarningAndDescribe(
        StateError('getToken returned no token; on iOS this means the '
            'Firebase project has no APNs key'),
        service: 'app',
        stage: 'push.no_token',
      );
      _registered = false;
      return false;
    }
    final sent = await _send(token);
    _registered = sent;
    return sent;
  }

  /// On iOS, the FCM token cannot exist until the APNs token does.
  ///
  /// Apple hands the app its APNs token asynchronously, usually within a
  /// second of permission being granted, and `getToken` throws
  /// `apns-token-not-set` if asked before then. Every iOS attempt in this
  /// app's history was asked before then. So: ask for the APNs token first
  /// and give it ten seconds, which is a long time for something that
  /// normally takes one. On Android there is no such token and this is a
  /// no-op.
  ///
  /// False means "not this time", reported as a warning rather than an
  /// error: the refresh listener is already subscribed, so if the token
  /// turns up late it still registers.
  ///
  /// Thirty seconds rather than ten, and the reason is what ten seconds
  /// could not tell anybody. On 15 September a tester's iPhone reported "No
  /// APNs token after ten seconds (permission authorized)" three times in
  /// one day, and everything else was then ruled out: the App ID carries
  /// PUSH_NOTIFICATIONS, the active provisioning profile carries
  /// `aps-environment: production`, the Firebase config matches the bundle,
  /// and firebase_messaging asks Apple for the token itself at plugin
  /// startup. So the token is being asked for and not arriving inside ten
  /// seconds, and "refused" and "slower than the deadline" produced exactly
  /// the same sentence.
  ///
  /// They do not any more. A token that turns up late is reported as having
  /// turned up late, with the number of seconds, which is the difference
  /// between a bug in Apple's answer and a bug in our patience. Nothing
  /// blocks on this: `refreshIfAllowed` is launched unawaited.
  static Future<bool> _waitForApns() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return true;
    final started = DateTime.now();
    // What getAPNSToken itself said, if it did more than return null. An
    // exception here used to escape the whole loop and be reported as a
    // refresh failure, which named the wrong thing.
    String? complaint;
    for (var tick = 0; tick < 60; tick++) {
      try {
        final apns = await FirebaseMessaging.instance.getAPNSToken();
        if (apns != null && apns.isNotEmpty) {
          final waited = DateTime.now().difference(started);
          if (waited.inSeconds >= 8) {
            reportWarningAndDescribe(
              StateError('APNs token arrived after ${waited.inSeconds}s. '
                  'Under the old ten-second limit this phone would have been '
                  'reported as never getting one.'),
              service: 'app',
              stage: 'push.apns_slow',
            );
          }
          return true;
        }
      } catch (error) {
        complaint = error.toString();
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    // The report says what permission the phone believes it has, because
    // "no token" means two different things: not asked yet, or asked and
    // never answered by Apple. Only the second is a fault worth chasing.
    String permission;
    try {
      final settings = await FirebaseMessaging.instance.getNotificationSettings();
      permission = settings.authorizationStatus.name;
    } catch (_) {
      permission = 'unknown';
    }
    final waited = DateTime.now().difference(started).inSeconds;
    reportWarningAndDescribe(
      StateError('No APNs token after ${waited}s (permission $permission)'
          '${complaint == null ? '' : '; getAPNSToken said: $complaint'}. '
          'Signing is not the cause: the App ID carries PUSH_NOTIFICATIONS '
          'and the active profile carries aps-environment. Will register on '
          'the next refresh instead.'),
      service: 'app',
      stage: 'push.no_apns',
    );
    return false;
  }

  /// True when the token reached the database.
  ///
  /// Tries three times, because the one recorded failure of this call was a
  /// gateway timeout — over by the time anybody read it — and a phone that
  /// has said yes should not stay unreachable until its next launch over a
  /// second of bad luck.
  static Future<bool> _send(String token) async {
    try {
      await retrying(() => Supabase.instance.client.rpc<void>(
            'register_device_token',
            params: <String, dynamic>{
              'device_token': token,
              'device_platform': defaultTargetPlatform == TargetPlatform.iOS
                  ? 'ios'
                  : 'android',
            },
          ));
    } catch (error) {
      // The single most important failure in this file. If this throws, the
      // person has said yes, the OS has agreed, and the app still cannot be
      // reached - which is exactly the state production has been in since the
      // feature shipped, with nothing anywhere to say so.
      reportAndDescribe(error, service: 'app', stage: 'push.register_token');
      return false;
    }
    return true;
  }

  /// Whether the server agrees this account has a reachable phone.
  ///
  /// [isRegistered] is this session's memory of one call. This is the
  /// database's answer, which is the one that decides whether a notification
  /// can actually be delivered, and it survives a restart. `device_tokens` is
  /// closed to clients - a token is a credential - so this asks a function
  /// for the fact rather than for the row.
  static Future<bool> reachesThisAccount() async {
    try {
      _registered = await Supabase.instance.client.rpc<bool>('push_reaches_me');
      return _registered;
    } catch (error) {
      reportAndDescribe(error, service: 'app', stage: 'push.reaches_me');
      return false;
    }
  }

  /// Sends this account a real notification, down the real path.
  ///
  /// False when no phone is registered, which is the answer worth having:
  /// the button that calls this is there to tell somebody whether the chain
  /// works, and a test that reports success while reaching nothing is the
  /// failure it was built to catch.
  static Future<bool> sendTestNotification() async {
    return Supabase.instance.client.rpc<bool>('send_myself_a_test_notification');
  }

  /// The week's pushes, as the server counted them out and the phone
  /// confirmed them back. Null when it cannot be fetched: the screen then
  /// says nothing rather than something wrong.
  static Future<PushDeliveryReport?> deliveryReport() async {
    try {
      final rows =
          await Supabase.instance.client.rpc<dynamic>('push_delivery_report');
      final row = rows is List ? (rows.isEmpty ? null : rows.first) : rows;
      if (row is! Map) return null;
      return PushDeliveryReport.fromRow(Map<String, dynamic>.from(row));
    } catch (error) {
      reportAndDescribe(error, service: 'app', stage: 'push.delivery_report');
      return null;
    }
  }

  /// The devices registered to this account, most recently seen first, and
  /// this install's own token so the screen can say which row is this phone.
  ///
  /// The token is fetched rather than remembered because nothing here keeps
  /// it: `getToken` answers from the local cache after the first call, and a
  /// token that has changed since registration should read as a device that
  /// is not this one, which is the truth.
  ///
  /// Null when it cannot be fetched, so the screen says nothing rather than
  /// something wrong.
  static Future<({List<RegisteredDevice> devices, String? myToken})?>
      registeredDevices() async {
    try {
      final rows = await Supabase.instance.client.rpc<dynamic>('my_devices');
      final devices = <RegisteredDevice>[
        if (rows is List)
          for (final row in rows)
            if (row is Map)
              RegisteredDevice.fromRow(Map<String, dynamic>.from(row)),
      ];
      String? mine;
      try {
        mine = await FirebaseMessaging.instance.getToken();
      } catch (_) {
        // On iOS this throws until APNs hands over a token, which is the
        // state that made this screen necessary. An unknown token means no
        // row gets marked as this phone, which is the honest answer.
        mine = null;
      }
      return (devices: devices, myToken: mine);
    } catch (error) {
      reportAndDescribe(error, service: 'app', stage: 'push.my_devices');
      return null;
    }
  }

  /// Signing out, so the next person to use this phone does not receive the
  /// last one's notifications.
  ///
  /// The table is keyed on the token, so a different account signing in on
  /// this device would move the row anyway — but somebody who signs out and
  /// hands the phone back should not have to rely on that.
  static Future<void> forget() async {
    // First, and outside the availability check: a listener registered for the
    // account that is leaving has no business surviving into the next one's
    // session, handing them a token refresh for somebody else's row.
    await _refresh?.cancel();
    _refresh = null;
    _registered = false;
    if (!_available) return;
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null || token.isEmpty) return;
      await Supabase.instance.client.rpc<void>(
        'forget_device_token',
        params: <String, dynamic>{'device_token': token},
      );
    } catch (error) {
      reportAndDescribe(error, service: 'app', stage: 'push.forget_token');
    }
  }
}
