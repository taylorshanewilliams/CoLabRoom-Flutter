import 'package:flutter/widgets.dart';

/// Where the person is, so a failure can say so.
///
/// Every error this app has reported arrived without a screen attached, and
/// the triage agent's diagnoses say so repeatedly: the ancestor chain is
/// "truncated exactly where it would have told us the screen", and issue #19
/// gives up with "I cannot tell you which widget it is from this report". The
/// screen is the most useful single fact a report can carry, and it was the
/// one thing missing.
///
/// **What this does and does not know.** Thirty-four of this app's thirty-five
/// route pushes are a bare `MaterialPageRoute` with no settings, so a
/// navigator observer alone would record almost nothing — and rewriting all
/// thirty-four by hand is exactly the kind of change that goes subtly wrong in
/// a file nobody reads again. So this tracks two cheaper things that are true:
/// the destination the shell is showing, which covers the whole app at the
/// level of "which quarter of it", and any route that does name itself. Call
/// sites that know better pass their own string to the reporter and win over
/// both.
///
/// Deliberately a plain global. It is written by the shell and read by the
/// error reporter, the two places in this app furthest apart; threading a
/// string between them through every widget in between would be a great deal
/// of ceremony for something nothing else wants.
abstract final class CurrentRoute {
  static String? _destination;
  static final List<String> _named = <String>[];

  /// The best available answer to "where were they", or null.
  ///
  /// Null is honest and will appear in real reports: a crash during start-up,
  /// a failed sign-in before the first screen exists, an upload finishing
  /// after the last screen was popped.
  static String? get name => _named.isNotEmpty ? _named.last : _destination;

  /// The shell's current destination — Home, Songs, Studio, Control Room.
  static void enter(String destination) => _destination = destination;

  static void push(String? routeName) {
    if (routeName == null || routeName.isEmpty) return;
    _named.add(routeName);
  }

  static void pop(String? routeName) {
    if (routeName == null || routeName.isEmpty) return;
    final index = _named.lastIndexOf(routeName);
    if (index >= 0) _named.removeAt(index);
  }

  @visibleForTesting
  static void reset() {
    _destination = null;
    _named.clear();
  }
}

/// Keeps [CurrentRoute] in step with any route that names itself.
///
/// Installed on the navigator rather than called from each screen, so that a
/// screen added later gets this for free the moment somebody gives its route
/// a name — and costs nothing until they do.
class RouteTracker extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    CurrentRoute.push(route.settings.name);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    CurrentRoute.pop(route.settings.name);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    CurrentRoute.pop(route.settings.name);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    CurrentRoute.pop(oldRoute?.settings.name);
    CurrentRoute.push(newRoute?.settings.name);
  }
}
