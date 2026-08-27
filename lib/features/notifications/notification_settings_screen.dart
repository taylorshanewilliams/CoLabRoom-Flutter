import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../widgets/app_surface.dart';

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
            AppSurface(
              padding: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  SwitchListTile(
                    title: const Text('Invites'),
                    subtitle: const Text('When someone invites you to a catalog or a song'),
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
