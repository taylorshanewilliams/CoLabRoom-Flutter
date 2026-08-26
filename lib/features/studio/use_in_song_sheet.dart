import 'package:flutter/material.dart';

import '../../app/colabroom_theme.dart';
import '../../domain/music_models.dart';

/// What a recording should become.
///
/// The app has only ever been able to answer this one way: a new song. That
/// is why a band ends up with two songs of the same name — somebody records
/// the song they have been writing for a week, and the only button available
/// makes a second copy holding the audio and none of the words. The lyrics
/// were never lost; there was simply no way to say "this recording is *that*
/// song".
class UseInSongChoice {
  const UseInSongChoice.newSong()
      : project = null,
        isNew = true;

  const UseInSongChoice.existing(SongProject this.project) : isNew = false;

  final SongProject? project;
  final bool isNew;
}

/// Picks the song a recording belongs to.
Future<UseInSongChoice?> showUseInSongSheet(
  BuildContext context,
  List<MusicRoom> rooms,
) {
  final songs = <({MusicRoom room, SongProject project})>[
    for (final room in rooms)
      for (final project in room.projects) (room: room, project: project),
  ]..sort((a, b) => b.project.updatedAt.compareTo(a.project.updatedAt));

  return showModalBottomSheet<UseInSongChoice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: AppColors.deepNavy,
    builder: (sheetContext) => SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: songs.isEmpty ? 0.35 : 0.7,
        maxChildSize: 0.92,
        builder: (context, scrollController) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 2),
              child: Text(
                'Use this in a song',
                style: TextStyle(
                    color: AppColors.text,
                    fontSize: 18,
                    fontWeight: FontWeight.w800),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text(
                'Attach it to something you are already writing, or start a '
                'new song from it.',
                style: TextStyle(
                    color: AppColors.muted, fontSize: 12.5, height: 1.4),
              ),
            ),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                children: <Widget>[
                  ListTile(
                    key: const Key('use_in_new_song'),
                    leading: const Icon(Icons.add_rounded, color: AppColors.gold),
                    title: const Text('A new song',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: const Text('Name it and pick a Room'),
                    onTap: () => Navigator.pop(
                        sheetContext, const UseInSongChoice.newSong()),
                  ),
                  if (songs.isNotEmpty) ...<Widget>[
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
                      child: Text(
                        'OR ADD IT TO',
                        style: TextStyle(
                          color: AppColors.muted,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                    for (final entry in songs)
                      ListTile(
                        leading: Icon(
                          entry.project.hasAudioReference
                              ? Icons.graphic_eq_rounded
                              : Icons.music_note_rounded,
                          color: entry.project.hasAudioReference
                              ? AppColors.orange
                              : AppColors.cyan,
                        ),
                        title: Text(entry.project.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text(
                          _describe(entry.room, entry.project),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => Navigator.pop(
                          sheetContext,
                          UseInSongChoice.existing(entry.project),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// What is already on a song, said before somebody picks it.
///
/// The line count matters most: it is the thing a person is afraid of losing,
/// and seeing "54 lines" next to a title is what makes attaching to it feel
/// safe rather than reckless. The warning about an existing recording matters
/// too, because that one really is replaced.
String _describe(MusicRoom room, SongProject project) {
  final lines = project.contributions.length;
  return <String>[
    '${room.icon} ${room.name}',
    if (lines > 0) '$lines ${lines == 1 ? 'line' : 'lines'}',
    if (project.hasAudioReference) 'already has a recording',
  ].join('  ·  ');
}
