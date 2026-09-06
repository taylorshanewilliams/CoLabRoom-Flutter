import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Getting this phone onto the list of places a notification can reach.
///
/// Everything here is written to fail quietly. Push is the layer on top of a
/// notification system that already works: a person whose token never
/// registers still sees every notification when they open the app, exactly as
/// they did before any of this existed. Nothing in here is allowed to be the
/// reason a screen breaks, so every path swallows its own failures and says so
/// in debug output rather than to the user.
///
/// It is also written to do nothing at all when Firebase is not configured —
/// the preview repository, the widget tests, and any build without the config
/// files. Those all run without a Firebase app, and calling into
/// firebase_messaging there throws.
abstract final class PushRegistration {
  static bool _started = false;
  static bool _available = false;
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
      if (kDebugMode) debugPrint('Push unavailable: $error');
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
      await _registerToken();
      // A token is rotated by the OS — a restore onto a new phone, a reinstall,
      // Firebase deciding it is stale. Without this the row goes quietly out of
      // date and delivery stops with nothing to show why.
      _refresh ??= FirebaseMessaging.instance.onTokenRefresh
          .listen((token) => unawaited(_send(token)));
      return true;
    } catch (error) {
      if (kDebugMode) debugPrint('Push could not be enabled: $error');
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

  static Future<void> _registerToken() async {
    final token = await FirebaseMessaging.instance.getToken();
    if (token == null || token.isEmpty) return;
    await _send(token);
  }

  static Future<void> _send(String token) async {
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
      if (kDebugMode) debugPrint('Push token not registered: $error');
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
    if (!_available) return;
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null || token.isEmpty) return;
      await Supabase.instance.client.rpc<void>(
        'forget_device_token',
        params: <String, dynamic>{'device_token': token},
      );
    } catch (error) {
      if (kDebugMode) debugPrint('Push token not forgotten: $error');
    }
  }
}
