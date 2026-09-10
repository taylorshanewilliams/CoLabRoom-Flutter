import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
      final registered = await _registerToken();
      if (!registered) return false;
      // A token is rotated by the OS — a restore onto a new phone, a reinstall,
      // Firebase deciding it is stale. Without this the row goes quietly out of
      // date and delivery stops with nothing to show why.
      _refresh ??= FirebaseMessaging.instance.onTokenRefresh
          .listen((token) => unawaited(_send(token)));
      return true;
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
  static Future<void> refreshIfAllowed() async {
    if (!_available) return;
    if (!await isAllowed()) return;
    await _registerToken();
    _refresh ??= FirebaseMessaging.instance.onTokenRefresh
        .listen((token) => unawaited(_send(token)));
  }

  /// True when this phone is now on the list a notification can reach.
  ///
  /// A null token is its own answer and not an error: on iOS it is what
  /// `getToken` returns when the project has no APNs key, which is the state
  /// this app has been in since push shipped. Reported, because it is
  /// indistinguishable from success everywhere else in the app.
  static Future<bool> _registerToken() async {
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

  /// True when the token reached the database.
  static Future<bool> _send(String token) async {
    try {
      await Supabase.instance.client.rpc<void>(
        'register_device_token',
        params: <String, dynamic>{
          'device_token': token,
          'device_platform': defaultTargetPlatform == TargetPlatform.iOS
              ? 'ios'
              : 'android',
        },
      );
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
