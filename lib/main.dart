import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/beta_config.dart';
import 'app/colabroom_app.dart';
import 'app/colabroom_theme.dart';
import 'app/music_beta_controller.dart';
import 'data/in_memory_music_repository.dart';
import 'services/app_session.dart';
import 'services/crash_reporter.dart';
import 'services/notification_shade.dart';
import 'services/push_registration.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Before anything else that can fail. A build error reaches
  // FlutterError.onError, so the crash screen below is what the user sees
  // while this is what makes it countable.
  CrashReporter.install();
  ErrorWidget.builder = (details) => _CrashScreen(details: details);

  if (BetaConfig.hasSupabase) {
    await Supabase.initialize(
      url: BetaConfig.supabaseUrl,
      publishableKey: BetaConfig.supabaseAnonKey,
    );
    // Brings Firebase up so a device that has already been allowed can
    // re-register its token. It does not ask anybody for anything: the
    // permission dialog is spent later, at a moment that has earned it. See
    // PushRegistration.enable.
    await PushRegistration.start();
    unawaited(PushRegistration.refreshIfAllowed());
    // Creates the channel, and draws anything that arrives while the app is
    // open -- which Android does not do for you, and which is why pressing
    // the test button and watching the screen produced nothing at all.
    unawaited(NotificationShade.start());
    // The denominator for every error rate. Unawaited: a session that cannot
    // be recorded costs one missing count, and an app that will not open
    // because its analytics failed costs a user.
    unawaited(AppSession.start());
    runApp(CoLabRoomApp.supabase(client: Supabase.instance.client));
  } else {
    final controller = MusicBetaController(InMemoryMusicRepository.seeded());
    await controller.load();
    runApp(CoLabRoomApp.preview(controller: controller));
  }
}

/// Replaces any widget that throws while building. Keeps the friendly
/// message as the default view — the "Show technical details" toggle is
/// there so a bug report can actually include the real exception/stack
/// trace instead of just this screen, which used to be the only thing a
/// crash ever showed.
class _CrashScreen extends StatefulWidget {
  const _CrashScreen({required this.details});

  final FlutterErrorDetails details;

  @override
  State<_CrashScreen> createState() => _CrashScreenState();
}

class _CrashScreenState extends State<_CrashScreen> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.ink,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.sync_problem_rounded, color: AppColors.cyan, size: 42),
                  const SizedBox(height: 14),
                  const Text(
                    'CoLabRoom hit a problem.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.text,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 7),
                  const Text(
                    'Close and reopen the app. Your saved rooms are still secure.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.muted, height: 1.4),
                  ),
                  const SizedBox(height: 18),
                  TextButton(
                    onPressed: () => setState(() => _expanded = !_expanded),
                    child: Text(_expanded ? 'Hide technical details' : 'Show technical details'),
                  ),
                  if (_expanded) ...<Widget>[
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.line),
                      ),
                      child: SelectableText(
                        '${widget.details.exceptionAsString()}\n\n${widget.details.stack}',
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
