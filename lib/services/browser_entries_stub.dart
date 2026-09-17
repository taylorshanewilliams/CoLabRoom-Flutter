import 'browser_entries.dart';

BrowserEntries browserEntries() => const _Nowhere();

class _Nowhere implements BrowserEntries {
  const _Nowhere();

  @override
  int? get currentDepth => null;

  @override
  void go(int delta) {}
}
