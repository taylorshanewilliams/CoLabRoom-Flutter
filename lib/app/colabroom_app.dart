import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../features/auth/supabase_auth_gate.dart';
import 'beta_config.dart';
import 'colabroom_theme.dart';
import 'music_beta_controller.dart';
import 'workspace_shell.dart';
import '../services/browser_history.dart';
import '../services/current_route.dart';

class CoLabRoomApp extends StatefulWidget {
  const CoLabRoomApp.preview({required MusicBetaController controller, this.onWeb, super.key})
      : _controller = controller,
        _supabase = null;

  const CoLabRoomApp.supabase({required SupabaseClient client, this.onWeb, super.key})
      : _controller = null,
        _supabase = client;

  final MusicBetaController? _controller;
  final SupabaseClient? _supabase;

  /// Whether this is the web build. A test passes it; production reads
  /// [kIsWeb].
  final bool? onWeb;

  @override
  State<CoLabRoomApp> createState() => _CoLabRoomAppState();
}

/// The app, and no `builder`.
///
/// **The text is the size the phone says it is.** There used to be a `builder`
/// here clamping the system text scale to 0.8-1.3, so somebody who had set the
/// largest size on their phone — which is the whole of how a partially sighted
/// musician reads anything — got a *smaller* one here than their phone
/// promised. Every Musician, Same Song, 17 September 2026: the phone's own text
/// size is honoured, never clamped, and it is the first thing ADA Title II and
/// WCAG 2.1 AA §1.4.4 ask of anything a school or a university would run.
///
/// The clamp was there to stop fixed heights overflowing. The fix for a fixed
/// height is an intrinsic height, not shrinking the reader's text, and nothing
/// replaces the builder: MaterialApp makes its own MediaQuery from the view, so
/// with none here the scaler is exactly what the platform reports. `test_render`
/// renders the whole app at 2.0 and fails a walk on any overflow, which is what
/// keeps that true.
class _CoLabRoomAppState extends State<CoLabRoomApp> {
  // Made once, not per build: a new delegate would be a new navigator, and
  // everything open on it would close.
  late final Widget _home = widget._supabase == null
      ? WorkspaceShell(controller: widget._controller!)
      : SupabaseAuthGate(client: widget._supabase!);

  // Costs nothing until a route names itself, and then that name reaches
  // every error report without anybody remembering to pass it.
  // RouteTracker names the screen for crash reports. BrowserHistory
  // makes the browser's back button go back a screen instead of leaving
  // the site, which it did because a MaterialApp with imperative pushes
  // registers one history entry for the entire app.
  late final List<NavigatorObserver> _observers = <NavigatorObserver>[RouteTracker(), BrowserHistory()];

  late final RouterConfig<Object> _webRouter = RouterConfig<Object>(
    routeInformationProvider: PlatformRouteInformationProvider(
      initialRouteInformation: RouteInformation(
        uri: Uri.parse(WidgetsBinding.instance.platformDispatcher.defaultRouteName),
      ),
    ),
    routeInformationParser: const _AnyAddress(),
    routerDelegate: _OneHome(home: _home, observers: _observers),
    backButtonDispatcher: RootBackButtonDispatcher(),
  );

  @override
  Widget build(BuildContext context) {
    // The web build runs under a Router, and this is why.
    //
    // 17 September 2026: typing app.colabroom.com, signed in, showed "Opening
    // your rooms…" and then went back to Google, every time. A recorder in
    // the live page found it. MaterialApp's own navigator asks the browser for
    // single-entry history when it starts; BrowserHistory asks for multi-entry;
    // and switching from single to multi steps history back once
    // (`history.go(-1)`) to undo the entry single-entry pushed. Chrome
    // prerenders an address while it is typed, and a prerendered page cannot
    // add history entries -- so the entry was never there, and the step back
    // left the site. It struck when the signed-in shell arrived, because that
    // is when BrowserHistory is made a second time.
    //
    // A Router's navigator never asks for single-entry history, so there is
    // nothing to switch away from and nothing to undo. Addresses themselves
    // are still IncomingAddresses' and DeepLink's; the Router only holds the
    // app.
    if (widget.onWeb ?? kIsWeb) {
      return MaterialApp.router(
        title: BetaConfig.appName,
        debugShowCheckedModeBanner: false,
        theme: CoLabRoomTheme.dark(),
        routerConfig: _webRouter,
      );
    }
    return MaterialApp(
      title: BetaConfig.appName,
      debugShowCheckedModeBanner: false,
      navigatorObservers: _observers,
      theme: CoLabRoomTheme.dark(),
      home: _home,
    );
  }
}

/// Every address is the app. Which screen an address opens is DeepLink's and
/// IncomingAddresses' decision, made inside the shell; the Router's only job
/// here is to be the kind of app that never asks for single-entry history.
class _AnyAddress extends RouteInformationParser<Object> {
  const _AnyAddress();

  @override
  Future<Object> parseRouteInformation(RouteInformation routeInformation) async => routeInformation.uri;
}

/// The app, as the one page of a Router.
class _OneHome extends RouterDelegate<Object> with ChangeNotifier, PopNavigatorRouterDelegateMixin<Object> {
  _OneHome({required this.home, required this.observers});

  final Widget home;
  final List<NavigatorObserver> observers;

  @override
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  // Nothing to report: BrowserHistory tells the browser where somebody is,
  // screen by screen, and a second reporter would fight it.
  @override
  Object? get currentConfiguration => null;

  @override
  Future<void> setNewRoutePath(Object configuration) async {}

  @override
  Widget build(BuildContext context) {
    return Navigator(
      key: navigatorKey,
      observers: observers,
      pages: <Page<void>>[MaterialPage<void>(name: '/', child: home)],
      onDidRemovePage: (_) {},
    );
  }
}
