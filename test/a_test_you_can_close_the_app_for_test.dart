import 'package:colabroom/services/test_when_closed.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// A push test you can actually close the app for.
///
/// The instant test works — on 2026-09-10 it landed the first push this app
/// has ever delivered to a phone. Taylor: "it came instantly though and i
/// cant get the app closed in time to know if it works when the app is
/// closed."
///
/// That is the half that matters, and it is a different mechanism. Android
/// draws a pushed notification itself only while the app is in the
/// background; with the app open it hands it to the app, which is the path
/// #198 fixed. The background path has never been exercised, because a
/// notification that arrives in under a second arrives before anybody can
/// press the home button.
///
/// A delay needs somewhere to run. The client cannot hold a timer across
/// being closed — that is the whole point — and the database has no
/// scheduler. But the app knows the exact moment it stops being in the
/// foreground, so the test sends itself on the way out.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(TestWhenClosed.instance.disarm);

  test('nothing is armed until somebody asks for it', () {
    expect(TestWhenClosed.instance.isArmed, isFalse);
  });

  test('arming survives until the app is closed', () {
    TestWhenClosed.instance.arm();
    expect(TestWhenClosed.instance.isArmed, isTrue);
  });

  test('inactive is not closed', () {
    // `inactive` fires for a phone call, a pull of the notification shade, or
    // the app switcher being opened and dismissed. None of those is somebody
    // closing the app, and firing on them would send the test while they are
    // still looking at the screen — which is the case that already works.
    TestWhenClosed.instance.arm();
    TestWhenClosed.instance.handleForTesting(AppLifecycleState.inactive);
    expect(TestWhenClosed.instance.isArmed, isTrue,
        reason: 'still waiting for the app to actually go away');
  });

  test('it fires once, and disarms itself', () {
    // A flag that survived would send a notification every time somebody put
    // their phone down.
    TestWhenClosed.instance.arm();
    TestWhenClosed.instance.handleForTesting(AppLifecycleState.paused);
    expect(TestWhenClosed.instance.isArmed, isFalse);

    // A second pause with nothing armed must do nothing at all.
    TestWhenClosed.instance.handleForTesting(AppLifecycleState.paused);
    expect(TestWhenClosed.instance.isArmed, isFalse);
  });
}
