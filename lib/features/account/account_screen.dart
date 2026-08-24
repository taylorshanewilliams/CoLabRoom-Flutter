import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app/beta_config.dart';
import '../../app/beta_scope.dart';
import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';
import '../../widgets/app_surface.dart';
import '../notifications/notification_settings_screen.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({this.supabase, super.key});

  final SupabaseClient? supabase;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  bool _savingAvatar = false;

  bool _requestedAvatar = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Fetched when this screen opens rather than on every app load — for now
    // this is the only place a profile picture is looked at. Here rather than
    // in initState because the scope isn't reachable that early.
    if (_requestedAvatar) return;
    _requestedAvatar = true;
    unawaited(BetaScope.of(context, listen: false).loadAvatar());
  }

  Future<void> _changeAvatar(BuildContext context) async {
    final controller = BetaScope.of(context, listen: false);
    final file = await FilePicker.pickFile(type: FileType.image);
    if (file == null || !context.mounted) return;
    setState(() => _savingAvatar = true);
    try {
      await controller.setAvatar(await file.readAsBytes());
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('Could not save that picture: $error')));
      }
    } finally {
      if (mounted) setState(() => _savingAvatar = false);
    }
  }

  Future<void> _removeAvatar(BuildContext context) async {
    final controller = BetaScope.of(context, listen: false);
    setState(() => _savingAvatar = true);
    try {
      await controller.clearAvatar();
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('Could not remove that picture: $error')));
      }
    } finally {
      if (mounted) setState(() => _savingAvatar = false);
    }
  }

  Future<void> _editProfile(BuildContext context, String currentName) async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => _EditProfileDialog(initialName: currentName),
    );
    final cleaned = value?.trim();
    if (cleaned == null || cleaned.isEmpty || !context.mounted) return;
    try {
      final client = widget.supabase;
      if (client == null) return;
      await client.auth.updateUser(
        UserAttributes(data: <String, dynamic>{'display_name': cleaned}),
      );
      await client.from('profiles').update(<String, dynamic>{'display_name': cleaned}).eq(
            'id',
            client.auth.currentUser!.id,
          );
      if (mounted) setState(() {});
    } on AuthException catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  void _showPrivacy(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Privacy & Data'),
        content: const Text(
          'Music Rooms are private to members. Contributions retain their author and '
          'timestamp. Deleting an account removes its profile and contributions; Rooms '
          'owned by that account are also permanently deleted.',
        ),
        actions: <Widget>[
          FilledButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Done')),
        ],
      ),
    );
  }

  Future<void> _deleteAccount(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Account?'),
        content: const Text(
          'This permanently deletes your profile, your contributions, and every Room '
          'you own—including its song projects. This cannot be undone.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete Permanently'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      final client = widget.supabase;
      if (client == null) return;
      await client.rpc<void>('delete_my_account');
      await client.auth.signOut();
    } on PostgrestException catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  Future<void> _feedback(BuildContext context) async {
    final message = await showDialog<String>(
      context: context,
      builder: (_) => const _FeedbackDialog(),
    );
    if (message == null || message.isEmpty || !context.mounted) return;
    final platform = kIsWeb ? 'web' : defaultTargetPlatform.name;
    await BetaScope.of(context).submitFeedback(
      FeedbackDraft(
        category: 'general',
        message: message,
        route: 'account',
        platform: platform,
        appVersion: BetaConfig.appVersion,
      ),
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Thank you—your beta feedback was saved.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.supabase?.auth.currentUser;
    final displayName = user?.userMetadata?['display_name'] as String? ?? 'Taylor Williams';
    final email = user?.email ?? 'Local preview';
    final initials = _initials(displayName);
    // Listening, so the picture appears the moment the fetch or the upload
    // lands rather than on the next rebuild that happens for another reason.
    final avatar = BetaScope.of(context).avatarBytes;
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 30),
      children: <Widget>[
        Text('Account', style: Theme.of(context).textTheme.displaySmall),
        const SizedBox(height: 20),
        AppSurface(
          child: Row(
            children: <Widget>[
              Semantics(
                button: user != null,
                label: avatar == null ? 'Add a profile picture' : 'Change your profile picture',
                child: InkWell(
                  onTap: user == null || _savingAvatar ? null : () => _changeAvatar(context),
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: 60,
                    height: 60,
                    alignment: Alignment.center,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      // The initials gradient stays as the ground rather than
                      // becoming a grey placeholder: with no picture set it
                      // still reads as a person, not as a missing image.
                      gradient: avatar == null
                          ? const LinearGradient(
                              colors: <Color>[AppColors.blue, Color(0xFF124A80)],
                            )
                          : null,
                      image: avatar == null
                          ? null
                          : DecorationImage(image: MemoryImage(avatar), fit: BoxFit.cover),
                    ),
                    child: _savingAvatar
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.text),
                          )
                        : avatar == null
                            ? Text(
                                initials,
                                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                              )
                            : null,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(displayName, style: Theme.of(context).textTheme.titleLarge),
                    Text(email),
                    if (user != null)
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          TextButton(
                            onPressed: () => _editProfile(context, displayName),
                            child: const Text('Edit profile  ›'),
                          ),
                          TextButton(
                            onPressed: _savingAvatar ? null : () => _changeAvatar(context),
                            child: Text(avatar == null ? 'Add photo' : 'Change photo'),
                          ),
                          if (avatar != null)
                            TextButton(
                              onPressed: _savingAvatar ? null : () => _removeAvatar(context),
                              child: const Text('Remove'),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        AppSurface(
          padding: EdgeInsets.zero,
          child: Column(
            children: <Widget>[
              _AccountRow(
                icon: Icons.chat_bubble_outline_rounded,
                label: 'Help & Beta Feedback',
                onTap: () => _feedback(context),
              ),
              _AccountRow(
                icon: Icons.notifications_outlined,
                label: 'Notifications',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const NotificationSettingsScreen()),
                ),
              ),
              _AccountRow(
                icon: Icons.shield_outlined,
                label: 'Privacy & Data',
                onTap: () => _showPrivacy(context),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        if (user != null) ...<Widget>[
          OutlinedButton.icon(
            onPressed: () => widget.supabase?.auth.signOut(),
            icon: const Icon(Icons.logout_rounded),
            label: const Text('Sign Out'),
          ),
          TextButton(
            onPressed: () => _deleteAccount(context),
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Delete Account'),
          ),
          const SizedBox(height: 18),
        ],
        Text(
          'CoLabRoom Music Beta · ${BetaConfig.appVersion}',
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.muted),
        ),
      ],
    );
  }

  String _initials(String name) {
    final words = name.trim().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
    if (words.isEmpty) return 'CR';
    if (words.length == 1) return words.first.substring(0, 1).toUpperCase();
    return '${words.first.substring(0, 1)}${words.last.substring(0, 1)}'.toUpperCase();
  }
}

class _EditProfileDialog extends StatefulWidget {
  const _EditProfileDialog({required this.initialName});

  final String initialName;

  @override
  State<_EditProfileDialog> createState() => _EditProfileDialogState();
}

class _EditProfileDialogState extends State<_EditProfileDialog> {
  late final TextEditingController _name;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Profile'),
      content: TextField(
        controller: _name,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(labelText: 'Display name'),
        onSubmitted: (name) => Navigator.pop(context, name),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _name.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _FeedbackDialog extends StatefulWidget {
  const _FeedbackDialog();

  @override
  State<_FeedbackDialog> createState() => _FeedbackDialogState();
}

class _FeedbackDialogState extends State<_FeedbackDialog> {
  final _message = TextEditingController();

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Beta feedback'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          child: TextField(
            controller: _message,
            autofocus: true,
            minLines: 4,
            maxLines: 8,
            decoration: const InputDecoration(
              hintText: 'What happened, and what did you expect?',
            ),
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _message.text.trim()),
          child: const Text('Send Feedback'),
        ),
      ],
    );
  }
}

class _AccountRow extends StatelessWidget {
  const _AccountRow({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: AppColors.muted),
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
    );
  }
}
