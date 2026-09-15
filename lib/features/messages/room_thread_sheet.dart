import 'package:flutter/material.dart';

import '../../data/music_repository.dart';
import '../../domain/music_models.dart';
import '../../widgets/thread_sheet.dart';

/// The band, talking in the room it already has.
///
/// Taylor: "the same way the colabroom handles rooms, for your projects and
/// bands and such, the chat could be similar, you can create rooms for your
/// band, or message people individually, but it's all in one place."
///
/// A room is a band with songs in it, so its thread needs nobody invited
/// and nothing set up: everybody in the room can read it and write to it,
/// and every line tells the other members the way a direct message tells
/// its one reader. Opened from the Messages screen, from the room itself,
/// and from a message of somebody's in the inbox.
Future<void> showRoomThread(
  BuildContext context, {
  required MusicRepository repository,
  required String roomId,
  required String roomName,
}) {
  return showThreadSheet(
    context,
    sheet: RoomThreadSheet(
      repository: repository,
      roomId: roomId,
      roomName: roomName,
    ),
  );
}

class RoomThreadSheet extends StatelessWidget {
  const RoomThreadSheet({
    required this.repository,
    required this.roomId,
    required this.roomName,
    super.key,
  });

  final MusicRepository repository;
  final String roomId;
  final String roomName;

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
    return ThreadSheet(
      keyPrefix: 'room_thread',
      stage: 'room_thread',
      headline: roomName,
      currentUserId: repository.currentUserId,
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
