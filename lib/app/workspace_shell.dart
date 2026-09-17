import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../features/shell/app_shell.dart';
import '../services/browser_history.dart';
import '../services/current_route.dart';
import 'beta_scope.dart';
import 'deep_link.dart';
import '../features/shell/join_from_address.dart';
import '../services/incoming_addresses.dart';
import 'music_beta_controller.dart';

/// Keeps every workspace route and dialog below [BetaScope].
///
/// Placing the scope directly around [AppShell] left routes pushed by the
/// MaterialApp navigator outside the scope. A nested navigator gives Rooms,
/// projects, dialogs, and the songwriting workspace one stable inherited-state
/// boundary for their entire lifetime.
class WorkspaceShell extends StatefulWidget {
  const WorkspaceShell({
    required this.controller,
    this.displayName = 'CoLabRoom',
    this.supabase,
    super.key,
  });

  final MusicBetaController controller;
  final String displayName;
  final SupabaseClient? supabase;

  @override
  State<WorkspaceShell> createState() => _WorkspaceShellState();
}

class _WorkspaceShellState extends State<WorkspaceShell> {
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    // The browser's forward button, and a link or QR code opening the app
    // while it is already running, land here rather than on the navigator
    // MaterialApp built, which has no routes and used to throw. See
    // IncomingAddresses.
    IncomingAddresses.attach(_openAddress);
  }

  @override
  void dispose() {
    IncomingAddresses.detach(_openAddress);
    super.dispose();
  }

  /// An address arriving while the app is open, made into the screen it
  /// names — or, for a tab, a return to the bottom of the stack, or, for an
  /// invitation or a lesson link, the room it opens.
  void _openAddress(Uri address) {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) {
      // An iPhone's launch link can arrive between this shell attaching and
      // its navigator being built. One frame later it is there.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _navigatorKey.currentState != null) _openAddress(address);
      });
      return;
    }
    if (opensARoom(address)) {
      unawaited(joinFromAddress(address, context: navigator.context, navigator: navigator));
      return;
    }
    final path = address.path;
    if (DeepLink.isATab(path)) {
      navigator.popUntil((route) => route.isFirst);
      return;
    }
    final route = DeepLink.routeFor(
      path,
      repository: widget.controller.repository,
      supabase: widget.supabase,
    );
    if (route != null) navigator.push(route);
  }

  @override
  Widget build(BuildContext context) {
    return BetaScope(
      controller: widget.controller,
      child: NavigatorPopHandler<void>(
        onPopWithResult: (_) {
          _navigatorKey.currentState?.maybePop();
        },
        child: Navigator(
          key: _navigatorKey,
          // The address the app was opened at, turned into a stack.
          //
          // Flutter hands the incoming route here and lets a Navigator build
          // more than one page from it, which is exactly what a deep link
          // wants: the shell underneath, the linked screen on top. A link
          // that replaced the app would leave somebody on a song with
          // nowhere to go back to.
          initialRoute: DeepLink.initialRoute(WidgetsBinding.instance),
          onGenerateInitialRoutes: (state, initialRoute) => DeepLink.stackFor(
            path: initialRoute,
            shell: (tab) => AppShell(
              displayName: widget.displayName,
              supabase: widget.supabase,
              initialTab: tab,
            ),
            repository: widget.controller.repository,
            supabase: widget.supabase,
          ),
          // The observers belong here, not only on the MaterialApp.
          //
          // MaterialApp.navigatorObservers watches the navigator MaterialApp
          // builds. This is a different one — every push inside the app goes
          // to it — so a history observer up there sees none of them, and
          // the browser back button stays broken while looking fixed.
          observers: <NavigatorObserver>[RouteTracker(), BrowserHistory()],
          onGenerateRoute: (settings) => MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => AppShell(
              displayName: widget.displayName,
              supabase: widget.supabase,
            ),
          ),
        ),
      ),
    );
  }
}
