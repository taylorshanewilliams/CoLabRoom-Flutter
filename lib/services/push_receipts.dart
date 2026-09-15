import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app/beta_config.dart';
import 'error_reporter.dart';

/// How a push reached the phone.
enum PushArrival {
  /// The background handler ran: the phone received it with the app not in
  /// front. The one kind of delivery nobody can prove by watching a screen.
  closed,

  /// It arrived while the app was open and the app drew it itself.
  open,

  /// The person opened the app from it.
  tapped,
}

/// The receipt, from the isolate Android gives a closed app.
///
/// A top-level function, because that is the only kind firebase_messaging
/// can run when the app is not in front: it spins up a fresh isolate with
/// nothing from `main()` in it, so Firebase and Supabase are brought up
/// here, once per isolate, before the receipt can be sent. If the session
/// cannot be recovered there is nobody to send it as, and the warning says
/// so rather than the row lying about it.
@pragma('vm:entry-point')
Future<void> pushArrivedWithTheAppClosed(RemoteMessage message) async {
  await PushReceipts.prepareBackgroundIsolate();
  await PushReceipts.arrived(message, PushArrival.closed);
}

/// The phone, saying it got one.
///
/// Taylor, 14 Sep: "never actually gotten a notification to my phone from a
/// real event." The server's answer that night was six pushes to his phone,
/// every one accepted by FCM -- and no way to know what the phone did with
/// them. FCM accepting a message means it left the building. Whether the
/// phone drew it is a fact only the phone has, and until now it kept it.
///
/// So each push carries the notification's id (send-push has done that since
/// 0051), and whenever one arrives -- however it arrives -- the app tells
/// the server which one and how. The settings screen reads the week's
/// totals back as one sentence, and "six sent, six arrived" ends the doubt
/// where "six sent, none arrived" names the bug.
abstract final class PushReceipts {
  static bool _started = false;
  static bool _backgroundReady = false;
  static StreamSubscription<RemoteMessage>? _opened;

  /// Where a tapped push should take somebody, once there is a screen to
  /// take them to. Installed by the shell; a tap that lands before then is
  /// kept and handed over when it is.
  static void Function(RemoteMessage message)? _onTapped;
  static RemoteMessage? _pendingTap;

  /// Registers the handlers. Safe without Firebase: does nothing.
  static Future<void> start({required bool available}) async {
    if (_started || !available) return;
    _started = true;
    try {
      FirebaseMessaging.onBackgroundMessage(pushArrivedWithTheAppClosed);
      _opened ??= FirebaseMessaging.onMessageOpenedApp.listen(_tapped);
      // The app was closed and opened from a notification: the tap is the
      // launch itself, and only this call can see it.
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) _tapped(initial);
    } catch (error) {
      unawaited(ErrorReporter().reportWarning(
        service: 'app',
        stage: 'push.receipts.start',
        message: error.toString(),
      ));
    }
  }

  static void _tapped(RemoteMessage message) {
    unawaited(arrived(message, PushArrival.tapped));
    final handler = _onTapped;
    if (handler == null) {
      _pendingTap = message;
      return;
    }
    handler(message);
  }

  /// The shell, saying where a tapped push goes. Delivers a tap that
  /// arrived before the shell existed.
  static void onTapped(void Function(RemoteMessage message)? handler) {
    _onTapped = handler;
    final pending = _pendingTap;
    if (handler != null && pending != null) {
      _pendingTap = null;
      handler(pending);
    }
  }

  /// The notification a push is about, or null for one that carries none.
  static String? notificationIdOf(RemoteMessage message) {
    final raw = message.data['notification_id'];
    if (raw is! String) return null;
    final id = raw.trim();
    return id.isEmpty ? null : id;
  }

  /// Tells the server this one arrived, and how. Quiet to the person,
  /// reported to us: a receipt that fails is the bug this exists to find.
  static Future<void> arrived(RemoteMessage message, PushArrival how) async {
    final id = notificationIdOf(message);
    if (id == null) return;
    try {
      await Supabase.instance.client.rpc<void>(
        'push_arrived',
        params: <String, dynamic>{'notification_id': id, 'how': how.name},
      );
    } catch (error) {
      unawaited(ErrorReporter().reportWarning(
        service: 'app',
        stage: 'push.arrived.${how.name}',
        message: error.toString(),
      ));
    }
  }

  /// Brings Firebase and Supabase up in an isolate that has neither. Once
  /// per isolate: Android keeps the background isolate alive between
  /// messages, and initialising Supabase twice in one is an error.
  static Future<void> prepareBackgroundIsolate() async {
    if (_backgroundReady) return;
    _backgroundReady = true;
    try {
      await Firebase.initializeApp();
    } catch (_) {
      // Already up in this isolate, or no config in this build. Either way
      // the receipt below is what matters, and it needs only Supabase.
    }
    if (!BetaConfig.hasSupabase) return;
    try {
      await Supabase.initialize(
        url: BetaConfig.supabaseUrl,
        publishableKey: BetaConfig.supabaseAnonKey,
      );
    } catch (error) {
      // Recorded through the client that failed to start, if it started
      // enough to record anything; otherwise nowhere, which is honest.
      if (kDebugMode) debugPrint('push receipt: $error');
    }
  }

  @visibleForTesting
  static Future<void> stop() async {
    await _opened?.cancel();
    _opened = null;
    _onTapped = null;
    _pendingTap = null;
    _started = false;
  }
}
