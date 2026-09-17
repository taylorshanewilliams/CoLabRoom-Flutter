import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/beta_config.dart';
import 'app/colabroom_app.dart';
import 'app/colabroom_theme.dart';
import 'app/music_beta_controller.dart';
import 'data/in_memory_music_repository.dart';
import 'services/app_session.dart';
import 'services/crash_reporter.dart';
import 'services/notification_shade.dart';
import 'services/push_receipts.dart';
import 'services/push_registration.dart';
import 'services/set_aside.dart';
import 'services/incoming_addresses.dart';

/// Turns the semantics tree on before the first frame, on the web only.
///
/// Flutter's web build collects nothing for a screen reader until something
/// asks it to: "For performance reasons, Flutter's web accessibility is not
/// on by default. To turn on accessibility, the user needs to press an
/// invisible button with `aria-label=\"Enable accessibility\"`." — Flutter,
/// *Web accessibility*, docs.flutter.dev/ui/accessibility/web-accessibility
/// (Flutter 3.47). That button is the whole story on the desk: nobody has
/// ever found it, so the signed-in web app has been a blank rectangle to
/// VoiceOver and to NVDA since the day it shipped. The same page gives this
/// call as the alternative, and it is the one the app makes.
///
/// The cost is the reason it is not the default, and it is real: with a
/// handle outstanding the framework builds the semantics tree every frame and
/// the engine mirrors it into the DOM, on every device that opens the site
/// rather than only the ones that need it. It is the right trade here —
/// schools and universities have to meet WCAG 2.1 AA, and an app whose
/// accessibility depends on somebody finding a hidden button does not. Every
/// Musician, Same Song, 17 September 2026.
///
/// The handle is never disposed: disposing it turns semantics back off, and
/// the whole point is that it stays on for the life of the tab. Returns null
/// everywhere but the web, where the platform asks for semantics itself the
/// moment a screen reader is running.
///
/// [onWeb] exists so the web branch can be tested at all — every test in this
/// repo runs on the VM, where `kIsWeb` is false and the interesting half of
/// this function is unreachable.
SemanticsHandle? enableWebSemantics({bool onWeb = kIsWeb}) {
  if (!onWeb) return null;
  return SemanticsBinding.instance.ensureSemantics();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Before runApp, so the first frame the browser paints is already one a
  // screen reader can read. See enableWebSemantics.
  enableWebSemantics();
  // Before anything else that can fail. A build error reaches
  // FlutterError.onError, so the crash screen below is what the user sees
  // while this is what makes it countable.
  CrashReporter.install();
  ErrorWidget.builder = (details) => _CrashScreen(details: details);
  // Before runApp, so it is asked about a pushed address before the
  // framework is: the browser's forward button, or a link opening the app.
  IncomingAddresses.install();

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
    // The phone reporting back which pushes reached it, and where a
    // tapped one takes you. See PushReceipts.
    unawaited(PushReceipts.start(available: PushRegistration.isAvailable));
    // What somebody has already said no to, read once before the first
    // screen draws, so a dismissed card does not flash back up on launch.
    await SetAside.load();
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
