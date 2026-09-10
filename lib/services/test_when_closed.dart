import 'dart:async';

import 'package:flutter/widgets.dart';

import 'error_reporter.dart';
import 'push_registration.dart';

/// A push test you can actually close the app for.
///
/// The instant test works, and on 2026-09-10 it landed the first push this
/// app has ever delivered to a phone. Taylor: "it came instantly though and i
/// cant get the app closed in time to know if it works when the app is
/// closed."
///
/// That is the half that matters. Android draws a pushed notification itself
/// only while the app is in the **background**; with the app open it hands it
/// to the app, which is the path #198 fixed. The background path is a
/// different mechanism — the system reads the `notification` block and the
/// channel named by `default_notification_channel_id` — and it has never been
/// exercised, because a notification that arrives in under a second arrives
/// before anybody can press the home button.
///
/// A delay would need somewhere to run. The client cannot hold a timer across
/// being closed, which is the whole point of the test, and the database has
/// no scheduler. But the app already knows the exact moment it stops being in
/// the foreground: that is what `AppLifecycleState.paused` means. So the test
/// is sent *then*, by the app, on its way out.
///
/// One shot. Armed by a button, fired by the next pause, and disarmed either
/// way — a flag that survived would send a notification every time somebody
/// put their phone down.
class TestWhenClosed with WidgetsBindingObserver {
  TestWhenClosed._();

  static final TestWhenClosed instance = TestWhenClosed._();

  bool _armed = false;
  bool _observing = false;

  /// Whether a test is waiting for the app to be closed.
  bool get isArmed => _armed;

  /// Send one the next time this app goes to the background.
  void arm() {
    _armed = true;
    if (_observing) return;
    WidgetsBinding.instance.addObserver(this);
    _observing = true;
  }

  void disarm() => _armed = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `paused` is the app leaving the foreground. `inactive` is not: it fires
    // for a phone call, a notification shade pull, or the app switcher being
    // opened and dismissed, none of which is somebody closing the app.
    if (state != AppLifecycleState.paused) return;
    if (!_armed) return;
    _armed = false;
    unawaited(_send());
  }

  Future<void> _send() async {
    try {
      await PushRegistration.sendTestNotification();
    } catch (error) {
      // Nobody is looking at the screen by definition, so there is nothing to
      // show and somewhere to record it instead.
      unawaited(ErrorReporter().reportWarning(
        service: 'app',
        stage: 'push.test_when_closed',
        message: error.toString(),
      ));
    }
  }

  @visibleForTesting
  void handleForTesting(AppLifecycleState state) =>
      didChangeAppLifecycleState(state);
}
