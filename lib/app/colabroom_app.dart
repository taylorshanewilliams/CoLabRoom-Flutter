import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../features/auth/supabase_auth_gate.dart';
import 'beta_config.dart';
import 'colabroom_theme.dart';
import 'music_beta_controller.dart';
import 'workspace_shell.dart';

class CoLabRoomApp extends StatelessWidget {
  const CoLabRoomApp.preview({required MusicBetaController controller, super.key})
      : _controller = controller,
        _supabase = null;

  const CoLabRoomApp.supabase({required SupabaseClient client, super.key})
      : _controller = null,
        _supabase = client;

  final MusicBetaController? _controller;
  final SupabaseClient? _supabase;

  @override
  Widget build(BuildContext context) {
    final home = _supabase == null
        ? WorkspaceShell(controller: _controller!)
        : SupabaseAuthGate(client: _supabase);
    return MaterialApp(
      title: BetaConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: CoLabRoomTheme.dark(),
      // Clamp system font scaling so a user's accessibility text-size
      // setting can't blow past what our fixed-width dialogs/tiles were
      // laid out for and trigger a RenderFlex overflow.
      builder: (context, child) {
        final clamped = MediaQuery.textScalerOf(context).clamp(minScaleFactor: 0.8, maxScaleFactor: 1.3);
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: clamped),
          child: child!,
        );
      },
      home: home,
    );
  }
}
