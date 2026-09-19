import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../app/music_beta_controller.dart';
import '../../domain/music_models.dart';
import '../../services/picture_for_upload.dart';
import '../../services/user_facing_error.dart';
import '../../widgets/invite_collaborator_dialog.dart';
import '../../widgets/note_that_fits.dart';

/// What can be done to a room, from wherever the room is.
///
/// These lived as private methods on the room screen, which meant the
/// room's thread on the Messages tab -- the place Taylor asked to "create
/// rooms, delete rooms, invite people" from -- could not offer any of
/// them without a second copy. One copy, two doors, the same words.

void _say(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showNote(message);
}

/// Whether [me] owns [room]. An owner cannot leave -- there would be
/// nobody left who can invite, rename or delete it -- and everybody else
/// cannot delete. So a menu offers exactly one of the two, never both.
bool isRoomOwner(MusicRoom room, String me) {
  for (final member in room.members) {
    if (member.userId == me) return member.role == RoomRole.owner;
  }
  return false;
}

/// Give the room a picture, from the phone's own picker.
Future<void> pickRoomLogo(
  BuildContext context,
  MusicBetaController controller,
  MusicRoom room,
) async {
  final file = await FilePicker.pickFile(type: FileType.image);
  if (file == null || !context.mounted) return;
  try {
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) throw Exception('That image could not be read.');
    await controller.setRoomLogo(room, await PictureForUpload.shrink(bytes));
  } catch (error) {
    if (!context.mounted) return;
    _say(context, reportAndDescribe(error,
        service: 'app', stage: 'set_room_logo', route: 'Room'));
  }
}

Future<void> clearRoomLogo(
  BuildContext context,
  MusicBetaController controller,
  MusicRoom room,
) async {
  try {
    await controller.clearRoomLogo(room);
  } catch (error) {
    if (!context.mounted) return;
    _say(context, reportAndDescribe(error,
        service: 'app', stage: 'clear_room_logo', route: 'Room'));
  }
}

Future<void> renameRoom(
  BuildContext context,
  MusicBetaController controller,
  MusicRoom room,
) async {
  final value = await showDialog<String>(
    context: context,
    builder: (_) => RenameRoomDialog(initialName: room.name),
  );
  if (value == null || !context.mounted) return;
  try {
    await controller.renameRoom(room, value);
  } catch (error) {
    if (!context.mounted) return;
    _say(context, reportAndDescribe(error, service: 'app', route: 'Room'));
  }
}

/// Invite somebody by email: an account that matches is told in its inbox,
/// anybody else gets a code to paste.
Future<void> inviteToRoom(
  BuildContext context,
  MusicBetaController controller,
  MusicRoom room,
) async {
  final draft = await showDialog<InviteDraft>(
    context: context,
    builder: (_) => InviteCollaboratorDialog(
      title: 'Invite to ${room.name}',
      subtitle: 'They get every song in the room, and its thread.',
    ),
  );
  if (draft == null || !context.mounted) return;
  try {
    final result =
        await controller.createInvite(room, draft.email, role: draft.role);
    if (!context.mounted) return;
    if (result.matchedAccount) {
      _say(context,
          'Invite sent — ${draft.email} will see it in their inbox.');
    } else {
      await showInviteReadyDialog(context, email: draft.email, code: result.code);
    }
  } catch (error) {
    if (!context.mounted) return;
    _say(context, reportAndDescribe(error, service: 'app', route: 'Room'));
  }
}

/// Leave, after asking. True when the person is no longer in the room.
Future<bool> leaveRoom(
  BuildContext context,
  MusicBetaController controller,
  MusicRoom room,
) async {
  final sure = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: AppColors.raised,
      title: Text('Leave ${room.name}?'),
      content: const Text(
        'You lose the room and every song in it. What you recorded stays '
        'with the songs — a take keeps its author, and leaving does not '
        'erase the work you did with them.',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Stay'),
        ),
        FilledButton(
          key: const Key('leave_room_confirm'),
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFF718B)),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Leave'),
        ),
      ],
    ),
  );
  if (sure != true || !context.mounted) return false;
  try {
    await controller.leaveRoom(room.id);
    return true;
  } catch (error) {
    if (!context.mounted) return false;
    _say(context, reportAndDescribe(error,
        service: 'app', stage: 'leave_room', route: 'Room'));
    return false;
  }
}

/// Delete, after asking. True when the room is gone.
Future<bool> deleteRoom(
  BuildContext context,
  MusicBetaController controller,
  MusicRoom room,
) async {
  final songs = room.projects.length;
  final sure = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: AppColors.raised,
      title: Text('Delete ${room.name}?'),
      content: Text(
        'This permanently deletes the room and everything in it — '
        '$songs ${songs == 1 ? 'song' : 'songs'}, with their words, takes '
        'and song sheets, and everything said in its thread. It takes them '
        'from everybody in the room, not only you, and cannot be undone.',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Keep'),
        ),
        FilledButton(
          key: const Key('delete_room_confirm'),
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFF718B)),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (sure != true || !context.mounted) return false;
  try {
    await controller.deleteRoom(room);
    return true;
  } catch (error) {
    if (!context.mounted) return false;
    _say(context, reportAndDescribe(error,
        service: 'app', stage: 'delete_room', route: 'Room'));
    return false;
  }
}

class RenameRoomDialog extends StatefulWidget {
  const RenameRoomDialog({required this.initialName, super.key});

  final String initialName;

  @override
  State<RenameRoomDialog> createState() => _RenameRoomDialogState();
}

class _RenameRoomDialogState extends State<RenameRoomDialog> {
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
      title: const Text('Rename room'),
      content: TextField(
        controller: _name,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        onSubmitted: (value) {
          if (value.trim().isNotEmpty) Navigator.pop(context, value);
        },
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        // Waits for words: with nothing typed it used to close and complain.
        ListenableBuilder(
          listenable: _name,
          builder: (context, _) => FilledButton(
            onPressed: _name.text.trim().isEmpty ? null : () => Navigator.pop(context, _name.text),
            child: const Text('Save'),
          ),
        ),
      ],
    );
  }
}
