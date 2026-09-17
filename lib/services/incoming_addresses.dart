import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter/widgets.dart';

/// An address arriving from outside the app: the browser's forward button on
/// the web, a tapped link or a scanned QR code on a phone.
///
/// Four times in the week of 9 September 2026 the web build died with
///
///   Null check operator used on a null value
///   while dispatching notifications for
///   WidgetsBindingObserver.didPushRouteInformation
///
/// Here is the chain. `BrowserHistory` gives every screen a history entry,
/// so the back button works. Going back then makes the *forward* button
/// live, and pressing it hands the address to the framework as a push. The
/// framework's own observer answers a push by calling `pushNamed` on the
/// navigator `MaterialApp` built — which has a `home` and no route
/// generator, because every real route in this app lives on the nested
/// navigator inside [WorkspaceShell]. No generator, no unknown-route
/// handler, and the framework asserts on the null.
///
/// So this observer is registered *before* the framework's, and answers
/// first: a known address is opened on the navigator that actually holds the
/// app, and anything else is swallowed. Returning true is the whole fix;
/// the rest is making forward mean forward.
///
/// **Phones, 16 September 2026.** Links to app.colabroom.com open the app
/// when it is installed (App Links; see the manifest). Flutter hands a phone
/// the whole link — `https://app.colabroom.com/lesson/<code>` — as the
/// initial route when the link starts the app, and as exactly the same push
/// when the app is already open, so the same crash was waiting there. It was
/// already happening to one address: Supabase's sign-in callback,
/// `com.colabroom.beta://login-callback`, is pushed the same way whenever it
/// comes back to a running app. That one is not ours — supabase_flutter
/// reads it on its own channel — and it is swallowed without reaching the
/// shell.
///
/// **iPhones, the same day.** A Universal Link reaches a Flutter app the same
/// way in principle, but on a cold start the engine gives the app three
/// seconds to draw its first frame and otherwise hands the link back to
/// Safari -- and this app waits on Supabase and Firebase before its first
/// frame. So on iOS the engine's own deep linking is switched off
/// (`FlutterDeepLinkingEnabled` false, set in build-ios-testflight.yml) and
/// links arrive instead through app_links, which keeps the launch link until
/// somebody asks for it and has no deadline. They go through [arrive] exactly
/// as a pushed address does.
class IncomingAddresses with WidgetsBindingObserver {
  /// Public so a test can drive one directly. Production has exactly one,
  /// made by [install].
  IncomingAddresses();

  /// The site whose links the phone app claims.
  static const host = 'app.colabroom.com';

  static IncomingAddresses? _installed;
  static StreamSubscription<Uri>? _links;
  static void Function(Uri address)? _open;
  static Uri? _waiting;
  static bool _arrivalTaken = false;

  /// Registers the one instance, once.
  ///
  /// Must run before `runApp`: the binding dispatches to observers in the
  /// order they were added and stops at the first that says it handled the
  /// push. `WidgetsApp` adds itself when it mounts, so anything added before
  /// `runApp` is asked before it.
  static void install({Stream<Uri>? links}) {
    if (_installed != null) return;
    final observer = IncomingAddresses();
    _installed = observer;
    WidgetsBinding.instance.addObserver(observer);
    final phoneLinks = links ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS ? AppLinks().uriLinkStream : null);
    _links = phoneLinks?.listen(arrive, onError: (Object _) {});
  }

  /// Whether an address is one of this app's to open.
  ///
  /// The web hands over bare paths. A phone hands over whole links, and not
  /// all of them are for the shell.
  static bool isOurs(Uri address) =>
      !address.hasScheme || (address.scheme == 'https' && address.host == host);

  /// The navigator that holds the app says how to open an address.
  ///
  /// A callback rather than a global key, so two shells in a test suite do
  /// not fight over one key and a shell that has gone is not handed a push.
  static void attach(void Function(Uri address) open) => _open = open;

  static void detach(void Function(Uri address) open) {
    if (identical(_open, open)) _open = null;
  }

  /// An address that arrived while nothing could open it: a link tapped
  /// while the sign-in screen was up. The next shell starts there.
  static Uri? get waiting => _waiting;

  /// Where this person came in, once: an address that arrived while
  /// nothing could open it, or else the one the app was started with.
  ///
  /// Once, because joining a room from a link is an action rather than a
  /// place. A shell built again later — signing out and back in — must not
  /// join it a second time.
  static Uri? takeArrival() {
    final waiting = _waiting;
    _waiting = null;
    final taken = _arrivalTaken;
    _arrivalTaken = true;
    if (waiting != null) return waiting;
    if (taken) return null;
    if (kIsWeb) return Uri.base;
    final launch = Uri.tryParse(WidgetsBinding.instance.platformDispatcher.defaultRouteName);
    return launch != null && isOurs(launch) ? launch : null;
  }

  @visibleForTesting
  static void reset() {
    if (_installed case final observer?) WidgetsBinding.instance.removeObserver(observer);
    _installed = null;
    unawaited(_links?.cancel());
    _links = null;
    _open = null;
    _waiting = null;
    _arrivalTaken = false;
  }

  /// An address from outside: opened now if a shell is there to open it,
  /// kept for the next shell if not, and ignored if it is not ours.
  static void arrive(Uri address) {
    if (!isOurs(address)) return;
    final open = _open;
    if (open == null) {
      _waiting = address;
    } else {
      open(address);
    }
  }

  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) async {
    arrive(routeInformation.uri);
    // Handled either way. False would pass the address on to the framework,
    // which is the crash this exists to stop -- and on an iPhone it would
    // send a Universal Link back to Safari.
    return true;
  }
}
