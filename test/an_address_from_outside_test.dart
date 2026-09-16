import 'package:colabroom/app/deep_link.dart';
import 'package:colabroom/services/incoming_addresses.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The web build died four times in one week on the browser's forward
/// button: the framework answered a pushed address by calling `pushNamed`
/// on a navigator with no routes. This observer answers first -- and since
/// 16 September 2026 it does the same on a phone, where a link opening the
/// app arrives as exactly that push.
void main() {
  setUp(IncomingAddresses.reset);
  tearDown(IncomingAddresses.reset);

  test('a pushed address reaches whoever is attached, and is always handled',
      () async {
    final observer = IncomingAddresses();
    final opened = <String>[];
    void open(Uri address) => opened.add(address.path);
    IncomingAddresses.attach(open);
    addTearDown(() => IncomingAddresses.detach(open));

    final handled = await observer.didPushRouteInformation(
      RouteInformation(uri: Uri.parse('/song/abc')),
    );

    expect(handled, isTrue);
    expect(opened, <String>['/song/abc']);
  });

  test('with nobody attached the address is kept rather than passed on',
      () async {
    final observer = IncomingAddresses();
    // True is the whole fix: false hands the address to the framework, and
    // the framework throws.
    expect(
      await observer.didPushRouteInformation(
        RouteInformation(uri: Uri.parse('/nothing/here')),
      ),
      isTrue,
    );
    expect(IncomingAddresses.waiting, Uri.parse('/nothing/here'));
  });

  test('detaching somebody else leaves the attached handler alone', () async {
    final observer = IncomingAddresses();
    final opened = <String>[];
    void mine(Uri address) => opened.add(address.path);
    void theirs(Uri address) {}
    IncomingAddresses.attach(mine);
    addTearDown(() => IncomingAddresses.detach(mine));

    IncomingAddresses.detach(theirs);
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
