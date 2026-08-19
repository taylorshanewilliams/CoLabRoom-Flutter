import 'package:flutter/material.dart';

import '../app/colabroom_theme.dart';
import '../domain/music_models.dart';
import 'app_surface.dart';
import 'bloom_tap.dart';

class RoomTile extends StatelessWidget {
  const RoomTile({required this.room, required this.onTap, this.onMore, super.key});

  final MusicRoom room;
  final VoidCallback onTap;

  /// When set, shows a small overflow button (rename/delete) instead of the
  /// plain chevron. Left null on read-only previews (e.g. the Home screen's
  /// "My Rooms" strip) where those actions don't apply.
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    return BloomTap(
      onTap: onTap,
      semanticLabel: 'Open ${room.name}',
      child: AppSurface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 42,
                  height: 42,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const RadialGradient(
                      colors: <Color>[Color(0x7A2B6FFF), Color(0x382B6FFF), Color(0x082B6FFF)],
                    ),
                  ),
                  child: Text(
                    room.icon,
                    style: const TextStyle(fontSize: 23, color: AppColors.cyan),
                  ),
                ),
                const Spacer(),
                if (onMore != null)
                  InkResponse(
                    key: const Key('room_more_button'),
                    onTap: onMore,
                    radius: 18,
                    child: const Icon(Icons.more_vert_rounded, size: 20, color: AppColors.muted),
                  )
                else
                  const Icon(Icons.chevron_right_rounded, size: 20, color: AppColors.muted),
              ],
            ),
            const Spacer(),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    room.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${room.projects.length} ${room.projects.length == 1 ? 'project' : 'projects'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
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

class SongTile extends StatelessWidget {
  const SongTile({
    required this.project,
    required this.onTap,
    this.onLongPress,
    this.onMore,
    this.selected = false,
    super.key,
  });

  final SongProject project;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// When set (and [selected] is false), shows a small overflow button
  /// (rename/delete/select) instead of the plain arrow — mirrors
  /// [RoomTile.onMore].
  final VoidCallback? onMore;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return BloomTap(
      onTap: onTap,
      onLongPress: onLongPress,
      semanticLabel: 'Open ${project.title}',
      child: AppSurface(
        padding: const EdgeInsets.all(12),
        color: selected ? const Color(0xFF0C2341) : AppColors.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.raised,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: const Icon(
                    Icons.music_note_rounded,
                    color: AppColors.cyan,
                    size: 21,
                  ),
                ),
                const Spacer(),
                if (selected)
                  const Icon(Icons.check_circle_rounded, color: AppColors.cyan, size: 19)
                else if (onMore != null)
                  InkResponse(
                    key: const Key('song_more_button'),
                    onTap: onMore,
                    radius: 18,
                    child: const Icon(Icons.more_vert_rounded, size: 20, color: AppColors.muted),
                  )
                else
                  const Icon(Icons.arrow_outward_rounded, color: AppColors.muted, size: 19),
              ],
            ),
            const Spacer(),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    project.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${project.contributions.length} contributions',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
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

class SetlistTile extends StatelessWidget {
  const SetlistTile({required this.setlist, required this.onTap, super.key});

  final Setlist setlist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return BloomTap(
      onTap: onTap,
      semanticLabel: 'Open ${setlist.name}',
      child: AppSurface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.raised,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.queue_music_rounded, color: AppColors.cyan),
                ),
                const Spacer(),
                const Icon(Icons.chevron_right_rounded, color: AppColors.muted, size: 20),
              ],
            ),
            const Spacer(),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    setlist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${setlist.projectIds.length} ${setlist.projectIds.length == 1 ? 'song' : 'songs'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
