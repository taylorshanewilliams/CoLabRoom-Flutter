import 'package:colabroom/app/deep_link.dart';
import 'package:colabroom/services/web_addresses.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The web build died four times in one week on the browser's forward
/// button: the framework answered a pushed address by calling `pushNamed`
/// on a navigator with no routes. This observer answers first.
void main() {
  test('a pushed address reaches whoever is attached, and is always handled',
      () async {
    final observer = WebAddresses();
    final opened = <String>[];
    void open(String path) => opened.add(path);
    WebAddresses.attach(open);
    addTearDown(() => WebAddresses.detach(open));

    final handled = await observer.didPushRouteInformation(
      RouteInformation(uri: Uri.parse('/song/abc')),
    );

    expect(handled, isTrue);
    expect(opened, <String>['/song/abc']);
  });

  test('with nobody attached the address is swallowed rather than passed on',
      () async {
    final observer = WebAddresses();
    // True is the whole fix: false hands the address to the framework, and
    // the framework throws.
    expect(
      await observer.didPushRouteInformation(
        RouteInformation(uri: Uri.parse('/nothing/here')),
      ),
      isTrue,
    );
  });

  test('detaching somebody else leaves the attached handler alone', () async {
    final observer = WebAddresses();
    final opened = <String>[];
    void mine(String path) => opened.add(path);
    void theirs(String path) {}
    WebAddresses.attach(mine);
    addTearDown(() => WebAddresses.detach(mine));

    WebAddresses.detach(theirs);
    await observer.didPushRouteInformation(
      RouteInformation(uri: Uri.parse('/musician/m1')),
    );
    expect(opened, <String>['/musician/m1']);
  });

  test('the two tabs are a return, not a screen', () {
    expect(DeepLink.isATab('/'), isTrue);
    expect(DeepLink.isATab('/openmic'), isTrue);
    expect(DeepLink.isATab('/song/abc'), isFalse);
    expect(DeepLink.isATab('/musician/m1'), isFalse);
    expect(DeepLink.isATab('/not/a/place'), isFalse);
  });
}
