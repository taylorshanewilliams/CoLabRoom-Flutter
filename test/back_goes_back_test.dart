import 'package:colabroom/services/browser_entries.dart';
import 'package:colabroom/services/browser_history.dart';
import 'package:colabroom/services/incoming_addresses.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Back goes back, on the web.
///
/// 17 September 2026, in the audit: Home → Account → Blocked people → the
/// in-app Back → the browser's Back opened Account again, and every Back after
/// that did the same. An in-app Back replaced the top history entry instead of
/// stepping back, so it left a spare one; and the browser's Back arrives as an
/// address, which was opened on top of what was already there.
///
/// These tests run the observer against a small browser: a list of entries,
/// a place in it, and the two ways of moving -- the app's `history.go` and the
/// browser's own Back, which delivers the entry's address the way the engine
/// does.
class _Browser implements BrowserEntries {
  _Browser();

  final List<(String, Object?)> entries = <(String, Object?)>[('/', null)];
  int at = 0;
  int goes = 0;

  @override
  int? get currentDepth => depthOnEntry(entries[at].$2);

  @override
  void go(int delta) {
    goes += 1;
    at += delta;
    _deliver();
  }

  /// The browser's Back button.
  void back() {
    at -= 1;
    _deliver();
  }

  void _deliver() {
    final (uri, state) = entries[at];
    // What the engine does on popstate: hand the address to the framework.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.navigation.name,
      SystemChannels.navigation.codec.encodeMethodCall(
        MethodCall('pushRouteInformation', <String, Object?>{'location': uri, 'state': state}),
      ),
      (_) {},
    );
  }

  Future<Object?> onNavigation(MethodCall call) async {
    if (call.method != 'routeInformationUpdated') return null;
    final args = call.arguments as Map<Object?, Object?>;
    final entry = (args['uri']! as String, args['state']);
    if (args['replace'] == true) {
      entries[at] = entry;
    } else {
      entries.removeRange(at + 1, entries.length);
      entries.add(entry);
      at += 1;
    }
    return null;
  }

  String get here => entries[at].$1;
}

Future<(_Browser, List<Uri>)> _app(WidgetTester tester) async {
  final browser = _Browser();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.navigation, browser.onNavigation);
  addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.navigation, null));

  // Addresses the app was asked to open, which a Back must never be.
  final opened = <Uri>[];
  IncomingAddresses.install();
  IncomingAddresses.attach(opened.add);
  addTearDown(IncomingAddresses.reset);
  addTearDown(BrowserHistory.forget);

  final history = BrowserHistory(onWeb: true, entries: browser);
  Widget page(String name, List<Widget> children) => Scaffold(
        appBar: AppBar(title: Text(name)),
        body: Column(children: children),
      );
  late final Map<String, WidgetBuilder> pages;
  void open(BuildContext context, String name) => Navigator.of(context).push(MaterialPageRoute<void>(
        settings: RouteSettings(name: name),
        builder: pages[name]!,
      ));
  pages = <String, WidgetBuilder>{
    '/account': (context) => page('Account', <Widget>[
          TextButton(onPressed: () => open(context, '/blocked'), child: const Text('Blocked people')),
          TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                content: const Text('A dialog'),
                actions: <Widget>[
                  TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Close')),
                ],
              ),
            ),
            child: const Text('Open a dialog'),
          ),
        ]),
    '/blocked': (context) => page('Blocked', <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).popUntil((route) => route.isFirst),
            child: const Text('All the way home'),
          ),
        ]),
  };
  // The same shape as the app: screens are pushed on a navigator inside the
  // shell, and that navigator carries the observer.
  await tester.pumpWidget(MaterialApp(
    home: Navigator(
      observers: <NavigatorObserver>[history],
      onGenerateRoute: (settings) => MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/'),
        builder: (context) => page('Home', <Widget>[
          TextButton(onPressed: () => open(context, '/account'), child: const Text('Account')),
        ]),
      ),
    ),
  ));
  // Whatever MaterialApp said about its own page is not what is under test.
  browser.entries
    ..clear()
    ..add(('/', null));
  browser.at = 0;
  return (browser, opened);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i += 1) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.tap(find.text(label).last);
  await _settle(tester);
}

/// The app's own Back arrow, at the top of the page on screen.
Future<void> _inAppBack(WidgetTester tester) async {
  await tester.tap(find.byType(BackButton).last);
  await _settle(tester);
}

String _title(WidgetTester tester) =>
    (tester.widget<AppBar>(find.byType(AppBar).last).title! as Text).data!;

void main() {
  testWidgets('what the audit did: in-app Back, then the browser Back, lands home', (tester) async {
    final (browser, opened) = await _app(tester);
    await _tap(tester, 'Account');
    await _tap(tester, 'Blocked people');
    expect(browser.entries.length, 3);

    await _inAppBack(tester);
    expect(_title(tester), 'Account');
    expect(browser.at, 1, reason: 'the in-app Back takes its entry with it');

    browser.back();
    await _settle(tester);

    expect(_title(tester), 'Home', reason: 'it used to open Account again, forever');
    expect(opened, isEmpty, reason: 'a Back is never an address to open');
  });

  testWidgets('the browser Back goes one page back at a time', (tester) async {
    final (browser, opened) = await _app(tester);
    await _tap(tester, 'Account');
    await _tap(tester, 'Blocked people');

    browser.back();
    await _settle(tester);
    expect(_title(tester), 'Account');

    browser.back();
    await _settle(tester);
    expect(_title(tester), 'Home');
    expect(opened, isEmpty);
  });

  testWidgets('going home in one step steps the browser back once, all the way', (tester) async {
    final (browser, _) = await _app(tester);
    await _tap(tester, 'Account');
    await _tap(tester, 'Blocked people');

    await _tap(tester, 'All the way home');

    expect(_title(tester), 'Home');
    expect(browser.at, 0);
    expect(browser.goes, 1, reason: 'two history.go calls in one turn race each other');
  });

  testWidgets('a dialog is not a place', (tester) async {
    final (browser, _) = await _app(tester);
    await _tap(tester, 'Account');
    final before = List<(String, Object?)>.of(browser.entries);

    await _tap(tester, 'Open a dialog');
    await _tap(tester, 'Close');

    expect(browser.entries, before, reason: 'no entry for it, and no address rewritten under it');
    expect(browser.here, '/account');
  });

  testWidgets('an entry the app never wrote is not stepped back from', (tester) async {
    final (browser, _) = await _app(tester);
    await _tap(tester, 'Account');
    // What a prerendered page leaves: the push happened, the entry did not.
    browser.entries
      ..clear()
      ..add(('/', null));
    browser.at = 0;

    await _inAppBack(tester);

    expect(_title(tester), 'Home');
    expect(browser.goes, 0, reason: 'stepping back from here would leave the site');
  });

  testWidgets('pages keep their addresses', (tester) async {
    final (browser, _) = await _app(tester);
    await _tap(tester, 'Account');
    await _tap(tester, 'Blocked people');

    expect(browser.entries.map((entry) => entry.$1), <String>['/', '/account', '/blocked']);
    expect(browser.entries.map((entry) => depthOnEntry(entry.$2)), <int?>[0, 1, 2]);
  });
}
