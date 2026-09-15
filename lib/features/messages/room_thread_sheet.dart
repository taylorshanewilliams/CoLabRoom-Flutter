import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../app/music_beta_controller.dart';
import '../../app/routes.dart';
import '../../domain/music_models.dart';
import '../../widgets/player_face.dart';
import '../../widgets/room_mark.dart';
import '../../widgets/thread_sheet.dart';
import '../rooms/room_actions.dart';
import '../rooms/room_detail_screen.dart';
import '../rooms/room_members_screen.dart';

/// The band, talking in the room it already has -- and the room itself.
///
/// Taylor: "the same way the colabroom handles rooms, for your projects and
/// bands and such, the chat could be similar ... within the messages tab, a
/// way to create rooms, delete rooms, invite people etc." So the thread's
/// header is the room: its picture (tap to give it one), its name (tap to
/// rename), who is in it, and the four things people do to a room --
/// invite somebody, set the picture, open the songs, see the members --
/// with rename, leave or delete under the dots. The same actions as the
/// room screen, from the same code, so the two doors never disagree.
Future<void> showRoomThread(
  BuildContext context, {
  required MusicBetaController controller,
  required String roomId,
  String? roomName,
}) {
  return showThreadSheet(
    context,
    sheet: RoomThreadSheet(
      controller: controller,
      roomId: roomId,
      roomName: roomName,
    ),
  );
}

class RoomThreadSheet extends StatelessWidget {
  const RoomThreadSheet({
    required this.controller,
    required this.roomId,
    this.roomName,
    super.key,
  });

  final MusicBetaController controller;
  final String roomId;

  /// What to call the room until it is loaded -- a notification knows the
  /// name before the room list does.
  final String? roomName;

  ThreadLine _line(RoomMessage message) => ThreadLine(
        id: message.id,
        authorId: message.authorId,
        authorName: message.authorName,
        body: message.body,
        createdAt: message.createdAt,
        source: message,
      );

  @override
  Widget build(BuildContext context) {
    final repository = controller.repository;
    return ThreadSheet(
      keyPrefix: 'room_thread',
      stage: 'room_thread',
      headline: roomName ?? controller.roomById(roomId)?.name ?? 'Room',
      header: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final room = controller.roomById(roomId);
          if (room == null) {
            return Text(
              roomName ?? 'Room',
              key: const Key('room_thread_headline'),
              style: const TextStyle(
                color: AppColors.text,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            );
          }
          return _RoomHeader(controller: controller, room: room);
        },
      ),
      currentUserId: repository.currentUserId,
      changes: controller,
      emptyLine: 'Nothing said yet. Everybody in this room can read what is '
          'said here.',
      load: () async => <ThreadLine>[
        for (final message in await repository.loadRoomMessages(roomId))
          _line(message),
      ],
      send: (body) async =>
          _line(await repository.sendRoomMessage(roomId: roomId, body: body)),
      takeBack: (line) =>
          repository.deleteRoomMessage(line.source! as RoomMessage),
    );
  }
}

class _RoomHeader extends StatelessWidget {
  const _RoomHeader({required this.controller, required this.room});

  final MusicBetaController controller;
  final MusicRoom room;

  void _openSongs(BuildContext context) {
    // Out of the sheet first, so back from the room lands on Messages.
    Navigator.of(context).pop();
    Navigator.of(context).push(MaterialPageRoute<void>(
      settings: RouteSettings(name: AppRoutes.room(room.id)),
      builder: (_) => RoomDetailScreen(roomId: room.id),
    ));
  }

  void _openMembers(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => RoomMembersScreen(roomId: room.id),
    ));
  }

  Future<void> _more(BuildContext context, String value) async {
    switch (value) {
      case 'rename':
        await renameRoom(context, controller, room);
      case 'remove_picture':
        await clearRoomLogo(context, controller, room);
      case 'leave':
        if (await leaveRoom(context, controller, room) && context.mounted) {
          Navigator.of(context).pop();
        }
      case 'delete':
        if (await deleteRoom(context, controller, room) && context.mounted) {
          Navigator.of(context).pop();
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final owner = isRoomOwner(room, controller.repository.currentUserId);
    final logo = controller.roomLogoBytes(room);
    final people = room.members.length;
    final songs = room.projects.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            RoomMark(
              key: const Key('room_thread_mark'),
              name: room.name,
              logo: logo,
              size: 48,
              tooltip: logo == null
                  ? 'Give this room a picture'
                  : 'Change this room’s picture',
              onTap: () => unawaited(pickRoomLogo(context, controller, room)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  InkWell(
                    onTap: () => unawaited(renameRoom(context, controller, room)),
                    borderRadius: BorderRadius.circular(6),
                    child: Text(
                      room.name,
                      key: const Key('room_thread_headline'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        height: 1.25,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: <Widget>[
                      if (people > 1) ...<Widget>[
                        _Faces(controller: controller, room: room),
                        const SizedBox(width: 6),
                      ],
                      Expanded(
                        child: Text(
                          people == 1
                              ? 'Just you · $songs ${songs == 1 ? 'song' : 'songs'}'
                              : '$people in the room · $songs ${songs == 1 ? 'song' : 'songs'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: AppColors.muted, fontSize: 12.5),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              key: const Key('room_thread_more'),
              tooltip: 'More',
              color: AppColors.raised,
              icon: const Icon(Icons.more_horiz_rounded, color: AppColors.muted),
              onSelected: (value) => unawaited(_more(context, value)),
              itemBuilder: (_) => <PopupMenuEntry<String>>[
                const PopupMenuItem<String>(
                    value: 'rename', child: Text('Rename room')),
                if (logo != null)
                  const PopupMenuItem<String>(
                      value: 'remove_picture', child: Text('Remove picture')),
                if (owner)
                  const PopupMenuItem<String>(
                    key: Key('room_thread_delete'),
                    value: 'delete',
                    child: Text('Delete room'),
                  )
                else
                  const PopupMenuItem<String>(
                    key: Key('room_thread_leave'),
                    value: 'leave',
                    child: Text('Leave room'),
                  ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 10),
        // The four things people do to a room, as pills. Invite first: a
        // room with one person in it is a band waiting to happen.
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: <Widget>[
            _Pill(
              key: const Key('room_thread_invite'),
              icon: Icons.person_add_alt_1_rounded,
              label: 'Invite',
              gold: people == 1,
              onTap: () => unawaited(inviteToRoom(context, controller, room)),
            ),
            _Pill(
              key: const Key('room_thread_picture'),
              icon: Icons.add_photo_alternate_outlined,
              label: logo == null ? 'Picture' : 'Change picture',
              onTap: () => unawaited(pickRoomLogo(context, controller, room)),
            ),
            _Pill(
              key: const Key('room_thread_songs'),
              icon: Icons.library_music_rounded,
              label: songs == 0 ? 'Songs' : 'Songs · $songs',
              onTap: () => _openSongs(context),
            ),
            if (people > 1)
              _Pill(
                key: const Key('room_thread_members'),
                icon: Icons.group_outlined,
                label: 'Members',
                onTap: () => _openMembers(context),
              ),
          ],
        ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.icon,
    required this.label,
    required this.onTap,
    this.gold = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool gold;

  @override
  Widget build(BuildContext context) {
    final color = gold ? AppColors.gold : AppColors.cyan;
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      // Styled on the Text, never through styleFrom(textStyle:), which
      // replaces the resolved style and takes the font family with it.
      label: Text(
        label,
        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withValues(alpha: 0.45)),
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      ),
    );
  }
}

/// The people in the room, as a short stack of faces.
class _Faces extends StatelessWidget {
  const _Faces({required this.controller, required this.room});

  final MusicBetaController controller;
  final MusicRoom room;

  @override
  Widget build(BuildContext context) {
    final shown = room.members.take(4).toList(growable: false);
    return SizedBox(
      width: 18.0 + 12.0 * (shown.length - 1) + 4,
      height: 20,
      child: Stack(
        children: <Widget>[
          for (var i = 0; i < shown.length; i += 1)
            Positioned(
              left: 12.0 * i,
              child: PlayerFace(
                name: shown[i].displayName,
                color: Color(shown[i].colorValue),
                photo: controller.avatarBytesFor(shown[i].avatarPath),
                size: 20,
              ),
            ),
        ],
      ),
    );
  }
}
