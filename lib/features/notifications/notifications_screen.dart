import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../services/user_facing_error.dart';
import '../../widgets/problem_report.dart';
import '../../widgets/app_surface.dart';
import '../../domain/musical_roles.dart';
import '../../widgets/play_button.dart';
import '../openmic/report_sheet.dart';

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
      // Was `Text(error.toString())`, which is how a musician standing in a
      // room came to be shown a Postgres unique-constraint violation. The
      // detail goes to the error table now, and the moment somebody has just
      // been let down is the only moment they will describe what they were
      // doing — so there is a way to say more, right there.
      if (!mounted) {
        // Nobody left to tell, and still worth recording. An error that only
        // exists while somebody is looking at it is the state this app spent
        // three weeks in.
        reportAndDescribe(error,
            service: 'app', stage: 'invite', route: 'Inbox');
        return;
      }
      showProblem(context, error,
          service: 'app', stage: 'invite', route: 'Inbox');
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

  /// Saying a song is wrong, from the card it arrived on.
  Future<void> _reportAsk(AskForMe ask) async {
    final controller = BetaScope.of(context, listen: false);
    final sent = await showReportSheet(
      context,
      repository: controller.repository,
      kind: 'song',
      about: ask.songTitle,
      profileId: ask.askedById,
      projectId: ask.projectId,
    );
    if (sent && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Report sent. Somebody reads every one of these.'),
      ));
    }
  }

  /// Making it stop, which is a different thing from reporting it.
  ///
  /// Blocking also closes anything open between the two of you, so the ask
  /// leaves this inbox in the same breath — see block_user in 0063.
  Future<void> _blockAsker(AskForMe ask) async {
    final who = ask.askedById;
    if (who == null) return;
    final controller = BetaScope.of(context, listen: false);
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.raised,
        title: Text('Block ${ask.askedByName}?'),
        content: const Text(
          'They will not be able to ask you again or see anything of yours, '
          'and this ask leaves your inbox. You can undo it in your account.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Block'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    await _run(() => controller.repository.blockUser(who),
        '${ask.askedByName} is blocked.');
  }

  @override
  Widget build(BuildContext context) {
    final controller = BetaScope.of(context);
    final invites = controller.invites;
    final asks = controller.asksForMe;
    final roomInvites = controller.roomInvitesForMe;
    final notifications = controller.notifications;
    final empty = invites.isEmpty &&
        asks.isEmpty &&
        roomInvites.isEmpty &&
        notifications.isEmpty;

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
          // Reading something was never the same as being done with it, and
          // until now there was no way to say the second thing at all: an
          // inbox could only grow.
          if (notifications.any((n) => n.isRead))
            TextButton(
              key: const Key('inbox_clear_read'),
              onPressed: () => unawaited(controller.deleteReadNotifications()),
              child: const Text('Clear read'),
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
                  // First, above invitations. Somebody has asked *you*, by
                  // name, to play something — that is the most personal thing
                  // this inbox can hold and the one thing in it that another
                  // musician is waiting on.
                  if (asks.isNotEmpty) ...<Widget>[
                    const _SectionLabel('Asked of you'),
                    for (final ask in asks) ...<Widget>[
                      _AskCard(
                        ask: ask,
                        busy: _busy,
                        onAccept: () => _run(
                          () => controller.answerAsk(ask, accept: true),
                          '${ask.songTitle} is in Your music now.',
                        ),
                        onDecline: () => _run(
                          () => controller.answerAsk(ask, accept: false),
                          'Passed. They have been told.',
                        ),
                        onReport: () => unawaited(_reportAsk(ask)),
                        onBlock: () => unawaited(_blockAsker(ask)),
                      ),
                      const SizedBox(height: 10),
                    ],
                    const SizedBox(height: 8),
                  ],
                  // Somebody inviting you into a room by name, rather
                  // than by emailing you a code. Same section as the coded
                  // invitations below, because to a person they are the same
                  // thing: somebody wants you in their band.
                  if (roomInvites.isNotEmpty) ...<Widget>[
                    const _SectionLabel('Invitations'),
                    for (final invite in roomInvites) ...<Widget>[
                      _RoomInviteCard(
                        invite: invite,
                        busy: _busy,
                        onAccept: () => _run(
                          () => controller.answerRoomInvite(invite,
                              accept: true),
                          '${invite.roomName} is in Your music now.',
                        ),
                        onDecline: () => _run(
                          () => controller.answerRoomInvite(invite,
                              accept: false),
                          'Declined. They have been told.',
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    const SizedBox(height: 8),
                  ],
                  if (invites.isNotEmpty) ...<Widget>[
                    // No second heading. The note above says these belong in
                    // the same section "because to a person they are the same
                    // thing: somebody wants you in their band" — and then the
                    // code printed INVITATIONS twice whenever both lists had
                    // something in them, which is most of the time somebody
                    // is being invited at all.
                    if (roomInvites.isEmpty) const _SectionLabel('Invitations'),
                    for (final invite in invites) ...<Widget>[
                      _InviteCard(
                        invite: invite,
                        busy: _busy,
                        onJoin: () => _run(
                          () => controller.acceptInvite(invite: invite),
                          invite.isProjectScoped
                              ? 'Song joined. Find it in Your music.'
                              : 'Room joined. Its songs are in Your music.',
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
                      Dismissible(
                        key: ValueKey<String>('notification-${notification.id}'),
                        direction: DismissDirection.endToStart,
                        background: const _ClearBackground(),
                        onDismissed: (_) =>
                            unawaited(controller.deleteNotification(notification)),
                        child: _NotificationCard(
                          notification: notification,
                          onTap: () =>
                              controller.markNotificationRead(notification),
                          // A swipe on its own is not discoverable, and the
                          // inbox is where somebody arrives already annoyed.
                          onClear: () => unawaited(
                              controller.deleteNotification(notification)),
                        ),
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

/// Somebody asking you, by name, to play on their song.
///
/// The card carries the song's title and what they said, and nothing else —
/// which is not a design choice about density but the literal extent of what
/// the person asked is allowed to see. Deciding does not require access;
/// accepting is what grants it, and it grants that one song rather than the
/// room it sits in.
class _AskCard extends StatelessWidget {
  const _AskCard({
    required this.ask,
    required this.busy,
    required this.onAccept,
    required this.onDecline,
    required this.onReport,
    required this.onBlock,
  });

  final AskForMe ask;
  final bool busy;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  /// Somewhere to say this is wrong, and somewhere to make it stop.
  ///
  /// A stranger's song now plays inside this card, which makes the inbox a
  /// place unreviewed audio from somebody you have never met reaches you —
  /// and every surface like that needs both of these within reach. It is
  /// also what App Store 1.2 asks for wherever user content appears, and
  /// the one surface in the app that had neither.
  final VoidCallback onReport;
  final VoidCallback onBlock;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 12),
      decoration: BoxDecoration(
        color: AppColors.raised,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.cyan.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // Hear it first, then read about it. Somebody deciding whether to
          // spend an evening on a stranger's song makes that decision by ear
          // in about ten seconds, and every second before the play button is
          // a second spent reading instead.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if ((ask.storagePath ?? '').isNotEmpty) ...<Widget>[
                PlayButton(
                  storagePath: ask.storagePath!,
                  durationMs: ask.durationMs,
                  title: ask.songTitle,
                  byline: ask.askedByName,
                  songId: ask.projectId,
                  size: 38,
                ),
                const SizedBox(width: 11),
              ],
              Expanded(
                child: Text(
                  ask.headline,
                  style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    height: 1.3,
                  ),
                ),
              ),
              PopupMenuButton<String>(
                key: const Key('ask_card_more'),
                tooltip: 'More',
                icon: const Icon(Icons.more_horiz_rounded,
                    size: 20, color: AppColors.muted),
                onSelected: (choice) =>
                    choice == 'report' ? onReport() : onBlock(),
                itemBuilder: (_) => <PopupMenuEntry<String>>[
                  const PopupMenuItem<String>(
                      value: 'report', child: Text('Report this')),
                  PopupMenuItem<String>(
                      value: 'block',
                      child: Text('Block ${ask.askedByName}')),
                ],
              ),
            ],
          ),
          // What the song is. Every fact here was already in the database
          // and none of it used to reach the person being asked.
          if (ask.brief != null) ...<Widget>[
            const SizedBox(height: 7),
            Text(
              ask.brief!,
              style: const TextStyle(
                  color: AppColors.cyan, fontSize: 12, height: 1.35),
            ),
          ],
          if (ask.partsOnIt.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              // Words, not a number. A count of takes would be a tally of
              // somebody's work, and it tells the person answering nothing
              // about whether there is a hole shaped like them.
              'Already on it: ${ask.partsOnIt.map(MusicalRole.labelFor).join(', ').toLowerCase()}',
              style: const TextStyle(
                  color: AppColors.muted, fontSize: 12, height: 1.35),
            ),
          ],
          if (ask.note.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 7),
            Text(
              '“${ask.note.trim()}”',
              style: const TextStyle(
                color: AppColors.muted,
                fontSize: 13.5,
                height: 1.4,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          const SizedBox(height: 6),
          const Text(
            'Saying yes puts this one song in your library. Nothing else of '
            'theirs opens up.',
            style: TextStyle(color: AppColors.muted, fontSize: 11.5, height: 1.4),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton(
                  onPressed: busy ? null : onAccept,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.cyan,
                    foregroundColor: AppColors.ink,
                  ),
                  child: const Text("I'm in"),
                ),
              ),
              const SizedBox(width: 8),
              // A real answer, not a dismissal. Somebody who asked deserves
              // to hear no rather than nothing, and an ask that can only be
              // answered with silence is one nobody sends twice.
              TextButton(
                onPressed: busy ? null : onDecline,
                style: TextButton.styleFrom(foregroundColor: AppColors.muted),
                child: const Text('Not this one'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Somebody inviting you into a room of theirs.
///
/// Bigger than an ask and drawn to say so: an ask is one song, this is
/// everything in a room and everything added to it later. The card names
/// the room rather than counting its songs, because the count somebody
/// sees before accepting would be out of date the moment they did.
class _RoomInviteCard extends StatelessWidget {
  const _RoomInviteCard({
    required this.invite,
    required this.busy,
    required this.onAccept,
    required this.onDecline,
  });

  final RoomInviteForMe invite;
  final bool busy;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 12),
      decoration: BoxDecoration(
        color: AppColors.raised,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            invite.headline,
            style: const TextStyle(
              color: AppColors.text,
              fontSize: 15,
              fontWeight: FontWeight.w800,
              height: 1.3,
            ),
          ),
          if (invite.note.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 7),
            Text(
              '“${invite.note.trim()}”',
              style: const TextStyle(
                color: AppColors.muted,
                fontSize: 13.5,
                height: 1.4,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          const SizedBox(height: 6),
          const Text(
            'Joining puts every song in that room in your library, '
            'including ones added later. You can leave whenever you like.',
            style: TextStyle(color: AppColors.muted, fontSize: 11.5, height: 1.4),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton(
                  onPressed: busy ? null : onAccept,
                  child: const Text('Join'),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: busy ? null : onDecline,
                style: TextButton.styleFrom(foregroundColor: AppColors.muted),
                child: const Text('No thanks'),
              ),
            ],
          ),
        ],
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
                        'One song in ${invite.roomName} · not the rest of the room',
                        style: const TextStyle(color: AppColors.muted, fontSize: 12),
                      ),
                    Text('${invite.inviterName} invited you as ${invite.role.name}'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Join first and filled, No thanks quiet and second — the same
          // shape as the room invitation directly above it. These two cards
          // asked the identical question in opposite orders, with the
          // dismissive answer sitting where the eye and the thumb both go
          // first on one of them.
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton(
                  onPressed: busy ? null : onJoin,
                  child: const Text('Join'),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: busy ? null : onDecline,
                style: TextButton.styleFrom(foregroundColor: AppColors.muted),
                child: const Text('No thanks'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// What shows behind a notification on its way out.
class _ClearBackground extends StatelessWidget {
  const _ClearBackground();

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 18),
      decoration: BoxDecoration(
        color: AppColors.raised,
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Icon(Icons.delete_outline_rounded,
          size: 19, color: Color(0xFFFF718B)),
    );
  }
}

class _NotificationCard extends StatelessWidget {
  const _NotificationCard({
    required this.notification,
    required this.onTap,
    required this.onClear,
  });

  final AppNotification notification;
  final VoidCallback onTap;
  final VoidCallback onClear;

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
      case NotificationType.analysisReady:
        // The same icon the room list uses to mark a song that has audio, so
        // "your analysis finished" and "this song has a recording" read as one
        // idea in two places rather than two unrelated ones.
        return Icons.graphic_eq_rounded;
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
            Tooltip(
              message: 'Clear this notification',
              child: InkResponse(
                onTap: onClear,
                radius: 18,
                child: const Padding(
                  padding: EdgeInsets.only(left: 8, top: 2),
                  child: Icon(Icons.close_rounded,
                      size: 16, color: AppColors.muted),
                ),
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
