import 'package:flutter/material.dart';

import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../widgets/app_surface.dart';

class InvitesScreen extends StatelessWidget {
  const InvitesScreen({super.key});

  Future<void> _acceptCode(BuildContext context) async {
    final controller = BetaScope.of(context);
    final code = await showDialog<String>(
      context: context,
      builder: (_) => const _JoinCodeDialog(),
    );
    if (code == null) return;
    // The dialog is an await, so this context may be gone by the time it
    // returns — _runInviteAction shows snackbars through it.
    if (!context.mounted) return;
    await _runInviteAction(
      context,
      () => controller.acceptInvite(code: code),
      success: 'Catalog joined. You can open it from Catalogs.',
    );
  }

  Future<void> _runInviteAction(
    BuildContext context,
    Future<void> Function() action, {
    required String success,
  }) async {
    try {
      await action();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(success)));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = BetaScope.of(context);
    final invites = controller.invites;
    return DefaultTabController(
      length: 2,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(child: Text('Invites', style: Theme.of(context).textTheme.displaySmall)),
                FilledButton.icon(
                  onPressed: () => _acceptCode(context),
                  icon: const Icon(Icons.key_rounded),
                  label: const Text('Use Code'),
                ),
              ],
            ),
            const SizedBox(height: 18),
            TabBar(
              labelColor: AppColors.cyan,
              unselectedLabelColor: AppColors.muted,
              indicatorColor: AppColors.cyan,
              tabs: <Tab>[
                Tab(text: 'Received  ${invites.length}'),
                const Tab(text: 'Sent'),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: TabBarView(
                children: <Widget>[
                  invites.isEmpty
                      ? const Center(child: Text('No pending invitations.'))
                      : ListView.separated(
                          itemCount: invites.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 12),
                          itemBuilder: (context, index) => _InviteCard(
                            invite: invites[index],
                            onJoin: () => _runInviteAction(
                              context,
                              () => controller.acceptInvite(invite: invites[index]),
                              success: invites[index].isProjectScoped
                                  ? 'Song joined. You can open it from Catalogs.'
                                  : 'Catalog joined. You can open it from Catalogs.',
                            ),
                            onDecline: () => _runInviteAction(
                              context,
                              () => controller.declineInvite(invites[index]),
                              success: 'Invitation declined.',
                            ),
                          ),
                        ),
                  const Center(
                    child: Text('Share codes are created from the invite button inside a catalog.'),
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
      title: const Text('Join with an Invite Code'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: TextField(
          controller: _code,
          autofocus: true,
          autocorrect: false,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: 'Invite code',
            helperText: 'Use the code shared by whoever owns the catalog.',
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _code.text),
          child: const Text('Join catalog'),
        ),
      ],
    );
  }
}

class _InviteCard extends StatelessWidget {
  const _InviteCard({
    required this.invite,
    required this.onJoin,
    required this.onDecline,
  });

  final BetaInvite invite;
  final VoidCallback onJoin;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final initial = invite.inviterName.trim().isEmpty
        ? '?'
        : invite.inviterName.trim().substring(0, 1).toUpperCase();
    return AppSurface(
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
                        'One song in ${invite.roomName} · not the rest of the catalog',
                        style: const TextStyle(color: AppColors.muted, fontSize: 12),
                      ),
                    Text('Invited by ${invite.inviterName} · ${invite.role.name}'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(child: OutlinedButton(onPressed: onDecline, child: const Text('Decline'))),
              const SizedBox(width: 10),
              Expanded(child: FilledButton(onPressed: onJoin, child: const Text('Join'))),
            ],
          ),
        ],
      ),
    );
  }
}
