import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/colabroom_theme.dart';
import '../../app/music_beta_controller.dart';
import '../../app/workspace_shell.dart';
import '../../data/supabase_music_repository.dart';
import 'supabase_auth_screen.dart';

class SupabaseAuthGate extends StatefulWidget {
  const SupabaseAuthGate({required this.client, super.key});

  final SupabaseClient client;

  @override
  State<SupabaseAuthGate> createState() => _SupabaseAuthGateState();
}

class _SupabaseAuthGateState extends State<SupabaseAuthGate> {
  StreamSubscription<AuthState>? _authSubscription;
  MusicBetaController? _controller;
  Session? _session;
  bool _loading = true;
  String? _error;
  String? _activatingUserId;
  bool _recoveringPassword = false;

  @override
  void initState() {
    super.initState();
    _session = widget.client.auth.currentSession;
    _authSubscription = widget.client.auth.onAuthStateChange.listen((state) {
      if (state.event == AuthChangeEvent.passwordRecovery && state.session != null) {
        if (mounted) {
          setState(() {
            _session = state.session;
            _recoveringPassword = true;
            _loading = false;
          });
        }
        return;
      }
      _handleSession(state.session);
    });
    _handleSession(_session);
  }

  Future<void> _handleSession(Session? session) async {
    if (session == null) {
      final previousController = _controller;
      if (!mounted) return;
      setState(() {
        _session = null;
        _controller = null;
        _activatingUserId = null;
        _loading = false;
        _error = null;
      });
      _disposeAfterFrame(previousController);
      return;
    }

    if (_session?.user.id == session.user.id && _controller != null) return;
    if (_activatingUserId == session.user.id) return;
    _activatingUserId = session.user.id;
    if (mounted) {
      setState(() {
        _session = session;
        _loading = true;
        _error = null;
      });
    }
    final nextController = MusicBetaController(SupabaseMusicRepository(widget.client));
    await nextController.load();
    if (!mounted || widget.client.auth.currentUser?.id != session.user.id) {
      _activatingUserId = null;
      nextController.dispose();
      return;
    }
    final previousController = _controller;
    setState(() {
      _session = session;
      _controller = nextController;
      _activatingUserId = null;
      _loading = false;
      _error = nextController.error;
    });
    if (!identical(previousController, nextController)) {
      _disposeAfterFrame(previousController);
    }
  }

  void _disposeAfterFrame(MusicBetaController? controller) {
    if (controller == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_recoveringPassword) {
      return SupabasePasswordRecoveryScreen(
        client: widget.client,
        onComplete: () {
          setState(() => _recoveringPassword = false);
          _handleSession(widget.client.auth.currentSession);
        },
      );
    }
    if (_loading) return const _AuthLoading();
    if (_session == null) return SupabaseAuthScreen(client: widget.client);
    if (_error != null || _controller == null) {
      return _AuthFailure(
        message: _error ?? 'The workspace could not be loaded.',
        onRetry: () => _handleSession(widget.client.auth.currentSession),
        onSignOut: () => widget.client.auth.signOut(),
      );
    }
    final user = _session!.user;
    final metadataName = user.userMetadata?['display_name'] as String?;
    final emailName = user.email?.split('@').first;
    return WorkspaceShell(
      controller: _controller!,
      supabase: widget.client,
      displayName: metadataName?.trim().isNotEmpty == true
          ? metadataName!
          : emailName?.trim().isNotEmpty == true
              ? emailName!
              : 'CoLabRoom',
    );
  }
}

class _AuthLoading extends StatelessWidget {
  const _AuthLoading();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CircularProgressIndicator(color: AppColors.cyan),
            SizedBox(height: 16),
            Text('Opening your catalogs…'),
          ],
        ),
      ),
    );
  }
}

class _AuthFailure extends StatelessWidget {
  const _AuthFailure({required this.message, required this.onRetry, required this.onSignOut});

  final String message;
  final VoidCallback onRetry;
  final Future<void> Function() onSignOut;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(Icons.cloud_off_rounded, size: 48, color: AppColors.cyan),
                const SizedBox(height: 16),
                Text('We could not open the workspace.', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(message, textAlign: TextAlign.center),
                const SizedBox(height: 18),
                FilledButton(onPressed: onRetry, child: const Text('Try Again')),
                TextButton(onPressed: onSignOut, child: const Text('Sign Out')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
