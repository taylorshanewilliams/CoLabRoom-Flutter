import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

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
  /// nothing. Production never passes it.
  BrowserHistory({bool? onWeb}) : _onWeb = onWeb ?? kIsWeb {
    if (_onWeb) {
      // Without this the engine keeps a single entry and every push
      // overwrites it, which is exactly the behaviour being fixed.
      SystemNavigator.selectMultiEntryHistory();
    }
  }

  final bool _onWeb;

  /// How deep the stack is, so two pushes of the same screen are two entries.
  ///
  /// Browser history is a list of places, not a set: opening a song, going
  /// back, and opening it again is three entries and the middle one is not
  /// the same as the last.
  int _depth = 0;

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

  void _tell(Route<dynamic>? route, {required bool replace}) {
    if (!_onWeb) return;
    SystemNavigator.routeInformationUpdated(
      uri: Uri.parse(_pathFor(route)),
      replace: replace,
    );
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // The very first route is the app opening, not a step within it —
    // adding an entry for it would put an empty page behind the app.
    if (previousRoute == null) return;
    _depth += 1;
    _tell(route, replace: false);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_depth > 0) _depth -= 1;
    // Replace rather than push. A pop is usually the browser's own back
    // button arriving — the engine hands it to the framework as a pop — and
    // adding an entry there would make going back go forward.
    _tell(previousRoute, replace: true);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _tell(newRoute, replace: true);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_depth > 0) _depth -= 1;
    _tell(previousRoute, replace: true);
  }
}
