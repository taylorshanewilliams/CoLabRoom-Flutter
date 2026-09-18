import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/colabroom_theme.dart';
import '../../app/music_beta_controller.dart';
import '../../app/workspace_shell.dart';
import '../../data/supabase_music_repository.dart';
import '../../services/song_analysis_service.dart';
import '../songs/kept_here.dart';
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

  /// True while the spinner is up because somebody pressed Try Again on the
  /// screen that lists the kept songs, so the list does not blink away under
  /// their thumb and come back three seconds later.
  bool _tryingAgain = false;

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

  /// Try Again, on the screen that says the workspace could not be opened.
  ///
  /// It used to hand the session back to [_handleSession], which returns at
  /// once when this account already has a controller -- and after a load
  /// that failed it does, so the button did nothing at all and the only way
  /// out of that screen was to close the app. Nobody had a reason to be on
  /// that screen for long before; somebody who opened the app in a basement
  /// and then walked upstairs does (Every Musician, Same Song, 17 September
  /// 2026). The library is asked for again, through the controller that is
  /// already here.
  Future<void> _tryAgain() async {
    final controller = _controller;
    if (controller == null) return _handleSession(widget.client.auth.currentSession);
    setState(() {
      _loading = true;
      _tryingAgain = true;
      _error = null;
    });
    await controller.load();
    if (!mounted || !identical(controller, _controller)) return;
    setState(() {
      _loading = false;
      _tryingAgain = false;
      _error = controller.error;
    });
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
    if (_loading) {
      return OpeningYourRooms(signedIn: _session != null, keptAtOnce: _tryingAgain);
    }
    if (_session == null) return SupabaseAuthScreen(client: widget.client);
    if (_error != null || _controller == null) {
      return _AuthFailure(
        message: _error ?? 'The workspace could not be loaded.',
        onRetry: _tryAgain,
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

/// What the gate shows while the library loads: a spinner, and after a few
/// seconds the songs kept on this phone.
///
/// No signal fails quickly, and lands on the screen below with the kept
/// songs on it. One bar in a basement does not fail: the library request
/// hangs until the phone gives up on it, which is tried three times, so a
/// singer could look at this spinner for minutes with the whole set sitting
/// on the phone and no way to reach it -- the exact case a song is kept for
/// (review, 18 September 2026). So the server is given the same few seconds
/// here that Perform's own door gives it, and then the kept songs are
/// offered underneath while the library goes on trying. Nothing is drawn
/// when nothing is kept, and on a start with signal the library arrives
/// first and nobody ever sees the list.
///
/// Public only so that a test can reach it; the gate itself needs a server.
@visibleForTesting
class OpeningYourRooms extends StatefulWidget {
  const OpeningYourRooms({
    this.signedIn = false,
    this.keptAtOnce = false,
    this.analysisService,
    super.key,
  });

  /// Kept songs belong to an account, so there are none to offer before
  /// somebody is signed in.
  final bool signedIn;

  /// True after Try Again, when the list was on screen a moment ago and
  /// should not blink away.
  final bool keptAtOnce;

  /// Handed on to [KeptHere]. Null in production.
  final SongAnalysisService? analysisService;

  @override
  State<OpeningYourRooms> createState() => _OpeningYourRoomsState();
}

class _OpeningYourRoomsState extends State<OpeningYourRooms> {
  Timer? _timer;
  late bool _offerKept = widget.keptAtOnce;

  @override
  void initState() {
    super.initState();
    if (!_offerKept) {
      _timer = Timer(SongAnalysisService.keptAnswersAfter, () {
        if (mounted) setState(() => _offerKept = true);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const CircularProgressIndicator(color: AppColors.cyan),
                    const SizedBox(height: 16),
                    const Text('Opening your rooms…'),
                    if (widget.signedIn && _offerKept) ...<Widget>[
                      const SizedBox(height: 28),
                      KeptHere(analysisService: widget.analysisService),
                    ],
                  ],
                ),
              ),
            ),
          ),
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
      body: SafeArea(
        child: Center(
          // Scrolls, because a set kept for a gig is a dozen rows under
          // what used to be the whole of this screen.
          child: SingleChildScrollView(
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
                    // Where a phone with no signal lands, so where the songs
                    // kept for having no signal have to be. Nothing at all
                    // when nothing is kept (Every Musician, Same Song,
                    // 17 September 2026).
                    const SizedBox(height: 18),
                    const KeptHere(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
