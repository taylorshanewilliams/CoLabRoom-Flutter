import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../widgets/app_surface.dart';

/// The single inbox: pending invitations you can act on, then everything
/// that has happened since you were last here.
///
/// Invites used to own a whole bottom-nav tab. Once notifications existed
/// that meant one event showed up in two places, and the tab was permanent
/// real estate for something most people encounter a handful of times. They
/// live here now, at the top, as cards you can accept or decline in place.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action, String success) async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      messenger.showSnackBar(SnackBar(content: Text(success)));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _useCode() async {
    final controller = BetaScope.of(context);
    final code = await showDialog<String>(
      context: context,
      builder: (_) => const _JoinCodeDialog(),
    );
    if (code == null || !mounted) return;
    await _run(
      () => controller.acceptInvite(code: code),
      'Joined. You can open it from Songs.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = BetaScope.of(context);
    final invites = controller.invites;
    final notifications = controller.notifications;
    final empty = invites.isEmpty && notifications.isEmpty;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Inbox'),
        actions: <Widget>[
          if (notifications.any((n) => !n.isRead))
            TextButton(
              onPressed: () => controller.markAllNotificationsRead(),
              child: const Text('Mark all read'),
            ),
          IconButton(
            key: const Key('inbox_use_code'),
            tooltip: 'Join with an invite code',
            onPressed: _useCode,
            icon: const Icon(Icons.key_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: empty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(30),
                  child: Text(
                    'Nothing new. Invitations and activity from your\ncollaborators will show up here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.muted),
                  ),
                ),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
                children: <Widget>[
                  if (invites.isNotEmpty) ...<Widget>[
                    const _SectionLabel('Invitations'),
                    for (final invite in invites) ...<Widget>[
                      _InviteCard(
                        invite: invite,
                        busy: _busy,
                        onJoin: () => _run(
                          () => controller.acceptInvite(invite: invite),
                          invite.isProjectScoped
                              ? 'Song joined. Find it under Songs.'
                              : 'Room joined. Its songs are under Songs.',
                        ),
                        onDecline: () => _run(
                          () => controller.declineInvite(invite),
                          'Invitation declined.',
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    const SizedBox(height: 8),
                  ],
                  if (notifications.isNotEmpty) ...<Widget>[
                    const _SectionLabel('Activity'),
                    for (final notification in notifications) ...<Widget>[
                      _NotificationCard(
                        notification: notification,
                        onTap: () => controller.markNotificationRead(notification),
                      ),
                      const SizedBox(height: 10),
                    ],
                  ],
                ],
              ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 2),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: AppColors.muted,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.9,
        ),
      ),
    );
  }
}

class _InviteCard extends StatelessWidget {
  const _InviteCard({
    required this.invite,
    required this.busy,
    required this.onJoin,
    required this.onDecline,
  });

  final BetaInvite invite;
  final bool busy;
  final VoidCallback onJoin;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final initial = invite.inviterName.trim().isEmpty
        ? '?'
        : invite.inviterName.trim().substring(0, 1).toUpperCase();
    return AppSurface(
      color: AppColors.raised,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              CircleAvatar(backgroundColor: AppColors.blue, child: Text(initial)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      invite.isProjectScoped ? invite.projectTitle ?? 'A song' : invite.roomName,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (invite.isProjectScoped)
                      Text(
                        'One song in ${invite.roomName} · not the rest of the Room',
                        style: const TextStyle(color: AppColors.muted, fontSize: 12),
                      ),
                    Text('${invite.inviterName} invited you as ${invite.role.name}'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton(
                  onPressed: busy ? null : onDecline,
                  child: const Text('Decline'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: busy ? null : onJoin,
                  child: const Text('Join'),
                ),
              ),
            ],
          ),
        ],
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
                decoration: const BoxDecoration(color: AppColors.cyan, shape: BoxShape.circle),
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

class _JoinCodeDialog extends StatefulWidget {
  const _JoinCodeDialog();

  @override
  State<_JoinCodeDialog> createState() => _JoinCodeDialogState();
}

class _JoinCodeDialogState extends State<_JoinCodeDialog> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Join with a code'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: TextField(
          controller: _code,
          autofocus: true,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Invite code',
            helperText: 'Only needed if the invite was sent before you had an account.',
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _code.text),
          child: const Text('Join'),
        ),
      ],
    );
  }
}
