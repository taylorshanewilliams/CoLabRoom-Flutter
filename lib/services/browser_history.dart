import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'browser_entries.dart';
import 'current_route.dart';

/// The browser's back button, connected to the app's own history.
///
/// A Flutter app built with `MaterialApp` and imperative `Navigator.push`
/// registers **one** browser history entry for the whole application. So the
/// back button — the mouse one, the keyboard one, the one every person on a
/// desk uses without thinking — has nothing to go back to and leaves the
/// site entirely, from the middle of a song.
///
/// That is the single loudest way an app in a browser announces that it is a
/// phone app in a browser. Addressable state is most of what separates the
/// two, and history is the half of it people touch.
///
/// **17 September 2026: back went forward.** The audit found the browser's
/// Back re-opening the screen it had just left, forever. Two halves of one
/// mistake. An in-app Back *replaced* the top entry instead of stepping the
/// browser back, so every in-app Back left a spare entry behind. And with
/// multi-entry history the browser's Back does not arrive as a pop: it
/// arrives as an address (`pushRouteInformation`), which IncomingAddresses
/// answered by opening -- pushing -- the screen at that address. Home →
/// Account → Blocked people → in-app Back → browser Back opened Account
/// again, and every Back after that did the same.
///
/// So each entry now carries how deep it is. An in-app Back steps the browser
/// back when the entry on screen is one this app wrote at that depth -- and
/// only then, so a prerendered page that never got its entries cannot step
/// out of the site (see CoLabRoomApp). A Back or Forward arriving with a
/// depth goes to that depth: shallower pops, the same is nothing to do.
/// Only pages get entries. A dialog, a sheet or a menu is not a place.
///
/// This is the first half, not the whole answer. Real URLs — a link to a
/// song that opens that song, a refresh that keeps your place, a shareable
/// address for a profile — need the Router API and a route table, which is
/// its own piece of work. What this does is make going back mean going back.
///
/// Nothing here runs off the web. On a phone the platform back button
/// already pops the navigator, and asking the engine for multi-entry history
/// on a device would be answering a question nobody asked.
class BrowserHistory extends NavigatorObserver {
  /// [onWeb] exists so this can be tested at all: `flutter test` runs on the
  /// VM, where `kIsWeb` is false and every method here correctly does
  /// nothing. Production never passes it, nor [entries].
  BrowserHistory({bool? onWeb, BrowserEntries? entries})
      : _onWeb = onWeb ?? kIsWeb,
        _entries = entries ?? BrowserEntries.here() {
    if (_onWeb) {
      // Without this the engine keeps a single entry and every push
      // overwrites it, which is exactly the behaviour being fixed.
      SystemNavigator.selectMultiEntryHistory();
    }
  }

  final bool _onWeb;
  final BrowserEntries _entries;

  /// The one watching the navigator the app's screens are pushed on: the
  /// last to see a page arrive. The browser's Back is handed to it.
  static BrowserHistory? _active;

  /// The pages above the first, in order. An entry's depth is its place here
  /// plus one; the first page is depth 0.
  ///
  /// Browser history is a list of places, not a set: opening a song, going
  /// back, and opening it again is three entries and the middle one is not
  /// the same as the last.
  final List<Route<dynamic>> _pages = <Route<dynamic>>[];

  /// Whether the entry the app opened on has been given depth 0 yet.
  bool _openingMarked = false;

  /// Catching up with pops the browser has already made.
  bool _travelling = false;

  /// In-app Backs in this turn of the event loop, stepped back in one go.
  int _stepsBack = 0;

  /// A Forward being followed: the page it opens takes over the entry it
  /// came from rather than adding another after it.
  int? _arrivingAt;

  static bool _isPage(Route<dynamic>? route) => route is PageRoute;

  /// A path for a route, which is a name when a route has one.
  ///
  /// Most of this app's pushes are anonymous — they were written for a phone,
  /// where a route needs no address. Falling back on the tab somebody is
  /// standing in keeps the address honest without pretending to a precision
  /// that is not there yet.
  String _pathFor(Route<dynamic>? route) {
    final named = route?.settings.name;
    // A route named from AppRoutes is already an address; slugifying it
    // would turn /song/abc into -song-abc and lose the only real path in
    // the app.
    if (named != null && named.startsWith('/')) return named;
    final label = named ?? CurrentRoute.name ?? 'view';
    final slug = label
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? '/view' : '/$slug';
  }

  void _tell(Route<dynamic>? route, {required int depth, required bool replace}) {
    SystemNavigator.routeInformationUpdated(
      uri: Uri.parse(_pathFor(route)),
      state: <String, Object?>{'depth': depth},
      replace: replace,
    );
  }

  /// The page under everything this observer has counted.
  Route<dynamic>? _top(Route<dynamic>? fallback) => _pages.isEmpty ? fallback : _pages.last;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (!_onWeb || !_isPage(route)) return;
    _active = this;
    // The very first route is the app opening, not a step within it —
    // adding an entry for it would put an empty page behind the app.
    if (previousRoute == null) return;
    if (!_openingMarked) {
      _openingMarked = true;
      _tell(_top(previousRoute), depth: _pages.length, replace: true);
    }
    _pages.add(route);
    final arriving = _arrivingAt == _pages.length;
    _arrivingAt = null;
    _tell(route, depth: _pages.length, replace: arriving);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (!_onWeb || !_isPage(route)) return;
    final index = _pages.lastIndexOf(route);
    if (index < 0) return;
    final depth = _pages.length;
    _pages.removeAt(index);
    if (_travelling) return;
    // The browser is still showing this page's entry: step it back, so the
    // entry leaves with the page. Several pops in one turn (popUntil) step
    // back together, once.
    if (index == depth - 1 && _entries.currentDepth == depth + _stepsBack) {
      _stepsBack += 1;
      if (_stepsBack == 1) {
        scheduleMicrotask(() {
          final steps = _stepsBack;
          _stepsBack = 0;
          _entries.go(-steps);
        });
      }
      return;
    }
    // Not an entry to step back from -- a page opened before its entry could
    // be written, or history moved some other way. Say where we are instead.
    _tell(_top(previousRoute), depth: _pages.length, replace: true);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (!_onWeb || newRoute == null || !_isPage(newRoute)) return;
    final index = oldRoute == null ? -1 : _pages.lastIndexOf(oldRoute);
    if (index >= 0) _pages[index] = newRoute;
    _tell(newRoute, depth: index >= 0 ? index + 1 : _pages.length, replace: true);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (!_onWeb || !_isPage(route)) return;
    if (!_pages.remove(route) || _travelling) return;
    _tell(_top(previousRoute), depth: _pages.length, replace: true);
  }

  /// The browser's Back or Forward, arriving as an address.
  ///
  /// True when it has been dealt with: the app went back to that depth, or
  /// was already there. False when the entry is not one this app wrote, or
  /// for a Forward, which the address itself opens.
  static bool travel(RouteInformation information) {
    final history = _active;
    final depth = depthOnEntry(information.state);
    if (history == null || !history._onWeb || depth == null) return false;
    return history._travelTo(depth);
  }

  bool _travelTo(int depth) {
    final navigator = this.navigator;
    if (navigator == null) return false;
    if (depth == _pages.length) return true;
    if (depth > _pages.length) {
      _arrivingAt = depth == _pages.length + 1 ? depth : null;
      return false;
    }
    final target = depth == 0 ? null : _pages[depth - 1];
    _travelling = true;
    try {
      navigator.popUntil((route) => route.isFirst || identical(route, target));
    } finally {
      _travelling = false;
    }
    return true;
  }

  @visibleForTesting
  static void forget() => _active = null;
}
