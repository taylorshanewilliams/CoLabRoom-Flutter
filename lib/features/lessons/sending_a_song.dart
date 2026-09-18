import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';

/// A teacher sending a song to the students who need it (migration 0149).
///
/// Every Musician, Same Song, 17 September 2026, slice 19: an assignment
/// begins as the song itself, copied into each chosen student's lesson room
/// (0129) so the two of them work on it where only they can hear it. The
/// brief that goes with it is the next slice; this is the song arriving.
///
/// Copied rather than shared, which is what makes the rest simple: a song
/// in a two-person room is private by construction, so the student writes
/// and records on their own copy and nothing new has to be kept apart. The
/// server does the copying and decides what travels -- the words, the
/// chords, and the recording only for a song that is ours or public domain
/// (0142). The app's part is to ask whose song it is if nobody has been
/// asked yet, to list the lessons, to have Storage copy the recording (the
/// repository's job), and to say one sentence afterwards.
///
/// Kept out of the screen so the rule about who is offered it and the words
/// can be read in a test, the same reason leaving_practice is its own file.

/// The lessons a song can be sent into: rooms made by this person's own
/// lesson links that they still own, with the student still in them, by
/// the name the room has ("Guitar lessons · Jess"), in that order. Never
/// the song's own room, which already has it, and never a lesson the
/// student has left: the lesson row outlives the membership (0129), and a
/// two-person room with one person in it is nobody to send to. And nothing
/// at all for somebody who does not own the room the song lives in: a song
/// leaving its room is the room owner's decision, the way putting it on
/// the Open Mic is (0142), so an editor in a band room who happens to
/// teach is offered nobody for the band's song. The server refuses the
/// same person in words (0149); this is so the entry is not offered.
List<({String id, String name})> lessonRoomsToSendTo({
  required Iterable<String> taught,
  required List<MusicRoom> rooms,
  required String? me,
  required MusicRoom? songRoom,
}) {
  if (me == null || me.isEmpty || songRoom == null) return const [];
  if (!songRoom.members.any((member) => member.userId == me && member.role == RoomRole.owner)) {
    return const [];
  }
  final wanted = taught.toSet();
  final found = <({String id, String name})>[
    for (final room in rooms)
      if (room.id != songRoom.id &&
          wanted.contains(room.id) &&
          room.members.any((member) => member.userId == me && member.role == RoomRole.owner) &&
          room.members.any((member) => member.userId != me))
        (id: room.id, name: room.name),
  ];
  found.sort((left, right) => left.name.toLowerCase().compareTo(right.name.toLowerCase()));
  return found;
}

/// What the menu entry says.
const String sendToStudentsLabel = 'Send to students';

/// What does not go, said once on the sheet and only when it applies:
/// somebody else's song travels as words and chords, and its recording
/// stays where it is (0142, 0149). Null for a song that goes whole.
String? sendKeepsTheRecording(SongOrigin? origin) =>
    origin == SongOrigin.cover ? "Somebody else's song, so the recording stays here." : null;

/// The one sentence said back, carrying the one number this feature shows.
/// The rooms that received a copy are what is counted, so a send that
/// found every student already had it says so instead -- including a send
/// that only finished a recording on copies the students already had.
String sentSaid(int students) => switch (students) {
      0 => 'Already sent.',
      1 => 'Sent to 1 student',
      _ => 'Sent to $students students',
    };

/// Asks which students: the lessons by name, each with a tick, and one
/// action. Returns the rooms ticked, or null when the sheet was closed.
Future<List<String>?> showSendToStudents(
  BuildContext context, {
  required String songTitle,
  required List<({String id, String name})> rooms,
  SongOrigin? origin,
}) {
  return showModalBottomSheet<List<String>>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: AppColors.deepNavy,
    builder: (sheetContext) => _SendToStudentsSheet(
      songTitle: songTitle,
      rooms: rooms,
      keeps: sendKeepsTheRecording(origin),
    ),
  );
}

class _SendToStudentsSheet extends StatefulWidget {
  const _SendToStudentsSheet({
    required this.songTitle,
    required this.rooms,
    required this.keeps,
  });

  final String songTitle;
  final List<({String id, String name})> rooms;
  final String? keeps;

  @override
  State<_SendToStudentsSheet> createState() => _SendToStudentsSheetState();
}

class _SendToStudentsSheetState extends State<_SendToStudentsSheet> {
  /// Nobody ticked to begin with. A teacher with nine students who wants
  /// all nine taps nine times; one who wants two does not have to untick
  /// seven, and the one that goes to the wrong student cannot be unsent.
  final Set<String> _ticked = <String>{};

  @override
  Widget build(BuildContext context) {
    final keeps = widget.keeps;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 2, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              sendToStudentsLabel,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 3),
            Text(
              widget.songTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.muted, fontSize: 13),
            ),
            if (keeps != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                keeps,
                key: const Key('send_to_students_keeps'),
                style: const TextStyle(color: AppColors.muted, fontSize: 12.5, height: 1.4),
              ),
            ],
            const SizedBox(height: 10),
            // The list scrolls only once it is taller than half the screen,
            // so a studio of three sits whole above the button and a studio
            // of thirty still reaches it.
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.5,
              ),
              child: ListView(
                shrinkWrap: true,
                children: <Widget>[
                  for (final room in widget.rooms)
                    CheckboxListTile(
                      key: Key('send_to_room_${room.id}'),
                      value: _ticked.contains(room.id),
                      onChanged: (ticked) => setState(() {
                        if (ticked ?? false) {
                          _ticked.add(room.id);
                        } else {
                          _ticked.remove(room.id);
                        }
                      }),
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                      title: Text(room.name),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              key: const Key('send_to_students_do'),
              onPressed: _ticked.isEmpty
                  ? null
                  : () => Navigator.pop(context, _ticked.toList(growable: false)),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
              ),
              child: const Text('Send'),
            ),
          ],
        ),
      ),
    );
  }
}
