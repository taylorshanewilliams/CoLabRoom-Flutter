import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/colabroom_theme.dart';
import '../domain/music_models.dart';

class InviteDraft {
  const InviteDraft(this.email, this.role);

  final String email;
  final RoomRole role;
}

/// Collects an email + permission level for an invite — used for both
/// whole-Room invites and single-song invites; [title] and [subtitle]
/// carry the only scope-specific copy.
class InviteCollaboratorDialog extends StatefulWidget {
  const InviteCollaboratorDialog({
    this.title = 'Invite a Collaborator',
    this.subtitle,
    super.key,
  });

  final String title;
  final String? subtitle;

  @override
  State<InviteCollaboratorDialog> createState() => _InviteCollaboratorDialogState();
}

class _InviteCollaboratorDialogState extends State<InviteCollaboratorDialog> {
  final _email = TextEditingController();
  RoomRole _role = RoomRole.editor;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (widget.subtitle != null) ...<Widget>[
                Text(widget.subtitle!, style: const TextStyle(color: AppColors.muted, fontSize: 12.5)),
                const SizedBox(height: 14),
              ],
              TextField(
                controller: _email,
                autofocus: true,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Their email'),
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<RoomRole>(
                initialValue: _role,
                decoration: const InputDecoration(labelText: 'Permission'),
                items: const <DropdownMenuItem<RoomRole>>[
                  DropdownMenuItem(value: RoomRole.editor, child: Text('Editor')),
                  DropdownMenuItem(value: RoomRole.commenter, child: Text('Commenter')),
                  DropdownMenuItem(value: RoomRole.viewer, child: Text('Viewer')),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _role = value);
                },
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, InviteDraft(_email.text, _role)),
          child: const Text('Create Invite'),
        ),
      ],
    );
  }
}

/// Shown only when [email] doesn't have a CoLabRoom account yet — the
/// fallback half of the invite flow, after [InviteCollaboratorDialog]. When
/// the email does match an account, the invitee is notified in-app instead
/// and this dialog is skipped entirely (see the `matchedAccount` branch at
/// each `InviteCollaboratorDialog` call site).
Future<void> showInviteReadyDialog(
  BuildContext context, {
  required String email,
  required String code,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Invite ready'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '$email doesn\'t have a CoLabRoom account yet. Share this code with '
              'them — once they sign up, they can redeem it from Invites → Use Code. '
              'It expires in seven days.',
            ),
            const SizedBox(height: 16),
            SelectableText(
              code,
              style: const TextStyle(
                color: AppColors.cyan,
                fontWeight: FontWeight.w800,
                fontSize: 18,
                letterSpacing: 1.1,
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: code));
            if (dialogContext.mounted) {
              ScaffoldMessenger.of(dialogContext).showSnackBar(
                const SnackBar(content: Text('Invite code copied.')),
              );
            }
          },
          child: const Text('Copy Code'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}
