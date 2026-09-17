import 'browser_entries_stub.dart' if (dart.library.js_interop) 'browser_entries_web.dart' as platform;

/// The browser's own history, where the app has to read it or move it itself.
///
/// Flutter can add and replace history entries but cannot step back through
/// them, and it cannot say what the entry on screen holds. Both are needed to
/// make an in-app Back and the browser's Back the same thing; see
/// [BrowserHistory].
abstract class BrowserEntries {
  /// The depth written on the entry the browser is showing, or null when that
  /// entry is not one this app wrote.
  int? get currentDepth;

  /// Steps the browser through its history, like its own buttons do.
  void go(int delta);

  /// The browser this app is running in. Off the web, one that holds nothing
  /// and moves nowhere.
  static BrowserEntries here() => platform.browserEntries();
}

/// What a history entry this app wrote says about how deep it is.
int? depthOnEntry(Object? state) {
  if (state is Map) {
    final depth = state['depth'];
    if (depth is num) return depth.toInt();
  }
  return null;
}
