import 'package:flutter/services.dart';

/// What Apple actually said about registering this phone for push.
///
/// 15 September 2026: a tester's iPhone reported "No APNs token after 30s
/// (permission authorized)" and the token call never threw. Signing was ruled
/// out twice over -- the App ID carries PUSH_NOTIFICATIONS, and the profile
/// and the signed binary both carry `aps-environment: production`. So iOS was
/// either refusing the registration or never answering it, and those need
/// different fixes.
///
/// Apple says which, through
/// `didFailToRegisterForRemoteNotificationsWithError`. firebase_messaging
/// implements that callback and its entire body is one `NSLog`, so the reason
/// reached no log anybody could read without the phone plugged into a Mac.
///
/// The iOS half of this is a small class the build writes into the Runner
/// target, registered through Flutter's own `addApplicationDelegate`, which
/// is the supported way to see those callbacks without subclassing
/// `FlutterAppDelegate`. This is the Dart side of that channel.
class ApnsState {
  const ApnsState({required this.registered, this.failure});

  /// True once Apple has handed this app a device token, ever, this launch.
  final bool registered;

  /// Apple's own words when it refused, or null if it never refused.
  final String? failure;

  /// Neither answered nor refused.
  ///
  /// The most useful of the three states and the one nothing could say
  /// before: a device that cannot reach Apple's push service gets no token
  /// and no error, which is what a blocked network looks like from inside the
  /// app. A refusal is a configuration problem; silence is a connectivity
  /// one.
  bool get silent => !registered && failure == null;

  /// The clause this contributes to the report, or empty when it knows
  /// nothing worth adding.
  String describe() {
    if (failure != null) return '; Apple refused: $failure';
    if (registered) return '; Apple did hand over a token at some point';
    return '; Apple neither answered nor refused, which is what a device that '
        'cannot reach the push service looks like';
  }
}

/// The channel the iOS build installs. Absent everywhere else, on purpose.
abstract final class ApnsWatcher {
  static const MethodChannel _channel = MethodChannel('colabroom/apns');

  /// Null on Android, on web, and on any iOS build made before the watcher
  /// existed. Never throws: this is a diagnostic, and a diagnostic that can
  /// break the thing it is watching is worse than none.
  static Future<ApnsState?> state() async {
    try {
      final map = await _channel.invokeMapMethod<String, dynamic>('apnsState');
      if (map == null) return null;
      return ApnsState(
        registered: map['registered'] == true,
        failure: map['failure'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}
