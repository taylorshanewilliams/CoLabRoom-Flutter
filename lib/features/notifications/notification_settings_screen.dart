import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../services/push_registration.dart';
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
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  Future<void> _check() async {
    final allowed = await PushRegistration.isAllowed();
    if (mounted) setState(() => _allowed = allowed);
  }

  Future<void> _turnOn() async {
    setState(() => _busy = true);
    final allowed = await PushRegistration.enable();
    if (!mounted) return;
    setState(() {
      _allowed = allowed;
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

  @override
  Widget build(BuildContext context) {
    // A build with no Firebase configured has nothing to offer here, and a
    // switch that cannot do anything is worse than no switch.
    if (!PushRegistration.isAvailable) return const SizedBox.shrink();
    final allowed = _allowed;
    return AppSurface(
      padding: EdgeInsets.zero,
      child: SwitchListTile(
        title: const Text('On this phone'),
        subtitle: Text(
          allowed == true
              ? 'Notifications reach you when the app is closed.'
              : 'Notifications only appear when you open the app.',
        ),
        value: allowed ?? false,
        // Turning it off is the phone's own setting, not ours to fake. Sending
        // somebody to Settings is honest; a switch that appears to turn it off
        // while the system still allows it is not.
        onChanged: _busy || allowed == true
            ? null
            : (_) => unawaited(_turnOn()),
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
