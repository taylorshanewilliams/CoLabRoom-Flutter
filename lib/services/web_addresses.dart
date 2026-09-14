import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

/// The browser's forward button, and any address that arrives while the app
/// is already open.
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
/// Nothing here runs off the web. On a phone nothing pushes route
/// information into a running app, and the observer is never installed.
class WebAddresses with WidgetsBindingObserver {
  /// Public so a test can drive one directly. Production has exactly one,
  /// made by [install].
  WebAddresses();

  static WebAddresses? _installed;
  static void Function(String path)? _open;

  /// Registers the one instance, once, and only on the web.
  ///
  /// Must run before `runApp`: the binding dispatches to observers in the
  /// order they were added and stops at the first that says it handled the
  /// push. `WidgetsApp` adds itself when it mounts, so anything added before
  /// `runApp` is asked before it.
  static void install({bool? onWeb}) {
    if (!(onWeb ?? kIsWeb) || _installed != null) return;
    final observer = WebAddresses();
    _installed = observer;
    WidgetsBinding.instance.addObserver(observer);
  }

  /// The navigator that holds the app says how to open an address.
  ///
  /// A callback rather than a global key, so two shells in a test suite do
  /// not fight over one key and a shell that has gone is not handed a push.
  static void attach(void Function(String path) open) => _open = open;

  static void detach(void Function(String path) open) {
    if (identical(_open, open)) _open = null;
  }

  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) async {
    _open?.call(routeInformation.uri.path);
    // Handled either way. False would pass the address on to the framework,
    // which is the crash this exists to stop.
    return true;
  }
}
