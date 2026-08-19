import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../features/shell/app_shell.dart';
import 'beta_scope.dart';
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
  Widget build(BuildContext context) {
    return BetaScope(
      controller: widget.controller,
      child: NavigatorPopHandler<void>(
        onPopWithResult: (_) {
          _navigatorKey.currentState?.maybePop();
        },
        child: Navigator(
          key: _navigatorKey,
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
