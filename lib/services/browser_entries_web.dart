import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'browser_entries.dart';

@JS('history')
external JSObject get _history;

BrowserEntries browserEntries() => const _ThisBrowser();

class _ThisBrowser implements BrowserEntries {
  const _ThisBrowser();

  // The engine wraps what the app writes: {serialCount, state: <ours>}.
  @override
  int? get currentDepth {
    final state = _history.getProperty<JSAny?>('state'.toJS).dartify();
    return state is Map ? depthOnEntry(state['state']) : null;
  }

  @override
  void go(int delta) {
    _history.callMethod<JSAny?>('go'.toJS, delta.toJS);
  }
}
