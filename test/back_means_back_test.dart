import 'package:colabroom/services/browser_history.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The browser back button, connected to the app's own history.
///
/// A `MaterialApp` driven by imperative `Navigator.push` registers one
/// browser history entry for the whole application, so back has nothing to
/// go back to and leaves the site — from the middle of a song. It is the
/// loudest way an app in a browser says it is a phone app in a browser.
///
/// These tests drive the observer directly and watch the platform channel,
/// because the behaviour under test *is* the message sent to the engine.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<MethodCall> sent;

  setUp(() {
    sent = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.navigation, (call) async {
      sent.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.navigation, null);
  });

  MethodCall? lastUpdate() {
    for (final call in sent.reversed) {
      if (call.method == 'routeInformationUpdated') return call;
    }
    return null;
  }

  test('the first route is the app opening, not a step within it', () {
    final history = BrowserHistory(onWeb: true);
    // previousRoute null means this is the app appearing. An entry here puts
    // a blank page behind the app, so back would land on nothing.
    history.didPush(
      MaterialPageRoute<void>(builder: (_) => const SizedBox()),
      null,
    );

    expect(lastUpdate(), isNull);
  });

  test('a push adds an entry, so back has somewhere to go', () {
    final history = BrowserHistory(onWeb: true);
    final first = MaterialPageRoute<void>(builder: (_) => const SizedBox());
    final second = MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'Song sheet'),
      builder: (_) => const SizedBox(),
    );

    history.didPush(first, null);
    history.didPush(second, first);

    final update = lastUpdate();
    expect(update, isNotNull);
    expect(update!.arguments['replace'], isFalse,
        reason: 'a new screen is a new place, and replacing would leave back '
            'with nothing to pop');
    expect(update.arguments['uri'], '/song-sheet',
        reason: 'a route that names itself should say so in the address');
  });

  test('a pop replaces rather than pushes', () {
    final history = BrowserHistory(onWeb: true);
    final first = MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'Your music'),
      builder: (_) => const SizedBox(),
    );
    final second = MaterialPageRoute<void>(builder: (_) => const SizedBox());

    history.didPush(first, null);
    history.didPush(second, first);
    sent.clear();
    history.didPop(second, first);

    final update = lastUpdate();
    expect(update, isNotNull);
    expect(update!.arguments['replace'], isTrue,
        reason: 'a pop is usually the back button arriving. Adding an entry '
            'there would make going back go forward');
    expect(update.arguments['uri'], '/your-music');
  });
}
