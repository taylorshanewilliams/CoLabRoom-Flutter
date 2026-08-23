import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../widgets/app_surface.dart';

class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = BetaScope.of(context);
    final notifications = controller.notifications;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Notifications'),
        actions: <Widget>[
          if (notifications.any((notification) => !notification.isRead))
            TextButton(
              onPressed: () => controller.markAllNotificationsRead(),
              child: const Text('Mark all read'),
            ),
        ],
      ),
      body: SafeArea(
        child: notifications.isEmpty
            ? const Center(child: Text('No notifications yet.'))
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
                itemCount: notifications.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final notification = notifications[index];
                  return _NotificationCard(
                    notification: notification,
                    onTap: () => controller.markNotificationRead(notification),
                  );
                },
              ),
      ),
    );
  }
}

class _NotificationCard extends StatelessWidget {
  const _NotificationCard({required this.notification, required this.onTap});

  final AppNotification notification;
  final VoidCallback onTap;

  IconData get _icon {
    switch (notification.type) {
      case NotificationType.inviteReceived:
        return Icons.mail_outline_rounded;
      case NotificationType.inviteAccepted:
        return Icons.check_circle_outline_rounded;
      case NotificationType.inviteDeclined:
        return Icons.cancel_outlined;
      case NotificationType.projectUpdate:
        return Icons.edit_note_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: const BorderRadius.all(Radius.circular(19)),
      child: AppSurface(
        color: notification.isRead ? AppColors.surface : AppColors.raised,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(_icon, color: notification.isRead ? AppColors.muted : AppColors.cyan),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    notification.title,
                    style: TextStyle(
                      fontWeight: notification.isRead ? FontWeight.w600 : FontWeight.w800,
                    ),
                  ),
                  if (notification.body.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(notification.body, style: const TextStyle(color: AppColors.muted)),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    _relativeTime(notification.createdAt),
                    style: const TextStyle(color: AppColors.muted, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (!notification.isRead)
              Container(
                width: 9,
                height: 9,
                margin: const EdgeInsets.only(top: 4, left: 8),
                decoration: const BoxDecoration(
                  color: AppColors.cyan,
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _relativeTime(DateTime time) {
    final difference = DateTime.now().difference(time);
    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inMinutes < 60) return '${difference.inMinutes}m ago';
    if (difference.inHours < 24) return '${difference.inHours}h ago';
    return '${difference.inDays}d ago';
  }
}
