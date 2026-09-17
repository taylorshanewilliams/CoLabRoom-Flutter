import 'package:colabroom/main.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

/// The web app, readable from the first frame.
///
/// Flutter's web build collects no semantics until something asks for them,
/// and what asks for them by default is an invisible "Enable accessibility"
/// button nobody has ever found. Every Musician, Same Song, 17 September
/// 2026: schools and universities have to meet WCAG 2.1 AA, so the app asks
/// for itself. See `enableWebSemantics`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('on the web it holds the tree open', () {
    final before = SemanticsBinding.instance.debugOutstandingSemanticsHandles;

    final handle = enableWebSemantics(onWeb: true);
    expect(handle, isNotNull);
    expect(
      SemanticsBinding.instance.debugOutstandingSemanticsHandles,
      before + 1,
    );
    expect(SemanticsBinding.instance.semanticsEnabled, isTrue);

    // The app never does this — the handle is held for the life of the tab —
    // but a test that leaves one outstanding fails the next one.
    handle!.dispose();
  });

  test('everywhere else it asks for nothing', () {
    // iOS and Android turn semantics on themselves the moment a screen
    // reader is running, and paying for the tree on a phone that has none is
    // the cost this call is careful about.
    final before = SemanticsBinding.instance.debugOutstandingSemanticsHandles;
    expect(enableWebSemantics(onWeb: false), isNull);
    expect(
      SemanticsBinding.instance.debugOutstandingSemanticsHandles,
      before,
    );
  });
}
