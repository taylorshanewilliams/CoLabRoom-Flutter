import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../services/push_registration.dart';
import '../../services/test_when_closed.dart';
import '../../widgets/problem_report.dart';
import '../../widgets/app_surface.dart';

/// Whether this phone is on the list at all.
///
/// Separate from the switches below it, which decide what is worth being told
/// about. This one decides whether being told can reach you when the app is
/// closed — and unlike the others it cannot simply be turned back on from
/// here once it has been refused, because on iOS the system prompt is spent
/// after one answer. When that has happened the honest thing is to say so and
/// point at Settings rather than draw a switch that silently does nothing.
class _PhoneNotificationsTile extends StatefulWidget {
  const _PhoneNotificationsTile();

  @override
  State<_PhoneNotificationsTile> createState() =>
      _PhoneNotificationsTileState();
}

class _PhoneNotificationsTileState extends State<_PhoneNotificationsTile> {
  bool? _allowed;

  /// Whether the server has a token for this account.
  ///
  /// The thing the old subtitle claimed and never checked. The OS permission
  /// and a registered token are two different facts, and only the second one
  /// decides whether a notification can arrive.
  bool? _reachable;
  bool _busy = false;
  bool _testing = false;
  bool _armed = TestWhenClosed.instance.isArmed;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  Future<void> _check() async {
    final allowed = await PushRegistration.isAllowed();
    final reachable = allowed ? await PushRegistration.reachesThisAccount() : false;
    if (mounted) {
      setState(() {
        _allowed = allowed;
        _reachable = reachable;
      });
    }
  }

  Future<void> _turnOn() async {
    setState(() => _busy = true);
    final allowed = await PushRegistration.enable();
    final reachable = allowed ? await PushRegistration.reachesThisAccount() : false;
    if (!mounted) return;
    setState(() {
      _allowed = allowed;
      _reachable = reachable;
      _busy = false;
    });
    if (allowed) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text(
        'Your phone is set to refuse notifications from CoLabRoom. Turn them '
        'on in your phone settings and come back.',
      ),
    ));
  }

  Future<void> _sendTest() async {
    setState(() => _testing = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final sent = await PushRegistration.sendTestNotification();
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text(sent
            ? 'Sent. Close the app and it should arrive in a moment.'
            : 'This phone is not registered, so nothing was sent.'),
      ));
    } catch (error) {
      if (!mounted) return;
      showProblem(context, error,
          service: 'app', stage: 'push.test', route: 'Notifications');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // A build with no Firebase configured has nothing to offer here, and a
    // switch that cannot do anything is worse than no switch.
    if (!PushRegistration.isAvailable) return const SizedBox.shrink();
    final allowed = _allowed;
    final reachable = _reachable;
    return AppSurface(
      padding: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SwitchListTile(
            title: const Text('On this phone'),
            // Three states, not two, because there are three.
            //
            // The old subtitle read the OS permission and then made a claim
            // about this app: allowed meant "notifications reach you when the
            // app is closed". Those are different facts. On 2026-09-10 the
            // second was false for every account in production while the
            // first could be perfectly true - the permission is granted, the
            // token never registers, and the screen says everything is fine.
            //
            // The middle state is the one worth having. It is what iOS does
            // when the Firebase project has no APNs key, and it looked
            // exactly like success.
            subtitle: Text(
              allowed != true
                  ? 'Notifications only appear when you open the app.'
                  : reachable == true
                      ? 'Notifications reach you when the app is closed.'
                      : 'Allowed on this phone, but not registered yet, so '
                          'nothing can arrive while the app is closed.',
            ),
            value: allowed ?? false,
            // Turning it off is the phone's own setting, not ours to fake.
            // Sending somebody to Settings is honest; a switch that appears
            // to turn it off while the system still allows it is not.
            onChanged: _busy || allowed == true
                ? null
                : (_) => unawaited(_turnOn()),
          ),
          // Only once there is something to test. A button that can only
          // report failure is a way of telling somebody their app is broken.
          if (reachable == true) ...<Widget>[
            ListTile(
              dense: true,
              title: const Text('Send this phone a test notification'),
              subtitle: const Text(
                'Goes down the real path, so if it arrives, they all will.',
              ),
              trailing: _testing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send_rounded, size: 18),
              onTap: _testing ? null : () => unawaited(_sendTest()),
            ),
            // The half the instant test cannot reach.
            //
            // Android draws a pushed notification itself only while the app
            // is in the background; with the app open it hands it to the app,
            // which is a different mechanism entirely. A notification that
            // arrives in under a second arrives before anybody can press the
            // home button, so this one waits for the app to be closed and
            // sends itself on the way out.
            ListTile(
              key: const Key('test_when_closed'),
              dense: true,
              title: Text(_armed
                  ? 'Now close the app'
                  : 'Test it with the app closed'),
              subtitle: Text(_armed
                  ? 'It will send itself as you leave, and should arrive a '
                      'moment later.'
                  : 'Arms one. Press it, then close the app.'),
              trailing: Icon(
                _armed ? Icons.hourglass_top_rounded : Icons.schedule_rounded,
                size: 18,
                color: _armed ? AppColors.gold : null,
              ),
              onTap: () => setState(() {
                if (_armed) {
                  TestWhenClosed.instance.disarm();
                  _armed = false;
                } else {
                  TestWhenClosed.instance.arm();
                  _armed = true;
                }
              }),
            ),
          ],
        ],
      ),
    );
  }
}

class NotificationSettingsScreen extends StatelessWidget {
  const NotificationSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = BetaScope.of(context);
    final preferences = controller.notificationPreferences;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Notifications'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
          children: <Widget>[
            // Above the per-type switches, because it governs all of them.
            //
            // The app offers this at the moment it is earned — right after
            // somebody asks their room for something — but that moment only
            // ever arrives for the person doing the asking, and the people
            // who most need to hear about an ask are the ones who did not
            // make it. So there has to be a door that is always open.
            const _PhoneNotificationsTile(),
            const SizedBox(height: 14),
            AppSurface(
              padding: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  SwitchListTile(
                    title: const Text('Invites'),
                    subtitle: const Text('When someone invites you to a room or a song'),
                    value: preferences.invites,
                    onChanged: (value) => controller.updateNotificationPreferences(
                      preferences.copyWith(invites: value),
                    ),
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    title: const Text('Invite responses'),
                    subtitle: const Text('When someone accepts or declines your invite'),
                    value: preferences.inviteResponses,
                    onChanged: (value) => controller.updateNotificationPreferences(
                      preferences.copyWith(inviteResponses: value),
                    ),
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    title: const Text('Being asked'),
                    subtitle: const Text(
                        'When somebody asks you to play on their song. An ask '
                        'made of you still waits in your inbox — this is '
                        'about being told the moment it arrives.'),
                    value: preferences.asks,
                    onChanged: (value) => controller.updateNotificationPreferences(
                      preferences.copyWith(asks: value),
                    ),
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    title: const Text('New takes'),
                    subtitle: const Text(
                        "When somebody records a part on a song you're in. "
                        'Writing shows up on Home instead of here.'),
                    value: preferences.projectUpdates,
                    onChanged: (value) => controller.updateNotificationPreferences(
                      preferences.copyWith(projectUpdates: value),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
